import Foundation
import Network

@MainActor
@Observable
final class WebSocketClient {
  private(set) var isConnected = false
  private(set) var connectedServerName: String?
  private var connection: NWConnection?
  private let logger = SupaLogger("Remote")
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
        guard let self else { return }
        switch state {
        case .ready:
          self.isConnected = true
          self.connectedServerName = server.name
          self.logger.info("Connected to '\(server.name)'")
          self.sendHello()
        case .failed(let error):
          self.logger.warning("Connection failed: \(error)")
          self.handleDisconnect()
        case .cancelled:
          self.handleDisconnect()
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
    var frame = Self.encodeFrameHeader(type: type, payloadLength: payload.count)
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
      completion: .contentProcessed { [weak self] error in
        if let error {
          Task { @MainActor in
            self?.logger.warning("Client send error: \(error)")
          }
        }
      },
    )
  }

  func sendJSON<T: Encodable>(type: RemoteMessageType, value: T) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    send(type: type, payload: data)
  }

  static func encodeFrameHeader(type: RemoteMessageType, payloadLength: Int) -> Data {
    WebSocketServer.encodeFrameHeader(type: type, payloadLength: payloadLength)
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
        guard let self else { return }
        if let error {
          self.logger.warning("Client receive error: \(error)")
          self.handleDisconnect()
          return
        }
        if let data, data.count >= 5,
          let header = Self.decodeFrameHeader(from: data)
        {
          let payload = data.subdata(in: 5..<data.count)
          self.onMessageReceived?(header.type, payload)
        }
        if self.isConnected {
          self.receiveMessages(on: connection)
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
