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
