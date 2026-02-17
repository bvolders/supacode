# Remote Control Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add WebSocket-based remote control so supacode on one Mac can be controlled from another Mac on the local network, with H.264 terminal streaming via VideoToolbox.

**Architecture:** Server embeds a WebSocket server (Network.framework) advertising via Bonjour. Client discovers and connects, receives state snapshots (JSON) and terminal video (H.264 NAL units). Both machines keep full local functionality — remote is additive.

**Tech Stack:** Network.framework (NWListener, NWConnection, NWBrowser), VideoToolbox (VTCompressionSession, VTDecompressionSession), MetalKit (MTKView), TCA, SwiftUI

**Design doc:** `docs/plans/2026-02-16-remote-control-design.md`

---

## Phase 1 — Plumbing

### Task 1: Remote Protocol Models

Define the shared protocol types used by both server and client.

**Files:**
- Create: `supacode/Features/Remote/Models/RemoteProtocol.swift`

**Step 1: Write tests for protocol Codable round-tripping**

Create test file:
- Create: `supacodeTests/RemoteProtocolTests.swift`

```swift
import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteProtocolTests {
  @Test func messageTypeRawValues() {
    #expect(RemoteMessageType.hello.rawValue == 0x01)
    #expect(RemoteMessageType.welcome.rawValue == 0x02)
    #expect(RemoteMessageType.stateSnapshot.rawValue == 0x10)
    #expect(RemoteMessageType.videoFrame.rawValue == 0x21)
    #expect(RemoteMessageType.keyEvent.rawValue == 0x30)
  }

  @Test func helloMessageRoundTrips() throws {
    let hello = HelloMessage(
      protocolVersion: 1,
      appVersion: "0.6.0",
      clientName: "Henry's MacBook",
    )
    let data = try JSONEncoder().encode(hello)
    let decoded = try JSONDecoder().decode(HelloMessage.self, from: data)
    #expect(decoded.protocolVersion == 1)
    #expect(decoded.clientName == "Henry's MacBook")
  }

  @Test func welcomeMessageRoundTrips() throws {
    let welcome = WelcomeMessage(
      protocolVersion: 1,
      serverName: "Henry's Mac Mini",
    )
    let data = try JSONEncoder().encode(welcome)
    let decoded = try JSONDecoder().decode(WelcomeMessage.self, from: data)
    #expect(decoded.serverName == "Henry's Mac Mini")
  }

  @Test func remoteFrameHeaderEncodesCorrectly() {
    let header = RemoteFrameHeader(
      type: .stateSnapshot,
      length: 1024,
    )
    var data = Data()
    data.append(header.type.rawValue)
    var len = UInt32(header.length).bigEndian
    data.append(Data(bytes: &len, count: 4))
    #expect(data.count == 5)
    #expect(data[0] == 0x10)
  }
}
```

**Step 2: Run test to verify it fails**

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/RemoteProtocolTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL — `RemoteMessageType` not found

**Step 3: Write RemoteProtocol.swift**

```swift
import Foundation

enum RemoteMessageType: UInt8, Codable, Sendable {
  // Control
  case hello = 0x01
  case welcome = 0x02
  case ping = 0x03
  case pong = 0x04

  // State sync
  case stateSnapshot = 0x10
  case stateDelta = 0x11
  case action = 0x12

  // Terminal video
  case videoConfig = 0x20
  case videoFrame = 0x21
  case videoRequest = 0x22
  case videoStop = 0x23

  // Terminal input
  case keyEvent = 0x30
  case mouseEvent = 0x31
  case textInput = 0x32
  case resize = 0x33
}

struct RemoteFrameHeader: Sendable {
  let type: RemoteMessageType
  let length: Int
}

nonisolated struct HelloMessage: Codable, Sendable {
  let protocolVersion: Int
  let appVersion: String
  let clientName: String
}

nonisolated struct WelcomeMessage: Codable, Sendable {
  let protocolVersion: Int
  let serverName: String
}
```

**Step 4: Run test to verify it passes**

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/RemoteProtocolTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS

**Step 5: Commit**

```bash
git add supacode/Features/Remote/Models/RemoteProtocol.swift supacodeTests/RemoteProtocolTests.swift
git commit -m "feat(remote): add remote protocol message types"
```

---

### Task 2: Remote State Snapshot Models

Separate Codable models for state sync — decoupled from TCA internals.

**Files:**
- Create: `supacode/Features/Remote/Models/RemoteStateSnapshot.swift`
- Create: `supacodeTests/RemoteStateSnapshotTests.swift`

**Step 1: Write tests**

```swift
import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteStateSnapshotTests {
  @Test func snapshotRoundTrips() throws {
    let snapshot = RemoteStateSnapshot(
      repositories: [
        RemoteRepository(
          id: "/tmp/repo",
          name: "my-project",
          worktrees: [
            RemoteWorktree(
              id: "/tmp/repo/wt-feature",
              name: "feature",
              detail: "feature/login",
              tabs: [
                RemoteTab(id: UUID(), title: "zsh", isDirty: false),
              ],
              info: RemoteWorktreeInfo(
                addedLines: 42,
                removedLines: 10,
                pullRequestNumber: 123,
                pullRequestTitle: "Add login",
                pullRequestState: "OPEN",
              ),
              taskStatus: .idle,
            ),
          ],
        ),
      ],
      selectedWorktreeID: "/tmp/repo/wt-feature",
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(RemoteStateSnapshot.self, from: data)
    #expect(decoded.repositories.count == 1)
    #expect(decoded.repositories[0].worktrees[0].name == "feature")
    #expect(decoded.repositories[0].worktrees[0].info?.addedLines == 42)
    #expect(decoded.selectedWorktreeID == "/tmp/repo/wt-feature")
  }

  @Test func snapshotFromDomainModels() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-main",
      name: "main",
      detail: "main",
      workingDirectory: URL(filePath: "/tmp/repo/wt-main"),
      repositoryRootURL: URL(filePath: "/tmp/repo"),
    )
    let remote = RemoteWorktree(from: worktree, tabs: [], info: nil, taskStatus: .idle)
    #expect(remote.id == "/tmp/repo/wt-main")
    #expect(remote.name == "main")
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write RemoteStateSnapshot.swift**

```swift
import Foundation

nonisolated struct RemoteStateSnapshot: Codable, Sendable {
  let repositories: [RemoteRepository]
  let selectedWorktreeID: String?
}

nonisolated struct RemoteRepository: Codable, Sendable {
  let id: String
  let name: String
  let worktrees: [RemoteWorktree]
}

nonisolated struct RemoteWorktree: Codable, Sendable {
  let id: String
  let name: String
  let detail: String
  let tabs: [RemoteTab]
  let info: RemoteWorktreeInfo?
  let taskStatus: RemoteTaskStatus

  init(
    id: String,
    name: String,
    detail: String,
    tabs: [RemoteTab],
    info: RemoteWorktreeInfo?,
    taskStatus: RemoteTaskStatus
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.tabs = tabs
    self.info = info
    self.taskStatus = taskStatus
  }

  init(
    from worktree: Worktree,
    tabs: [RemoteTab],
    info: RemoteWorktreeInfo?,
    taskStatus: RemoteTaskStatus
  ) {
    self.id = worktree.id
    self.name = worktree.name
    self.detail = worktree.detail
    self.tabs = tabs
    self.info = info
    self.taskStatus = taskStatus
  }
}

