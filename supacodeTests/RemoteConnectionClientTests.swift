import ComposableArchitecture
import Testing

@testable import supacode

@MainActor
struct RemoteConnectionClientTests {
  @Test func testValueDoesNotCrash() {
    let client = RemoteConnectionClient.testValue
    #expect(client.isConnected() == false)
    #expect(client.discoveredServers().isEmpty)
  }
}
