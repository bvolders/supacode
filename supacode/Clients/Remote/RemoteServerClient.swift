import ComposableArchitecture
import Foundation

struct RemoteServerClient {
  var start: @MainActor @Sendable () throws -> Void
  var stop: @MainActor @Sendable () -> Void
  var disconnectClient: @MainActor @Sendable () -> Void
  var isRunning: @MainActor @Sendable () -> Bool
  var isClientConnected: @MainActor @Sendable () -> Bool
  var sendWelcome: @MainActor @Sendable () -> Void
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

extension RemoteServerClient {
  @MainActor
  static func live(server: WebSocketServer) -> Self {
    RemoteServerClient(
      start: {
        try server.start()
      },
      stop: {
        server.stop()
      },
      disconnectClient: {
        server.disconnect()
      },
      isRunning: {
        server.isRunning
      },
      isClientConnected: {
        server.isClientConnected
      },
      sendWelcome: {
        let welcome = WelcomeMessage(
          protocolVersion: 1,
          serverName: Host.current().localizedName ?? "Supacode Server"
        )
        server.sendJSON(type: .welcome, value: welcome)
      },
      sendStateSnapshot: { snapshot in
        server.sendJSON(type: .stateSnapshot, value: snapshot)
      },
      events: {
        AsyncStream { continuation in
          server.onMessageReceived = { type, data in
            if let event = Self.decodeServerEvent(type: type, data: data) {
              continuation.yield(event)
            }
          }
          server.onClientDisconnected = {
            continuation.yield(.clientDisconnected)
          }
          continuation.onTermination = { _ in
            Task { @MainActor in
              server.onMessageReceived = nil
              server.onClientDisconnected = nil
            }
          }
        }
      }
    )
  }

  private static func decodeServerEvent(type: RemoteMessageType, data: Data) -> RemoteServerEvent? {
    switch type {
    case .hello:
      guard let hello = try? JSONDecoder().decode(HelloMessage.self, from: data) else { return nil }
      return .clientConnected(name: hello.clientName)
    case .action:
      guard let action = try? JSONDecoder().decode(RemoteAction.self, from: data) else { return nil }
      return .actionReceived(action)
    case .keyEvent, .mouseEvent, .textInput, .resize:
      guard let input = decodeInputEvent(type: type, data: data) else { return nil }
      return .inputReceived(input)
    case .videoRequest:
      guard let payload = try? JSONDecoder().decode(RemoteVideoPayload.self, from: data) else { return nil }
      return .videoRequested(worktreeID: payload.worktreeID)
    case .videoStop:
      guard let payload = try? JSONDecoder().decode(RemoteVideoPayload.self, from: data) else { return nil }
      return .videoStopped(worktreeID: payload.worktreeID)
    default:
      return nil
    }
  }

  private static func decodeInputEvent(type: RemoteMessageType, data: Data) -> RemoteInputEvent? {
    switch type {
    case .keyEvent:
      guard let key = try? JSONDecoder().decode(RemoteKeyEvent.self, from: data) else { return nil }
      return .key(key)
    case .mouseEvent:
      guard let mouse = try? JSONDecoder().decode(RemoteMouseEvent.self, from: data) else { return nil }
      return .mouse(mouse)
    case .textInput:
      guard let text = try? JSONDecoder().decode(RemoteTextInput.self, from: data) else { return nil }
      return .text(text)
    case .resize:
      guard let resize = try? JSONDecoder().decode(RemoteResize.self, from: data) else { return nil }
      return .resize(resize)
    default:
      return nil
    }
  }
}

extension RemoteServerClient: DependencyKey {
  static let liveValue = RemoteServerClient(
    start: { fatalError("RemoteServerClient.start not configured") },
    stop: { fatalError("RemoteServerClient.stop not configured") },
    disconnectClient: { fatalError("RemoteServerClient.disconnectClient not configured") },
    isRunning: { false },
    isClientConnected: { false },
    sendWelcome: {},
    sendStateSnapshot: { _ in },
    events: { AsyncStream { $0.finish() } },
  )

  static let testValue = RemoteServerClient(
    start: {},
    stop: {},
    disconnectClient: {},
    isRunning: { false },
    isClientConnected: { false },
    sendWelcome: {},
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
