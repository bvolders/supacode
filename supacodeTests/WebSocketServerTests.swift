import Foundation
import Testing

@testable import supacode

@MainActor
struct WebSocketServerTests {
  @Test func serverInitializesDisconnected() {
    let server = WebSocketServer()
    #expect(server.isClientConnected == false)
  }

  @Test func frameHeaderEncoding() {
    let data = WebSocketServer.encodeFrameHeader(
      type: .stateSnapshot,
      payloadLength: 256,
    )
    #expect(data.count == 5)
    #expect(data[0] == RemoteMessageType.stateSnapshot.rawValue)
    let length = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    #expect(length == 256)
  }

  @Test func frameHeaderDecoding() {
    let data = WebSocketServer.encodeFrameHeader(type: .hello, payloadLength: 42)
    let header = WebSocketServer.decodeFrameHeader(from: data)
    #expect(header?.type == .hello)
    #expect(header?.length == 42)
  }
}
