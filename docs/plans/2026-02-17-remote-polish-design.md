# Remote Control — Phase 4 Polish Design

**Date:** 2026-02-17
**Scope:** Tasks 25–27 (Adaptive Bitrate, TLS + Pairing, Tunnel Support)
**Prerequisite:** Phase 1–3 complete. Live client wiring (RemoteServerClient/RemoteConnectionClient liveValues) is out of scope — will be done separately.

---

## Task 25: Adaptive Bitrate

### Goal

Dynamically adjust H.264 encoder bitrate (200 Kbps – 5 Mbps) and capture frame rate based on WebSocket send-queue pressure.

### Architecture

```
WebSocketServer.send() → tracks pendingSendCount
            ↓
AdaptiveBitrateController (1s evaluation loop)
            ↓
Adjusts SurfaceVideoEncoder bitrate via VTSessionSetProperty
Adjusts SurfaceCaptureOrchestrator frame interval
```

### Components

**AdaptiveBitrateController** — `@MainActor @Observable`
- Monitors `pendingSendCount` from `WebSocketServer`
- 1-second evaluation loop:
  - `pendingSendCount > 3` → decrease bitrate by 25%, floor at 200 Kbps
  - `pendingSendCount == 0` for 3 consecutive evaluations → increase by 25%, cap at 5 Mbps
  - `pendingSendCount > 8` → halve frame rate (30 → 15 → 10 fps)
  - `pendingSendCount < 2` for 5 consecutive evaluations → restore frame rate
- Exposes `currentBitrate: Int` and `currentFrameInterval: TimeInterval`

**WebSocketServer changes**
- Add `var pendingSendCount: Int` — increment before send, decrement in completion handler

**SurfaceVideoEncoder changes**
- Add `func updateBitrate(_ bps: Int)` — calls `VTSessionSetProperty(kVTCompressionPropertyKey_AverageBitRate)`

**SurfaceCaptureOrchestrator changes**
- Add `func updateFrameInterval(_ interval: TimeInterval)` — reschedules capture timer

### Error handling

`VTSessionSetProperty` failure → log and continue with current bitrate. No crash, no retry.

---

## Task 26: TLS + Pairing Code

### Goal

Encrypt all WebSocket traffic with TLS. Authenticate connections with a 6-digit pairing code displayed on the server.

### Connection Flow

1. Server starts → loads/generates self-signed TLS cert from Keychain
2. `NWListener` configured with `NWProtocolTLS.Options`
3. Client discovers server → connects with TLS (trusts all certs — self-signed)
4. Server receives connection → generates random 6-digit code, shows modal dialog
5. Client's `HelloMessage` includes `pairingCode` field
6. Server validates code → match: send `WelcomeMessage` → mismatch: disconnect

### Components

**TLSCertificateManager** — `@MainActor`
- `func loadOrCreateIdentity() -> SecIdentity`
- Checks Keychain for cert with label `com.supacode.remote-tls`
- If missing: creates RSA 2048-bit self-signed cert (CN=supacode-remote, 1-year validity)
- Uses Security.framework (`SecKeyCreateRandomKey`, certificate creation)

**BonjourAdvertiser changes**
- Add TLS options to `NWParameters`: `NWProtocolTLS.Options` with server identity
- Insert before WebSocket options in protocol stack

**WebSocketClient changes**
- Add `sec_protocol_options_set_verify_block` to accept any server cert
- Still encrypted — just skips CA validation (appropriate for self-signed LAN use)

**RemoteProtocol changes**
- `HelloMessage` gets `pairingCode: String?` field

**RemoteFeature changes**
- State: `activePairingCode: String?`
- On `clientConnected` → generate random 6-digit code, set state
- Actions: `pairingCodeValidated`, `pairingCodeRejected`

**PairingCodeView** — SwiftUI `.sheet`
- Shown when `activePairingCode != nil`
- Large monospaced 6-digit code display
- Auto-dismiss on successful pairing or 60-second timeout

### Error handling

- Certificate creation failure → fall back to unencrypted + log warning
- Wrong pairing code → disconnect client, dismiss dialog
- Pairing timeout (60s) → disconnect, dismiss

---

## Task 27: Tailscale/Tunnel Support (Manual Connection)

### Goal

Allow connecting to a remote supacode instance via manual host:port entry, enabling use over Tailscale, Cloudflare Tunnel, SSH tunnels, or any TCP route.

### Flow

1. User opens Connect sheet → sees Bonjour-discovered servers (existing)
2. Below list: "Connect directly" text field with placeholder "host:port"
3. User enters address → presses Enter/Connect button
4. RemoteFeature parses input → creates `NWEndpoint.hostPort`
5. Wraps in synthetic `DiscoveredServer` → reuses existing connect flow
6. Reconnection stores endpoint for auto-reconnect

### Components

**RemoteFeature changes**
- `Action.connectToAddress(String)` — parses "host:port"
- Parse: split on last `:`, validate port 1–65535
- Creates `DiscoveredServer(id: "manual-<host>:<port>", name: "<host>:<port>", endpoint: .hostPort(...))`
- Delegates to existing `.connectToServer()`

**DiscoveredServer** — No structural changes needed
- Already supports `NWEndpoint` which includes `.hostPort`
- Reconnection via `lastConnectedServer` works for manual entries

**RemoteConnectionClient** — No changes needed
- `connect(to:)` uses `server.endpoint` — `.hostPort` works identically to Bonjour

**Connect sheet UI**
- `Divider` + `TextField` below discovered servers list
- "Connect directly" label, "host:port" placeholder
- `onSubmit` dispatches `.connectToAddress(text)`
- Inline validation error for invalid format

### Error handling

- Invalid format → inline error below text field
- Connection failure → existing reconnection logic handles it
- DNS resolution failure → `NWConnection.failed` → existing error path

---

## Testing Strategy

- **Task 25**: Unit test `AdaptiveBitrateController` decision logic with mock pending counts
- **Task 26**: Test `TLSCertificateManager` identity creation; test `HelloMessage` round-trip with pairing code; test pairing validation in `RemoteFeatureTests`
- **Task 27**: Test address parsing (valid/invalid formats); test `connectToAddress` action creates correct endpoint
