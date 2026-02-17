import Foundation
@preconcurrency import Network

@MainActor
@Observable
final class WebSocketServer {
  private(set) var isClientConnected = false
  private(set) var pendingSendCount = 0
  private var connection: NWConnection?
  private let advertiser: BonjourAdvertiser
  private let logger = SupaLogger("Remote")
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
  }

  func stop() {
    disconnect()
    advertiser.stop()
  }

  func send(type: RemoteMessageType, payload: Data) {
    guard let connection else { return }
    var frame = Self.encodeFrameHeader(type: type, payloadLength: payload.count)
    frame.append(payload)
    let metadata = NWProtocolWebSocket.Metadata(
      opcode: type == .videoFrame || type == .videoConfig ? .binary : .text,
    )
    let context = NWConnection.ContentContext(
      identifier: "remote",
      metadata: [metadata],
    )
    pendingSendCount += 1
    connection.send(
      content: frame,
      contentContext: context,
      isComplete: true,
      completion: .contentProcessed { [weak self] error in
        Task { @MainActor in
          self?.pendingSendCount -= 1
          if let error {
            self?.logger.warning("Send error: \(error)")
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

  func disconnect() {
    connection?.cancel()
    connection = nil
    isClientConnected = false
  }

  private func handleNewConnection(_ newConnection: NWConnection) {
    if isClientConnected {
      logger.info("Rejecting connection — already have a client")
      newConnection.cancel()
      return
    }
    connection = newConnection
    isClientConnected = true
    logger.info("Client connected")

    newConnection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self else { return }
        switch state {
        case .failed(let error):
          self.logger.warning("Connection failed: \(error)")
          self.disconnect()
        case .cancelled:
          self.disconnect()
        default:
          break
        }
      }
    }
    newConnection.start(queue: .main)
    receiveMessages(on: newConnection)
  }

  private func receiveMessages(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      Task { @MainActor in
        guard let self else { return }
        if let error {
          self.logger.warning("Receive error: \(error)")
          self.disconnect()
          return
        }
        if let data, data.count >= 5,
          let header = Self.decodeFrameHeader(from: data)
        {
          let payload = data.subdata(in: 5..<data.count)
          self.onMessageReceived?(header.type, payload)
        }
        if self.isClientConnected {
          self.receiveMessages(on: connection)
        }
      }
    }
  }
}
