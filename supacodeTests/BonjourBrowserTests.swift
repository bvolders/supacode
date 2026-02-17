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
