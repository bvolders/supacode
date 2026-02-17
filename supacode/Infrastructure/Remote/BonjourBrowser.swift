import Foundation
@preconcurrency import Network

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
  private let logger = SupaLogger("Remote")
  var onServersChanged: (([DiscoveredServer]) -> Void)?

  func startBrowsing() {
    let params = NWParameters()
    params.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjour(type: Self.serviceType, domain: nil),
      using: params,
    )
    browser.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self else { return }
        switch state {
        case .ready:
          self.isBrowsing = true
          self.logger.info("Browsing for servers")
        case .failed(let error):
          self.logger.warning("Browser failed: \(error)")
          self.isBrowsing = false
        case .cancelled:
          self.isBrowsing = false
        default:
          break
        }
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor in
        guard let self else { return }
        self.discoveredServers = results.compactMap { result in
          guard case .service(let name, _, _, _) = result.endpoint else { return nil }
          return DiscoveredServer(
            id: name,
            name: name,
            endpoint: result.endpoint,
          )
        }
        self.onServersChanged?(self.discoveredServers)
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
