import ComposableArchitecture
import Foundation

struct RemoteServerClient {
  var start: @MainActor @Sendable () throws -> Void
  var stop: @MainActor @Sendable () -> Void
  var disconnectClient: @MainActor @Sendable () -> Void
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
    disconnectClient: { fatalError("RemoteServerClient.disconnectClient not configured") },
    isRunning: { false },
    isClientConnected: { false },
    sendStateSnapshot: { _ in },
    events: { AsyncStream { $0.finish() } },
  )

  static let testValue = RemoteServerClient(
    start: {},
    stop: {},
    disconnectClient: {},
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
