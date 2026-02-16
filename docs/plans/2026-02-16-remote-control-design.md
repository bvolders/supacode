# Remote Control for Supacode

**Date**: 2026-02-16
**Status**: Approved

## Problem

Supacode runs on a Mac in the basement (CPU power, many projects), but the user wants to control it from a MacBook upstairs. Currently supacode is a purely local macOS app with no networking capabilities.

## Goals

- Stream terminal output from the server to a remote client over the local network
- Control repositories, worktrees, and terminal input remotely
- Keep full local functionality on both machines (hybrid local + remote)
- Single remote client at a time
- Local network first, tunnel-ready later (Tailscale)

## Non-Goals (for now)

- Web browser client
- Multiple simultaneous remote clients
- Internet-first access with full auth/TLS
- Forking Ghostty for screen buffer access

## Architecture

### Hybrid Local + Remote

Both machines run the full supacode app. Remote connections are additive — the MacBook keeps its own local projects and can additionally connect to the basement Mac's projects.

```
Sidebar:
├── my-macbook-project        (local)
├── another-local-thing       (local)
├── ── basement-mac ────────  (remote)
├── big-project               (remote, streamed)
└── agent-swarm               (remote, streamed)
```

The terminal view is polymorphic:
- Local worktree: normal Ghostty surface (as today)
- Remote worktree: H.264 decoded video stream + input relay

### Server/Client Roles

**Server (basement Mac):**
- Runs supacode normally with embedded WebSocket server
- Owns all Ghostty surfaces and TCA state
- Captures terminal surfaces as H.264 video via VideoToolbox
- Advertises via Bonjour (`_supacode._tcp`)
- Accepts one remote client connection

**Client (MacBook upstairs):**
- Runs supacode normally for local projects
- Discovers servers via Bonjour
- Connects via WebSocket to receive state + video
- Renders remote terminals via hardware H.264 decoder into MTKView
- Sends keyboard/mouse input back to server

### Network Protocol

Single WebSocket connection with multiplexed message types:

| Type Byte | Name | Direction | Payload |
|-----------|------|-----------|---------|
| 0x01 | hello | C→S | JSON: version, capabilities |
| 0x02 | welcome | S→C | JSON: server info |
| 0x03 | ping | both | empty |
| 0x04 | pong | both | empty |
| 0x10 | stateSnapshot | S→C | JSON: full state |
| 0x11 | stateDelta | S→C | JSON: incremental change |
| 0x12 | action | C→S | JSON: user action |
| 0x20 | videoConfig | S→C | binary: SPS/PPS params |
| 0x21 | videoFrame | S→C | binary: H.264 NAL unit |
| 0x22 | videoRequest | C→S | JSON: worktree ID |
| 0x23 | videoStop | C→S | JSON: worktree ID |
| 0x30 | keyEvent | C→S | JSON: key + modifiers |
| 0x31 | mouseEvent | C→S | JSON: position + button |
| 0x32 | textInput | C→S | JSON: text string |
| 0x33 | resize | C→S | JSON: cols + rows |

Wire format: `[type: 1 byte][length: 4 bytes big-endian][payload]`
- Text WebSocket frames for JSON messages
- Binary WebSocket frames for video data

### H.264 Video Pipeline

**Server (encoder):**

```
GhosttySurfaceView.layer
    → CALayer.render(in: CGContext)   [capture at 1x]
    → CVPixelBuffer (BGRA)
    → VTCompressionSession            [hardware H.264]
       - Profile: Baseline
       - Realtime: true
       - MaxKeyFrameInterval: 60
       - AverageBitRate: 1_000_000
       - AllowFrameReordering: false  [no B-frames, low latency]
    → CMSampleBuffer (NAL units)
    → WebSocket binary frame
```

**Client (decoder):**

```
WebSocket binary frame
    → VTDecompressionSession          [hardware H.264]
    → CVPixelBuffer
    → MTKView / CAMetalLayer          [GPU render, zero CPU copy]
```

**Smart frame rate:**
- Only capture when Ghostty's wakeup callback fires (surface changed)
- 30fps cap during activity
- Near-zero bandwidth when idle (no frames sent)

**Bandwidth per terminal:**
- Idle: ~0
- Typing: ~50-100 Kbps
- Compiler output: ~200-500 Kbps
- Fast scroll: ~1-3 Mbps
- Average real-world: ~100-300 Kbps

### State Synchronization

Separate from video — synced as JSON over the same WebSocket.

```swift
struct RemoteStateSnapshot: Codable {
    let repositories: [RemoteRepository]
    let selectedWorktreeID: String?
    let settings: RemoteSettings
}

struct RemoteRepository: Codable {
    let id: String
    let name: String
    let worktrees: [RemoteWorktree]
}

struct RemoteWorktree: Codable {
    let id: String
    let name: String
    let detail: String
    let tabs: [RemoteTab]
    let info: RemoteWorktreeInfo?
    let taskStatus: String
}
```

Client actions (create worktree, select tab, run script, etc.) are sent as `RemoteAction` JSON and applied to the server's real TCA store.

### Discovery & Connection

**Server:** `NWListener` on port 9847 with Bonjour service type `_supacode._tcp`
**Client:** `NWBrowser` for `_supacode._tcp`, shows discovered servers in UI

Connection flow: browse → connect → hello/welcome handshake → stateSnapshot → ready

### Security

**Phase 1 (MVP):** Local network trust. Server shows "Allow connection?" notification. Single client lock.
**Phase 2:** Shared secret pairing code. TLS via NWProtocolTLS. Required for tunnel access.

## New Modules

```
supacode/
├── Features/Remote/
│   ├── Reducer/RemoteFeature.swift
│   ├── Views/
│   │   ├── RemoteServerView.swift
│   │   └── RemoteBrowserView.swift
│   └── Models/
│       ├── RemoteProtocol.swift
│       ├── RemoteStateSnapshot.swift
│       └── RemoteAction.swift
├── Clients/Remote/
│   ├── RemoteServerClient.swift
│   └── RemoteConnectionClient.swift
└── Infrastructure/Remote/
    ├── WebSocketServer.swift
    ├── WebSocketClient.swift
    ├── SurfaceVideoEncoder.swift
    ├── SurfaceVideoDecoder.swift
    ├── BonjourAdvertiser.swift
    └── BonjourBrowser.swift

supacode/Features/Terminal/Views/
    └── RemoteTerminalView.swift
```

## Phased Milestones

### Phase 1 — Plumbing
- Add Codable to domain models (Repository, Worktree, etc.)
- WebSocket server/client with Network.framework
- Bonjour discovery + connection handshake
- State snapshot sync (repos + worktrees appear in sidebar)

### Phase 2 — Terminal Streaming
- SurfaceVideoEncoder (CALayer → VTCompressionSession → H.264)
- SurfaceVideoDecoder (H.264 → VTDecompressionSession → MTKView)
- RemoteTerminalView replacing Ghostty surface for remote worktrees
- Keyboard/mouse input relay

### Phase 3 — Full Interaction
- Remote actions (create/delete worktrees, run scripts, tabs)
- Settings sync
- Connection approval UI on server
- Reconnection handling

### Phase 4 — Polish
- Adaptive bitrate based on network quality
- Tailscale/tunnel support
- TLS + pairing code auth
- Multiple terminal tabs per worktree streaming
