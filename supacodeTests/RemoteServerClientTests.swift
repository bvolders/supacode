import ComposableArchitecture
import Testing

@testable import supacode

@MainActor
struct RemoteServerClientTests {
  @Test func testValueDoesNotCrash() {
    let client = RemoteServerClient.testValue
    #expect(client.isRunning() == false)
  }
}
