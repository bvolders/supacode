import Foundation
@preconcurrency import Network
import Security

@MainActor
@Observable
final class BonjourAdvertiser {
  nonisolated static let serviceType = "_supacode._tcp"
  nonisolated static let defaultPort: UInt16 = 9847

  let serverName: String
  private(set) var isAdvertising = false
  private var listener: NWListener?
  private let logger = SupaLogger("Remote")

  init(serverName: String) {
    self.serverName = serverName
  }

  func start(
    port: UInt16 = BonjourAdvertiser.defaultPort,
    tlsIdentity: SecIdentity? = nil,
    onNewConnection: @escaping @Sendable (NWConnection) -> Void
  ) throws {
    let params: NWParameters
    if let tlsIdentity {
      let tlsOptions = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(
        tlsOptions.securityProtocolOptions,
        sec_identity_create(tlsIdentity)!,
      )
      params = NWParameters(tls: tlsOptions)
    } else {
      params = NWParameters.tcp
    }
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
        guard let self else { return }
        switch state {
        case .ready:
          self.isAdvertising = true
          self.logger.info("Server advertising as '\(self.serverName)'")
        case .failed(let error):
          self.logger.warning("Listener failed: \(error)")
          self.isAdvertising = false
        case .cancelled:
          self.isAdvertising = false
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
