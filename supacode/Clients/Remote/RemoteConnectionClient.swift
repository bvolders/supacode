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