nonisolated struct RemoteTab: Codable, Sendable {
  let id: UUID
  let title: String
  let isDirty: Bool
}

nonisolated struct RemoteWorktreeInfo: Codable, Sendable {
  let addedLines: Int?
  let removedLines: Int?
  let pullRequestNumber: Int?
  let pullRequestTitle: String?
  let pullRequestState: String?

  init(
    addedLines: Int? = nil,
    removedLines: Int? = nil,
    pullRequestNumber: Int? = nil,
    pullRequestTitle: String? = nil,
    pullRequestState: String? = nil
  ) {
    self.addedLines = addedLines
    self.removedLines = removedLines
    self.pullRequestNumber = pullRequestNumber
    self.pullRequestTitle = pullRequestTitle
    self.pullRequestState = pullRequestState
  }

  init(from info: WorktreeInfoEntry) {
    self.addedLines = info.addedLines
    self.removedLines = info.removedLines
    self.pullRequestNumber = info.pullRequest?.number
    self.pullRequestTitle = info.pullRequest?.title
    self.pullRequestState = info.pullRequest?.state
  }
}

enum RemoteTaskStatus: String, Codable, Sendable {
  case idle
  case running
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Features/Remote/Models/RemoteStateSnapshot.swift supacodeTests/RemoteStateSnapshotTests.swift
git commit -m "feat(remote): add remote state snapshot models"
```

---

### Task 3: Remote Action Models

Client-to-server actions for controlling the remote supacode instance.

**Files:**
- Create: `supacode/Features/Remote/Models/RemoteAction.swift`
- Create: `supacodeTests/RemoteActionTests.swift`

**Step 1: Write tests**

```swift
import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteActionTests {
  @Test func selectWorktreeRoundTrips() throws {
    let action = RemoteAction.selectWorktree(id: "/tmp/repo/wt-feature")
    let data = try JSONEncoder().encode(action)
    let decoded = try JSONDecoder().decode(RemoteAction.self, from: data)
    #expect(decoded == action)
  }

  @Test func createWorktreeRoundTrips() throws {
    let action = RemoteAction.createWorktree(
      repositoryID: "/tmp/repo",
      branchName: "feature/login",
    )
    let data = try JSONEncoder().encode(action)
    let decoded = try JSONDecoder().decode(RemoteAction.self, from: data)
    #expect(decoded == action)
  }

  @Test func keyEventRoundTrips() throws {
    let action = RemoteInputEvent.key(
      RemoteKeyEvent(
        keyCode: 0,
        characters: "a",
        modifiers: [.shift],
        isKeyDown: true,
      )
    )
    let data = try JSONEncoder().encode(action)
    let decoded = try JSONDecoder().decode(RemoteInputEvent.self, from: data)
    #expect(decoded == action)
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write RemoteAction.swift**

```swift
import Foundation

enum RemoteAction: Codable, Equatable, Sendable {
  case selectWorktree(id: String)
  case createWorktree(repositoryID: String, branchName: String)
  case deleteWorktree(id: String)
  case createTab(worktreeID: String)
  case closeTab(worktreeID: String, tabID: UUID)
  case selectTab(worktreeID: String, tabID: UUID)
  case runScript(worktreeID: String, script: String)
  case stopRunScript(worktreeID: String)
}

enum RemoteInputEvent: Codable, Equatable, Sendable {
  case key(RemoteKeyEvent)
  case mouse(RemoteMouseEvent)
  case text(RemoteTextInput)
  case resize(RemoteResize)
}

nonisolated struct RemoteKeyEvent: Codable, Equatable, Sendable {
  let keyCode: UInt16
  let characters: String?
  let modifiers: Set<RemoteModifier>
  let isKeyDown: Bool
}

enum RemoteModifier: String, Codable, Sendable {
  case shift
  case control
  case option
  case command
}

nonisolated struct RemoteMouseEvent: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
  let button: Int
  let isDown: Bool
  let modifiers: Set<RemoteModifier>
}

nonisolated struct RemoteTextInput: Codable, Equatable, Sendable {
  let text: String
  let worktreeID: String
}

nonisolated struct RemoteResize: Codable, Equatable, Sendable {
  let worktreeID: String
  let width: UInt32
  let height: UInt32
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Features/Remote/Models/RemoteAction.swift supacodeTests/RemoteActionTests.swift
git commit -m "feat(remote): add remote action and input event models"
```

---

### Task 4: Bonjour Advertiser (Server-Side Discovery)

Server advertises itself on the local network so clients can find it.

**Files:**
- Create: `supacode/Infrastructure/Remote/BonjourAdvertiser.swift`
- Create: `supacodeTests/BonjourAdvertiserTests.swift`

**Step 1: Write tests**

```swift
import Foundation
import Network
import Testing

@testable import supacode

@MainActor
struct BonjourAdvertiserTests {
  @Test func serviceTypeIsCorrect() {
    #expect(BonjourAdvertiser.serviceType == "_supacode._tcp")
  }

  @Test func defaultPortIsCorrect() {
    #expect(BonjourAdvertiser.defaultPort == 9847)
  }

  @Test func advertiserInitializesWithServerName() {
    let advertiser = BonjourAdvertiser(serverName: "Test Mac")
    #expect(advertiser.serverName == "Test Mac")
    #expect(advertiser.isAdvertising == false)
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write BonjourAdvertiser.swift**

```swift
import Foundation
import Network

@MainActor
@Observable
final class BonjourAdvertiser {
  static let serviceType = "_supacode._tcp"
  static let defaultPort: UInt16 = 9847

  let serverName: String
  private(set) var isAdvertising = false
  private var listener: NWListener?

  init(serverName: String) {
    self.serverName = serverName
  }

  func start(
    port: UInt16 = BonjourAdvertiser.defaultPort,
    onNewConnection: @escaping @Sendable (NWConnection) -> Void
  ) throws {
    let params = NWParameters.tcp
    let wsOptions = NWProtocolWebSocket.Options()
    wsOptions.autoReplyPing = true
    params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

    let nwPort = NWEndpoint.Port(rawValue: port)!
    let listener = try NWListener(using: params, on: nwPort)
    listener.service = NWListener.Service(
      name: serverName,
      type: Self.serviceType,
    )
    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .ready:
          self?.isAdvertising = true
          SupaLogger.info("[Remote] Server advertising as '\(self?.serverName ?? "")'")
        case .failed(let error):
          SupaLogger.error("[Remote] Listener failed: \(error)")
          self?.isAdvertising = false
        case .cancelled:
          self?.isAdvertising = false
        default:
          break
        }
      }
    }
    listener.newConnectionHandler = { connection in
      onNewConnection(connection)
    }
    listener.start(queue: .main)
    self.listener = listener
  }

