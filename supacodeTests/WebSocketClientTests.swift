import Foundation
import Testing

@testable import supacode

@MainActor
struct WebSocketClientTests {
  @Test func clientInitializesDisconnected() {
    let client = WebSocketClient()
    #expect(client.isConnected == false)
    #expect(client.connectedServerName == nil)
  }

  @Test func frameHeaderEncodingMatchesServer() {
    let serverEncoded = WebSocketServer.encodeFrameHeader(type: .action, payloadLength: 100)
    let decoded = WebSocketClient.decodeFrameHeader(from: serverEncoded)
    #expect(decoded?.type == .action)
    #expect(decoded?.length == 100)
  }
}
