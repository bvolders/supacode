import ComposableArchitecture
import Foundation
import Network

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

extension RemoteConnectionClient {
  @MainActor
  static func live(client: WebSocketClient, browser: BonjourBrowser) -> Self {
    RemoteConnectionClient(
      startBrowsing: {
        browser.startBrowsing()
      },
      stopBrowsing: {
        browser.stopBrowsing()
      },
      discoveredServers: {
        browser.discoveredServers
      },
      connect: { server in
        client.connect(to: server)
      },
      disconnect: {
        client.disconnect()
      },
      isConnected: {
        client.isConnected
      },
      sendAction: { action in
        client.sendJSON(type: .action, value: action)
      },
      sendInput: { event in
        switch event {
        case .key(let key):
          client.sendJSON(type: .keyEvent, value: key)
        case .mouse(let mouse):
          client.sendJSON(type: .mouseEvent, value: mouse)
        case .text(let text):
          client.sendJSON(type: .textInput, value: text)
        case .resize(let resize):
          client.sendJSON(type: .resize, value: resize)
        }
      },
      requestVideoStream: { worktreeID in
        client.sendJSON(type: .videoRequest, value: RemoteVideoPayload(worktreeID: worktreeID))
      },
      stopVideoStream: { worktreeID in
        client.sendJSON(type: .videoStop, value: RemoteVideoPayload(worktreeID: worktreeID))
      },
      events: {
        AsyncStream { continuation in
          client.onMessageReceived = { type, data in
            if let event = Self.decodeConnectionEvent(type: type, data: data) {
              continuation.yield(event)
            }
          }
          client.onDisconnected = {
            continuation.yield(.disconnected)
          }
          browser.onServersChanged = { servers in
            continuation.yield(.serversChanged(servers))
          }
          continuation.onTermination = { _ in
            Task { @MainActor in
              client.onMessageReceived = nil
              client.onDisconnected = nil
              browser.onServersChanged = nil
            }
          }
        }
      }
    )
  }

  private static func decodeConnectionEvent(type: RemoteMessageType, data: Data) -> RemoteConnectionEvent? {
    switch type {
    case .welcome:
      guard let welcome = try? JSONDecoder().decode(WelcomeMessage.self, from: data) else { return nil }
      return .connected(serverName: welcome.serverName)
    case .stateSnapshot:
      guard let snapshot = try? JSONDecoder().decode(RemoteStateSnapshot.self, from: data) else { return nil }
      return .stateSnapshotReceived(snapshot)
    default:
      return nil
    }
  }
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