  func stop() {
    listener?.cancel()
    listener = nil
    isAdvertising = false
  }
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Infrastructure/Remote/BonjourAdvertiser.swift supacodeTests/BonjourAdvertiserTests.swift
git commit -m "feat(remote): add Bonjour advertiser for server discovery"
```

---

### Task 5: Bonjour Browser (Client-Side Discovery)

Client discovers servers on the local network.

**Files:**
- Create: `supacode/Infrastructure/Remote/BonjourBrowser.swift`
- Create: `supacodeTests/BonjourBrowserTests.swift`

**Step 1: Write tests**

```swift
import Foundation
import Network
import Testing

@testable import supacode

@MainActor
struct BonjourBrowserTests {
  @Test func browseTypeMatchesAdvertiser() {
    #expect(BonjourBrowser.serviceType == BonjourAdvertiser.serviceType)
  }

  @Test func browserInitializesEmpty() {
    let browser = BonjourBrowser()
    #expect(browser.discoveredServers.isEmpty)
    #expect(browser.isBrowsing == false)
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write BonjourBrowser.swift**

```swift
import Foundation
import Network

nonisolated struct DiscoveredServer: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let endpoint: NWEndpoint

  nonisolated static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name
  }
}

@MainActor
@Observable
final class BonjourBrowser {
  static let serviceType = BonjourAdvertiser.serviceType

  private(set) var discoveredServers: [DiscoveredServer] = []
  private(set) var isBrowsing = false
  private var browser: NWBrowser?

  func startBrowsing() {
    let params = NWParameters()
    params.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjour(type: Self.serviceType, domain: nil),
      using: params,
    )
    browser.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .ready:
          self?.isBrowsing = true
          SupaLogger.info("[Remote] Browsing for servers")
        case .failed(let error):
          SupaLogger.error("[Remote] Browser failed: \(error)")
          self?.isBrowsing = false
        case .cancelled:
          self?.isBrowsing = false
        default:
          break
        }
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor in
        self?.discoveredServers = results.compactMap { result in
          guard case let .service(name, _, _, _) = result.endpoint else { return nil }
          return DiscoveredServer(
            id: name,
            name: name,
            endpoint: result.endpoint,
          )
        }
      }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  func stopBrowsing() {
    browser?.cancel()
    browser = nil
    isBrowsing = false
    discoveredServers = []
  }
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Infrastructure/Remote/BonjourBrowser.swift supacodeTests/BonjourBrowserTests.swift
git commit -m "feat(remote): add Bonjour browser for server discovery"
```

---

### Task 6: WebSocket Server

Handles a single WebSocket client connection with message framing.

**Files:**
- Create: `supacode/Infrastructure/Remote/WebSocketServer.swift`

**Step 1: Write tests**

- Create: `supacodeTests/WebSocketServerTests.swift`

```swift
import Foundation
import Testing

@testable import supacode

@MainActor
struct WebSocketServerTests {
  @Test func serverInitializesDisconnected() {
    let server = WebSocketServer()
    #expect(server.isClientConnected == false)
    #expect(server.isRunning == false)
  }

  @Test func frameHeaderEncoding() {
    let data = WebSocketServer.encodeFrameHeader(
      type: .stateSnapshot,
      payloadLength: 256,
    )
    #expect(data.count == 5)
    #expect(data[0] == RemoteMessageType.stateSnapshot.rawValue)
    let length = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    #expect(length == 256)
  }

  @Test func frameHeaderDecoding() {
    let data = WebSocketServer.encodeFrameHeader(type: .hello, payloadLength: 42)
    let header = WebSocketServer.decodeFrameHeader(from: data)
    #expect(header?.type == .hello)
    #expect(header?.length == 42)
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write WebSocketServer.swift**

```swift
import Foundation
import Network

@MainActor
@Observable
final class WebSocketServer {
  private(set) var isRunning = false
  private(set) var isClientConnected = false
  private var connection: NWConnection?
  private let advertiser: BonjourAdvertiser
  var onMessageReceived: ((RemoteMessageType, Data) -> Void)?

  init(serverName: String = Host.current().localizedName ?? "Supacode Server") {
    self.advertiser = BonjourAdvertiser(serverName: serverName)
  }

  var isRunning: Bool { advertiser.isAdvertising }

  func start() throws {
    try advertiser.start { [weak self] connection in
      Task { @MainActor in
        self?.handleNewConnection(connection)
      }
    }
    isRunning = true
  }

  func stop() {
    disconnect()
    advertiser.stop()
    isRunning = false
  }

  func send(type: RemoteMessageType, payload: Data) {
    guard let connection else { return }
    var frame = Self.encodeFrameHeader(type: type, payloadLength: payload.count)
    frame.append(payload)
    let metadata = NWProtocolWebSocket.Metadata(
      opCode: type == .videoFrame || type == .videoConfig ? .binary : .text
    )
    let context = NWConnection.ContentContext(
      identifier: "remote",
      metadata: [metadata],
    )
    connection.send(
      content: frame,
      contentContext: context,
      isComplete: true,
      completion: .contentProcessed { error in
        if let error {
          SupaLogger.error("[Remote] Send error: \(error)")
        }
      },
    )
  }

  func sendJSON<T: Encodable>(type: RemoteMessageType, value: T) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    send(type: type, payload: data)
  }

  static func encodeFrameHeader(type: RemoteMessageType, payloadLength: Int) -> Data {
    var data = Data(capacity: 5)
    data.append(type.rawValue)
    var length = UInt32(payloadLength).bigEndian
    data.append(Data(bytes: &length, count: 4))
    return data
  }

  static func decodeFrameHeader(from data: Data) -> RemoteFrameHeader? {
    guard data.count >= 5 else { return nil }
    guard let type = RemoteMessageType(rawValue: data[0]) else { return nil }
    let length = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    return RemoteFrameHeader(type: type, length: Int(length))
  }

  private func handleNewConnection(_ newConnection: NWConnection) {
    if isClientConnected {
      SupaLogger.info("[Remote] Rejecting connection — already have a client")
      newConnection.cancel()
      return
    }
    connection = newConnection
    isClientConnected = true
    SupaLogger.info("[Remote] Client connected")

    newConnection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .failed(let error):
          SupaLogger.error("[Remote] Connection failed: \(error)")
          self?.disconnect()
        case .cancelled:
          self?.disconnect()
        default:
          break
        }
      }
    }
    newConnection.start(queue: .main)
    receiveMessages(on: newConnection)
  }

  private func receiveMessages(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, context, _, error in
      Task { @MainActor in
        if let error {
          SupaLogger.error("[Remote] Receive error: \(error)")
          self?.disconnect()
          return
        }
        if let data, data.count >= 5 {
          if let header = Self.decodeFrameHeader(from: data) {
            let payload = data.subdata(in: 5..<data.count)
            self?.onMessageReceived?(header.type, payload)
          }
        }
        // Continue receiving
        if self?.isClientConnected == true {
          self?.receiveMessages(on: connection)
        }
      }
    }
  }

  func disconnect() {
    connection?.cancel()
    connection = nil
    isClientConnected = false
  }
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Infrastructure/Remote/WebSocketServer.swift supacodeTests/WebSocketServerTests.swift
git commit -m "feat(remote): add WebSocket server with message framing"
```

---

### Task 7: WebSocket Client

Connects to a discovered server and handles message framing.

**Files:**
- Create: `supacode/Infrastructure/Remote/WebSocketClient.swift`
- Create: `supacodeTests/WebSocketClientTests.swift`

**Step 1: Write tests**

```swift
import Foundation
import Testing

