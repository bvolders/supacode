import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteProtocolTests {
  @Test func messageTypeRawValues() {
    #expect(RemoteMessageType.hello.rawValue == 0x01)
    #expect(RemoteMessageType.welcome.rawValue == 0x02)
    #expect(RemoteMessageType.stateSnapshot.rawValue == 0x10)
    #expect(RemoteMessageType.videoFrame.rawValue == 0x21)
    #expect(RemoteMessageType.keyEvent.rawValue == 0x30)
  }

  @Test func helloMessageRoundTrips() throws {
    let hello = HelloMessage(
      protocolVersion: 1,
      appVersion: "0.6.0",
      clientName: "Henry's MacBook",
    )
    let data = try JSONEncoder().encode(hello)
    let decoded = try JSONDecoder().decode(HelloMessage.self, from: data)
    #expect(decoded.protocolVersion == 1)
    #expect(decoded.clientName == "Henry's MacBook")
  }

  @Test func welcomeMessageRoundTrips() throws {
    let welcome = WelcomeMessage(
      protocolVersion: 1,
      serverName: "Henry's Mac Mini",
    )
    let data = try JSONEncoder().encode(welcome)
    let decoded = try JSONDecoder().decode(WelcomeMessage.self, from: data)
    #expect(decoded.serverName == "Henry's Mac Mini")
  }

  @Test func remoteFrameHeaderEncodesCorrectly() {
    let header = RemoteFrameHeader(
      type: .stateSnapshot,
      length: 1024,
    )
    var data = Data()
    data.append(header.type.rawValue)
    var len = UInt32(header.length).bigEndian
    data.append(Data(bytes: &len, count: 4))
    #expect(data.count == 5)
    #expect(data[0] == 0x10)
  }
}