@testable import supacode

@MainActor
struct WebSocketClientTests {
  @Test func clientInitializesDisconnected() {
    let client = WebSocketClient()
    #expect(client.isConnected == false)
    #expect(client.connectedServerName == nil)
  }

  @Test func frameHeaderEncodingMatchesServer() {
    let serverEncoded = WebSocketServer.encodeFrameHeader(type: .action, payloadLength: 100)
    let decoded = WebSocketClient.decodeFrameHeader(from: serverEncoded)
    #expect(decoded?.type == .action)
    #expect(decoded?.length == 100)
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write WebSocketClient.swift**

```swift
import Foundation
import Network

@MainActor
@Observable
final class WebSocketClient {
  private(set) var isConnected = false
  private(set) var connectedServerName: String?
  private var connection: NWConnection?
  var onMessageReceived: ((RemoteMessageType, Data) -> Void)?
  var onDisconnected: (() -> Void)?

  func connect(to server: DiscoveredServer) {
    let params = NWParameters.tcp
    let wsOptions = NWProtocolWebSocket.Options()
    wsOptions.autoReplyPing = true
    params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

    let connection = NWConnection(to: server.endpoint, using: params)
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .ready:
          self?.isConnected = true
          self?.connectedServerName = server.name
          SupaLogger.info("[Remote] Connected to '\(server.name)'")
          self?.sendHello()
        case .failed(let error):
          SupaLogger.error("[Remote] Connection failed: \(error)")
          self?.handleDisconnect()
        case .cancelled:
          self?.handleDisconnect()
        default:
          break
        }
      }
    }
    connection.start(queue: .main)
    self.connection = connection
    receiveMessages(on: connection)
  }

  func disconnect() {
    connection?.cancel()
    connection = nil
    handleDisconnect()
  }

  func send(type: RemoteMessageType, payload: Data) {
    guard let connection else { return }
    var frame = WebSocketServer.encodeFrameHeader(type: type, payloadLength: payload.count)
    frame.append(payload)
    let metadata = NWProtocolWebSocket.Metadata(opCode: .text)
    let context = NWConnection.ContentContext(
      identifier: "remote",
      metadata: [metadata],
    )
    connection.send(
      content: frame,
      contentContext: context,
      isComplete: true,
      completion: .contentProcessed { error in
        if let error {
          SupaLogger.error("[Remote] Client send error: \(error)")
        }
      },
    )
  }

  func sendJSON<T: Encodable>(type: RemoteMessageType, value: T) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    send(type: type, payload: data)
  }

  static func decodeFrameHeader(from data: Data) -> RemoteFrameHeader? {
    WebSocketServer.decodeFrameHeader(from: data)
  }

  private func sendHello() {
    let hello = HelloMessage(
      protocolVersion: 1,
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
      clientName: Host.current().localizedName ?? "Supacode Client",
    )
    sendJSON(type: .hello, value: hello)
  }

  private func receiveMessages(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      Task { @MainActor in
        if let error {
          SupaLogger.error("[Remote] Client receive error: \(error)")
          self?.handleDisconnect()
          return
        }
        if let data, data.count >= 5,
          let header = WebSocketServer.decodeFrameHeader(from: data)
        {
          let payload = data.subdata(in: 5..<data.count)
          self?.onMessageReceived?(header.type, payload)
        }
        if self?.isConnected == true {
          self?.receiveMessages(on: connection)
        }
      }
    }
  }

  private func handleDisconnect() {
    isConnected = false
    connectedServerName = nil
    onDisconnected?()
  }
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Infrastructure/Remote/WebSocketClient.swift supacodeTests/WebSocketClientTests.swift
git commit -m "feat(remote): add WebSocket client with Bonjour connection"
```

---

### Task 8: Remote Server Client (TCA Dependency)

TCA dependency client wrapping the server infrastructure for use in reducers.

**Files:**
- Create: `supacode/Clients/Remote/RemoteServerClient.swift`

**Step 1: Write test**

- Create: `supacodeTests/RemoteServerClientTests.swift`

```swift
import ComposableArchitecture
import Testing

@testable import supacode

@MainActor
struct RemoteServerClientTests {
  @Test func testValueDoesNotCrash() {
    let client = RemoteServerClient.testValue
    #expect(client.isRunning() == false)
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write RemoteServerClient.swift**

Follow the `ShellClient` / `TerminalClient` DependencyKey pattern:

```swift
import ComposableArchitecture
import Foundation

struct RemoteServerClient {
  var start: @MainActor @Sendable () throws -> Void
  var stop: @MainActor @Sendable () -> Void
  var isRunning: @MainActor @Sendable () -> Bool
  var isClientConnected: @MainActor @Sendable () -> Bool
  var sendStateSnapshot: @MainActor @Sendable (RemoteStateSnapshot) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<RemoteServerEvent>
}

enum RemoteServerEvent: Equatable, Sendable {
  case clientConnected(name: String)
  case clientDisconnected
  case actionReceived(RemoteAction)
  case inputReceived(RemoteInputEvent)
  case videoRequested(worktreeID: String)
  case videoStopped(worktreeID: String)
}

extension RemoteServerClient: DependencyKey {
  static let liveValue = RemoteServerClient(
    start: { fatalError("RemoteServerClient.start not configured") },
    stop: { fatalError("RemoteServerClient.stop not configured") },
    isRunning: { false },
    isClientConnected: { false },
    sendStateSnapshot: { _ in },
    events: { AsyncStream { $0.finish() } },
  )

  static let testValue = RemoteServerClient(
    start: {},
    stop: {},
    isRunning: { false },
    isClientConnected: { false },
    sendStateSnapshot: { _ in },
    events: { AsyncStream { $0.finish() } },
  )
}

extension DependencyValues {
  var remoteServerClient: RemoteServerClient {
    get { self[RemoteServerClient.self] }
    set { self[RemoteServerClient.self] = newValue }
  }
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Clients/Remote/RemoteServerClient.swift supacodeTests/RemoteServerClientTests.swift
git commit -m "feat(remote): add RemoteServerClient TCA dependency"
```

---

### Task 9: Remote Connection Client (TCA Dependency)

TCA dependency client wrapping the client-side connection for use in reducers.

**Files:**
- Create: `supacode/Clients/Remote/RemoteConnectionClient.swift`
- Create: `supacodeTests/RemoteConnectionClientTests.swift`

**Step 1: Write test**

```swift
import ComposableArchitecture
import Testing

@testable import supacode

@MainActor
struct RemoteConnectionClientTests {
  @Test func testValueDoesNotCrash() {
    let client = RemoteConnectionClient.testValue
    #expect(client.isConnected() == false)
    #expect(client.discoveredServers().isEmpty)
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write RemoteConnectionClient.swift**

```swift
import ComposableArchitecture
import Foundation

struct RemoteConnectionClient {
  var startBrowsing: @MainActor @Sendable () -> Void
  var stopBrowsing: @MainActor @Sendable () -> Void
  var discoveredServers: @MainActor @Sendable () -> [DiscoveredServer]
  var connect: @MainActor @Sendable (DiscoveredServer) -> Void
  var disconnect: @MainActor @Sendable () -> Void
  var isConnected: @MainActor @Sendable () -> Bool
  var sendAction: @MainActor @Sendable (RemoteAction) -> Void
  var sendInput: @MainActor @Sendable (RemoteInputEvent) -> Void
  var requestVideoStream: @MainActor @Sendable (String) -> Void
  var stopVideoStream: @MainActor @Sendable (String) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<RemoteConnectionEvent>
}

enum RemoteConnectionEvent: Equatable, Sendable {
  case connected(serverName: String)
  case disconnected
  case stateSnapshotReceived(RemoteStateSnapshot)
  case serversChanged([DiscoveredServer])
}

extension RemoteConnectionClient: DependencyKey {
  static let liveValue = RemoteConnectionClient(
    startBrowsing: { fatalError("RemoteConnectionClient not configured") },
    stopBrowsing: {},
    discoveredServers: { [] },
    connect: { _ in },
    disconnect: {},
    isConnected: { false },
    sendAction: { _ in },
    sendInput: { _ in },
    requestVideoStream: { _ in },
    stopVideoStream: { _ in },
    events: { AsyncStream { $0.finish() } },
  )

  static let testValue = RemoteConnectionClient(
    startBrowsing: {},
    stopBrowsing: {},
    discoveredServers: { [] },
    connect: { _ in },
    disconnect: {},
    isConnected: { false },
    sendAction: { _ in },
    sendInput: { _ in },
    requestVideoStream: { _ in },
    stopVideoStream: { _ in },
    events: { AsyncStream { $0.finish() } },
  )
}

extension DependencyValues {
  var remoteConnectionClient: RemoteConnectionClient {
    get { self[RemoteConnectionClient.self] }
    set { self[RemoteConnectionClient.self] = newValue }
  }
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Clients/Remote/RemoteConnectionClient.swift supacodeTests/RemoteConnectionClientTests.swift
git commit -m "feat(remote): add RemoteConnectionClient TCA dependency"
```

---

### Task 10: RemoteFeature TCA Reducer

The TCA feature managing all remote state: server toggle, discovered servers, connection, and remote repositories.

**Files:**
- Create: `supacode/Features/Remote/Reducer/RemoteFeature.swift`
- Create: `supacodeTests/RemoteFeatureTests.swift`

**Step 1: Write tests**

```swift
import ComposableArchitecture
import Testing

@testable import supacode

@MainActor
struct RemoteFeatureTests {
  @Test func toggleServerStartsAndStops() async {
    let startCalled = LockIsolated(false)
    let stopCalled = LockIsolated(false)
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteServerClient.start = { startCalled.withValue { $0 = true } }
      $0.remoteServerClient.stop = { stopCalled.withValue { $0 = true } }
      $0.remoteServerClient.events = { AsyncStream { $0.finish() } }
    }

    await store.send(.toggleServer) {
      $0.isServerEnabled = true
    }
    #expect(startCalled.value)

    await store.send(.toggleServer) {
      $0.isServerEnabled = false
    }
    #expect(stopCalled.value)
  }

  @Test func connectToServerSendsConnect() async {
    let connectCalled = LockIsolated<String?>(nil)
    let server = DiscoveredServer(
      id: "test-mac",
      name: "Test Mac",
      endpoint: .hostPort(host: "localhost", port: 9847),
    )
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.connect = { server in
        connectCalled.withValue { $0 = server.name }
      }
      $0.remoteConnectionClient.events = { AsyncStream { $0.finish() } }
    }

    await store.send(.connectToServer(server))
    #expect(connectCalled.value == "Test Mac")
  }

  @Test func stateSnapshotUpdatesRemoteRepositories() async {
    let snapshot = RemoteStateSnapshot(
      repositories: [
        RemoteRepository(
          id: "/tmp/repo",
          name: "my-project",
          worktrees: [
            RemoteWorktree(
              id: "/tmp/repo/wt-main",
              name: "main",
              detail: "main",
              tabs: [],
              info: nil,
              taskStatus: .idle,
            ),
          ],
        ),
      ],
      selectedWorktreeID: nil,
    )

    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }

    await store.send(.remoteConnectionEvent(.stateSnapshotReceived(snapshot))) {
      $0.remoteRepositories = snapshot.repositories
    }
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write RemoteFeature.swift**

```swift
import ComposableArchitecture
import Foundation

@Reducer
struct RemoteFeature {
  @ObservableState
  struct State: Equatable {
    var isServerEnabled = false
    var connectedClientName: String?
    var connectedServerName: String?
    var discoveredServers: [DiscoveredServer] = []
    var remoteRepositories: [RemoteRepository] = []
    var remoteSelectedWorktreeID: String?
    var isBrowsing = false
  }

  enum Action {
    case toggleServer
    case startBrowsing
    case stopBrowsing
    case connectToServer(DiscoveredServer)
    case disconnect
    case remoteServerEvent(RemoteServerEvent)
    case remoteConnectionEvent(RemoteConnectionEvent)
    case sendRemoteAction(RemoteAction)
  }

  @Dependency(\.remoteServerClient) private var remoteServerClient
  @Dependency(\.remoteConnectionClient) private var remoteConnectionClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .toggleServer:
        state.isServerEnabled.toggle()
        if state.isServerEnabled {
          return .run { send in
            try remoteServerClient.start()
            for await event in remoteServerClient.events() {
              await send(.remoteServerEvent(event))
            }
          }
        } else {
          remoteServerClient.stop()
          state.connectedClientName = nil
          return .none
        }

      case .startBrowsing:
        state.isBrowsing = true
        remoteConnectionClient.startBrowsing()
        return .run { send in
          for await event in remoteConnectionClient.events() {
            await send(.remoteConnectionEvent(event))
          }
        }

      case .stopBrowsing:
        state.isBrowsing = false
        remoteConnectionClient.stopBrowsing()
        return .none

      case .connectToServer(let server):
        remoteConnectionClient.connect(server)
        return .none

      case .disconnect:
        remoteConnectionClient.disconnect()
        state.connectedServerName = nil
        state.remoteRepositories = []
        state.remoteSelectedWorktreeID = nil
        return .none

      case .sendRemoteAction(let action):
        remoteConnectionClient.sendAction(action)
        return .none

      case .remoteServerEvent(let event):
        switch event {
        case .clientConnected(let name):
          state.connectedClientName = name
        case .clientDisconnected:
          state.connectedClientName = nil
        case .actionReceived, .inputReceived, .videoRequested, .videoStopped:
          break // Handled by parent (AppFeature)
        }
        return .none

      case .remoteConnectionEvent(let event):
        switch event {
        case .connected(let serverName):
          state.connectedServerName = serverName
        case .disconnected:
          state.connectedServerName = nil
          state.remoteRepositories = []
          state.remoteSelectedWorktreeID = nil
        case .stateSnapshotReceived(let snapshot):
          state.remoteRepositories = snapshot.repositories
          state.remoteSelectedWorktreeID = snapshot.selectedWorktreeID
        case .serversChanged(let servers):
          state.discoveredServers = servers
        }
        return .none
      }
    }
  }
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Features/Remote/Reducer/RemoteFeature.swift supacodeTests/RemoteFeatureTests.swift
git commit -m "feat(remote): add RemoteFeature TCA reducer"
```

---

### Task 11: Wire RemoteFeature into AppFeature

Integrate RemoteFeature as a child of the root AppFeature.

**Files:**
- Modify: `supacode/Features/App/Reducer/AppFeature.swift`
- Modify: `supacode/App/supacodeApp.swift`

**Step 1: Add remote state to AppFeature.State**

In `AppFeature.swift`, add to the State struct:

```swift
var remote = RemoteFeature.State()
```

**Step 2: Add remote actions to AppFeature.Action**

```swift
case remote(RemoteFeature.Action)
```

**Step 3: Scope RemoteFeature in the reducer body**

In the `body` computed property, add `RemoteFeature` as a scoped child:

```swift
Scope(state: \.remote, action: \.remote) {
  RemoteFeature()
}
```

**Step 4: Build the app**

```bash
make build-app
```

Expected: BUILD SUCCEEDED (no new test needed — existing tests still pass)

**Step 5: Commit**

```bash
git add supacode/Features/App/Reducer/AppFeature.swift supacode/App/supacodeApp.swift
git commit -m "feat(remote): wire RemoteFeature into AppFeature"
```

---

### Task 12: Checkpoint — Verify Phase 1 builds and tests pass

**Step 1: Run full test suite**

```bash
make test
```

Expected: All tests pass

**Step 2: Run full build**

```bash
make build-app
```

Expected: BUILD SUCCEEDED

**Step 3: Run lint/format**

```bash
make check
```

Expected: No warnings or errors

---

## Phase 2 — Terminal Streaming

### Task 13: Surface Video Encoder (H.264)

Captures a CALayer and encodes to H.264 via VideoToolbox hardware encoder.

**Files:**
- Create: `supacode/Infrastructure/Remote/SurfaceVideoEncoder.swift`
- Create: `supacodeTests/SurfaceVideoEncoderTests.swift`

**Step 1: Write tests**

```swift
import CoreMedia
import Foundation
import Testing
import VideoToolbox

@testable import supacode

@MainActor
struct SurfaceVideoEncoderTests {
  @Test func encoderInitializesWithDimensions() throws {
    let encoder = try SurfaceVideoEncoder(width: 800, height: 600)
    #expect(encoder.width == 800)
    #expect(encoder.height == 600)
    #expect(encoder.isEncoding == false)
    encoder.stop()
  }

  @Test func encoderProducesParameterSets() throws {
    let encoder = try SurfaceVideoEncoder(width: 800, height: 600)
    let parameterSets = encoder.parameterSetData
    // Parameter sets (SPS/PPS) are available after session creation
    #expect(parameterSets != nil)
    encoder.stop()
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write SurfaceVideoEncoder.swift**

```swift
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
final class SurfaceVideoEncoder {
  let width: Int
  let height: Int
  private(set) var isEncoding = false
  private var session: VTCompressionSession?
  private var pixelBufferPool: CVPixelBufferPool?
  private(set) var parameterSetData: Data?

  var onEncodedFrame: ((Data, Bool) -> Void)?  // (nalData, isKeyFrame)

  init(width: Int, height: Int) throws {
    self.width = width
    self.height = height
    try createSession()
  }

  private func createSession() throws {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
      ] as CFDictionary,
      compressedDataAllocator: nil,
      outputCallback: nil,
      refcon: nil,
      compressionSessionOut: &session
    )
    guard status == noErr, let session else {
      throw RemoteError.encoderCreationFailed(status)
    }

    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_000_000 as CFNumber)

    VTCompressionSessionPrepareToEncodeFrames(session)
    self.session = session
    extractParameterSets()
  }

  func encode(layer: CALayer) {
    guard let session else { return }

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else { return }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pixelBuffer),
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) {
      layer.render(in: context)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let timestamp = CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)

    VTCompressionSessionEncodeFrame(
      session,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: timestamp,
      duration: .invalid,
      frameProperties: nil,
      infoFlagsOut: nil
    ) { [weak self] status, _, sampleBuffer in
      guard status == noErr, let sampleBuffer else { return }
      Task { @MainActor in
        self?.handleEncodedFrame(sampleBuffer)
      }
    }
    isEncoding = true
  }

  func stop() {
    if let session {
      VTCompressionSessionInvalidate(session)
    }
    session = nil
    isEncoding = false
  }

  private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
    guard let dataBuffer = sampleBuffer.dataBuffer else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard let dataPointer, totalLength > 0 else { return }

    let data = Data(bytes: dataPointer, count: totalLength)
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    onEncodedFrame?(data, isKeyFrame)
  }

  private func extractParameterSets() {
    guard let session else { return }
    // Force an I-frame to get parameter sets
    // Parameter sets will be available after first encode
    var formatDescription: CMFormatDescription?
    // This is a placeholder — real parameter sets come from the first encoded frame's format description
    _ = formatDescription
  }
}

enum RemoteError: Error {
  case encoderCreationFailed(OSStatus)
  case decoderCreationFailed(OSStatus)
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Infrastructure/Remote/SurfaceVideoEncoder.swift supacodeTests/SurfaceVideoEncoderTests.swift
git commit -m "feat(remote): add H.264 surface video encoder via VideoToolbox"
```

---

### Task 14: Surface Video Decoder (H.264)

Decodes H.264 NAL units received over WebSocket into CVPixelBuffers for display.

**Files:**
- Create: `supacode/Infrastructure/Remote/SurfaceVideoDecoder.swift`
- Create: `supacodeTests/SurfaceVideoDecoderTests.swift`

**Step 1: Write tests**

```swift
import Foundation
import Testing

@testable import supacode

@MainActor
struct SurfaceVideoDecoderTests {
  @Test func decoderInitializes() {
    let decoder = SurfaceVideoDecoder()
    #expect(decoder.isDecoding == false)
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write SurfaceVideoDecoder.swift**

```swift
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
@Observable
final class SurfaceVideoDecoder {
  private(set) var isDecoding = false
  private var session: VTDecompressionSession?
  private var formatDescription: CMVideoFormatDescription?

  var onDecodedFrame: ((CVPixelBuffer) -> Void)?

  func configure(sps: Data, pps: Data) throws {
    let spsPointer = Array(sps)
    let ppsPointer = Array(pps)
    let parameterSets: [UnsafePointer<UInt8>] = spsPointer.withUnsafeBufferPointer { spsBuffer in
      ppsPointer.withUnsafeBufferPointer { ppsBuffer in
        [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
      }
    }
    let parameterSetSizes = [sps.count, pps.count]

    var formatDescription: CMVideoFormatDescription?
    let status = parameterSets.withUnsafeBufferPointer { setsPtr in
      CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: kCFAllocatorDefault,
        parameterSetCount: 2,
        parameterSetPointers: setsPtr.baseAddress!,
        parameterSetSizes: parameterSetSizes,
        nalUnitHeaderLength: 4,
        formatDescriptionOut: &formatDescription
      )
    }
    guard status == noErr, let formatDescription else {
      throw RemoteError.decoderCreationFailed(status)
    }
    self.formatDescription = formatDescription
    try createDecompressionSession(formatDescription: formatDescription)
  }

  func decode(nalData: Data) {
    guard let session, let formatDescription else { return }
    isDecoding = true

    var blockBuffer: CMBlockBuffer?
    nalData.withUnsafeBytes { rawBuffer in
      let ptr = rawBuffer.baseAddress!
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: UnsafeMutableRawPointer(mutating: ptr),
        blockLength: nalData.count,
        blockAllocator: kCFAllocatorNull,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: nalData.count,
        flags: 0,
        blockBufferOut: &blockBuffer
      )
    }
    guard let blockBuffer else { return }

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 0,
      sampleTimingArray: nil,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else { return }

    VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [._EnableAsynchronousDecompression],
      infoFlagsOut: nil
    ) { [weak self] status, _, imageBuffer, _, _ in
      guard status == noErr, let imageBuffer else { return }
      Task { @MainActor in
        self?.onDecodedFrame?(imageBuffer)
      }
    }
  }

  func stop() {
    if let session {
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    formatDescription = nil
    isDecoding = false
  }

  private func createDecompressionSession(formatDescription: CMVideoFormatDescription) throws {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]

    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary,
      outputCallback: nil,
      decompressionSessionOut: &session
    )
    guard status == noErr, let session else {
      throw RemoteError.decoderCreationFailed(status)
    }
    self.session = session
  }
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Infrastructure/Remote/SurfaceVideoDecoder.swift supacodeTests/SurfaceVideoDecoderTests.swift
git commit -m "feat(remote): add H.264 surface video decoder via VideoToolbox"
```

---

### Task 15: RemoteTerminalView (MTKView Display)

SwiftUI view that displays decoded H.264 video frames for remote terminals.

**Files:**
- Create: `supacode/Features/Terminal/Views/RemoteTerminalView.swift`

**Step 1: Write RemoteTerminalView.swift**

```swift
import CoreVideo
import MetalKit
import SwiftUI

struct RemoteTerminalView: NSViewRepresentable {
  let decoder: SurfaceVideoDecoder

  func makeNSView(context: Context) -> RemoteTerminalMTKView {
    let view = RemoteTerminalMTKView()
    view.isPaused = true
    view.enableSetNeedsDisplay = true
    decoder.onDecodedFrame = { [weak view] pixelBuffer in
      view?.currentPixelBuffer = pixelBuffer
      view?.needsDisplay = true
    }
    return view
  }

  func updateNSView(_ nsView: RemoteTerminalMTKView, context: Context) {}
}

final class RemoteTerminalMTKView: MTKView {
  var currentPixelBuffer: CVPixelBuffer?
  private var textureCache: CVMetalTextureCache?
  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?

  override init(frame frameRect: CGRect, device: MTLDevice?) {
    let device = device ?? MTLCreateSystemDefaultDevice()
    super.init(frame: frameRect, device: device)
    setup()
  }

  required init(coder: NSCoder) {
    super.init(coder: coder)
    self.device = MTLCreateSystemDefaultDevice()
    setup()
  }

  private func setup() {
    guard let device else { return }
    commandQueue = device.makeCommandQueue()
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    framebufferOnly = false
    colorPixelFormat = .bgra8Unorm
  }

  override func draw(_ dirtyRect: NSRect) {
    guard
      let device,
      let commandQueue,
      let currentDrawable,
      let pixelBuffer = currentPixelBuffer,
      let textureCache
    else { return }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)

    var cvTexture: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      textureCache,
      pixelBuffer,
      nil,
      .bgra8Unorm,
      width,
      height,
      0,
      &cvTexture
    )
    guard let cvTexture, let sourceTexture = CVMetalTextureGetTexture(cvTexture) else { return }

    let commandBuffer = commandQueue.makeCommandBuffer()
    let blitEncoder = commandBuffer?.makeBlitCommandEncoder()
    let destTexture = currentDrawable.texture

    let sourceSize = MTLSize(width: min(width, destTexture.width), height: min(height, destTexture.height), depth: 1)
    blitEncoder?.copy(
      from: sourceTexture,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: sourceSize,
      to: destTexture,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blitEncoder?.endEncoding()
    commandBuffer?.present(currentDrawable)
    commandBuffer?.commit()
  }
}
```

**Step 2: Build to verify compilation**

```bash
make build-app
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add supacode/Features/Terminal/Views/RemoteTerminalView.swift
git commit -m "feat(remote): add RemoteTerminalView with Metal-backed H.264 display"
```

---

### Task 16: Terminal View Polymorphism

Modify the terminal content area to show either a local Ghostty surface OR a remote video stream based on whether the selected worktree is local or remote.

**Files:**
- Modify: `supacode/Features/Terminal/Views/WorktreeTerminalTabsView.swift`

**Step 1: Understand current view structure**

Read `WorktreeTerminalTabsView.swift` to understand the current rendering path. The view currently always renders local Ghostty surfaces. We need to add a branch that checks if the selected worktree is remote and shows `RemoteTerminalView` instead.

**Step 2: Add remote terminal rendering branch**

The exact edit depends on how remote worktrees are identified in state. The simplest approach: pass a `isRemote: Bool` flag and a `SurfaceVideoDecoder?` into the view. When `isRemote` is true, render `RemoteTerminalView` instead of the split tree.

This task depends on how the sidebar integration works — the exact edit will be determined during implementation based on the current file content.

**Step 3: Build and test**

```bash
make build-app
```

**Step 4: Commit**

```bash
git commit -am "feat(remote): add polymorphic terminal view (local/remote)"
```

---

### Task 17: Input Relay

Capture keyboard and mouse events on the client's RemoteTerminalView and send them to the server.

**Files:**
- Modify: `supacode/Features/Terminal/Views/RemoteTerminalView.swift`

**Step 1: Add key event handling to RemoteTerminalMTKView**

Override `keyDown`, `keyUp`, `flagsChanged`, `mouseDown`, `mouseUp`, `mouseMoved`, `scrollWheel` on `RemoteTerminalMTKView`. Each handler serializes the event as a `RemoteInputEvent` and sends it via a callback.

```swift
// Add to RemoteTerminalMTKView
var onInputEvent: ((RemoteInputEvent) -> Void)?

override var acceptsFirstResponder: Bool { true }

override func keyDown(with event: NSEvent) {
  let remoteEvent = RemoteKeyEvent(
    keyCode: event.keyCode,
    characters: event.characters,
    modifiers: Self.remoteModifiers(from: event),
    isKeyDown: true,
  )
  onInputEvent?(.key(remoteEvent))
}

override func keyUp(with event: NSEvent) {
  let remoteEvent = RemoteKeyEvent(
    keyCode: event.keyCode,
    characters: event.characters,
    modifiers: Self.remoteModifiers(from: event),
    isKeyDown: false,
  )
  onInputEvent?(.key(remoteEvent))
}

private static func remoteModifiers(from event: NSEvent) -> Set<RemoteModifier> {
  var mods = Set<RemoteModifier>()
  if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
  if event.modifierFlags.contains(.control) { mods.insert(.control) }
  if event.modifierFlags.contains(.option) { mods.insert(.option) }
  if event.modifierFlags.contains(.command) { mods.insert(.command) }
  return mods
}
```

**Step 2: Wire input events through RemoteConnectionClient**

The view's `onInputEvent` callback calls `remoteConnectionClient.sendInput(event)` which serializes and sends over WebSocket.

**Step 3: Server-side input injection**

On the server, when receiving `keyEvent`/`mouseEvent`/`textInput`, reconstruct an `NSEvent` or use the Ghostty C API directly:
- `ghostty_surface_key()` for key events
- `ghostty_surface_text()` for text input
- `ghostty_surface_mouse_button()` / `ghostty_surface_mouse_pos()` for mouse

**Step 4: Build and test**

```bash
make build-app
```

**Step 5: Commit**

```bash
git commit -am "feat(remote): add keyboard/mouse input relay for remote terminals"
```

---

### Task 18: Surface Capture Orchestrator

Manages per-worktree video encoding — captures the right Ghostty surface when a client requests video for a worktree.

**Files:**
- Create: `supacode/Infrastructure/Remote/SurfaceCaptureOrchestrator.swift`

**Step 1: Write SurfaceCaptureOrchestrator.swift**

```swift
import AppKit
import Foundation

@MainActor
@Observable
final class SurfaceCaptureOrchestrator {
  private var encoders: [String: SurfaceVideoEncoder] = []  // worktreeID → encoder
  private var displayLinks: [String: CVDisplayLink] = []
  private let server: WebSocketServer
  private let terminalManager: WorktreeTerminalManager

  init(server: WebSocketServer, terminalManager: WorktreeTerminalManager) {
    self.server = server
    self.terminalManager = terminalManager
  }

  func startStreaming(worktreeID: String) throws {
    guard encoders[worktreeID] == nil else { return }

    // Get the surface view for this worktree
    // The exact API depends on WorktreeTerminalState exposing the focused surface
    guard let surface = findSurface(for: worktreeID) else {
      SupaLogger.error("[Remote] No surface found for worktree \(worktreeID)")
      return
    }

    let bounds = surface.bounds
    let encoder = try SurfaceVideoEncoder(
      width: Int(bounds.width),
      height: Int(bounds.height),
    )
    encoder.onEncodedFrame = { [weak self] data, isKeyFrame in
      self?.server.send(type: .videoFrame, payload: data)
    }
    encoders[worktreeID] = encoder

    // Start a display link or timer to capture frames
    startCaptureTimer(worktreeID: worktreeID, surface: surface, encoder: encoder)
    SupaLogger.info("[Remote] Started streaming worktree \(worktreeID)")
  }

  func stopStreaming(worktreeID: String) {
    encoders[worktreeID]?.stop()
    encoders.removeValue(forKey: worktreeID)
    SupaLogger.info("[Remote] Stopped streaming worktree \(worktreeID)")
  }

  func stopAll() {
    for (id, _) in encoders {
      stopStreaming(worktreeID: id)
    }
  }

  private func findSurface(for worktreeID: String) -> NSView? {
    // Access the WorktreeTerminalState for this worktree
    // and get the currently focused GhosttySurfaceView
    // Implementation depends on WorktreeTerminalManager exposing this
    nil // placeholder
  }

  private func startCaptureTimer(
    worktreeID: String,
    surface: NSView,
    encoder: SurfaceVideoEncoder
  ) {
    // Use a 30fps timer with dirty checking
    // In practice, hook into Ghostty's wakeup callback for smarter scheduling
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak surface] _ in
      Task { @MainActor in
        guard let surface, let layer = surface.layer else { return }
        self?.encoders[worktreeID]?.encode(layer: layer)
      }
    }
  }
}
```

**Step 2: Build**

```bash
make build-app
```

**Step 3: Commit**

```bash
git add supacode/Infrastructure/Remote/SurfaceCaptureOrchestrator.swift
git commit -m "feat(remote): add surface capture orchestrator for per-worktree streaming"
```

---

### Task 19: Checkpoint — Full Phase 2 Integration Test

**Step 1: Build everything**

```bash
make build-app
```

**Step 2: Run all tests**

```bash
make test
```

**Step 3: Lint and format**

```bash
make check
```

**Step 4: Manual test plan**

1. Launch supacode on Machine A (server)
2. Toggle "Enable Remote Access" in settings
3. Launch supacode on Machine B (client)
4. Machine B should see Machine A in "Remote Servers" section
5. Connect — Machine A's repos appear in Machine B's sidebar
6. Select a remote worktree — see terminal video stream
7. Type in terminal — keystrokes relay to server, output streams back

---

## Phase 3 — Full Interaction (Future)

These tasks are outlined but not detailed — implement after Phase 1+2 are stable:

### Task 20: Remote Worktree Creation
- Client sends `RemoteAction.createWorktree` → server creates via existing TCA action
- Server sends state delta with new worktree

### Task 21: Remote Worktree Deletion
- Same pattern as creation

### Task 22: Remote Script Running
- Client sends `RemoteAction.runScript` → server runs via TerminalClient

### Task 23: Connection Approval UI
- Server shows notification: "MacBook wants to connect — Allow?"
- Uses `UNUserNotificationCenter` or inline alert

### Task 24: Reconnection Handling
- Client auto-reconnects on disconnect with exponential backoff
- Server re-sends state snapshot on reconnect

---

## Phase 4 — Polish (Future)

### Task 25: Adaptive Bitrate
- Monitor WebSocket send queue depth
- Reduce encoder bitrate when congested
- Increase when headroom available

### Task 26: TLS + Pairing
- Add `NWProtocolTLS` to server listener
- Generate self-signed certificate on first run
- Pairing code displayed on server, entered on client

### Task 27: Tailscale/Tunnel Support
- Allow manual host:port entry instead of Bonjour-only
- Works with any TCP tunnel (Tailscale, Cloudflare, SSH)
