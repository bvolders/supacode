import Foundation

enum RemoteMessageType: UInt8, Codable, Sendable {
  // Control
  case hello = 0x01
  case welcome = 0x02
  case ping = 0x03
  case pong = 0x04

  // State sync
  case stateSnapshot = 0x10
  case stateDelta = 0x11
  case action = 0x12

  // Terminal video
  case videoConfig = 0x20
  case videoFrame = 0x21
  case videoRequest = 0x22
  case videoStop = 0x23

  // Terminal input
  case keyEvent = 0x30
  case mouseEvent = 0x31
  case textInput = 0x32
  case resize = 0x33
}

struct RemoteFrameHeader: Sendable {
  let type: RemoteMessageType
  let length: Int
}

nonisolated struct HelloMessage: Codable, Sendable {
  let protocolVersion: Int
  let appVersion: String
  let clientName: String
  var pairingCode: String?
}

nonisolated struct WelcomeMessage: Codable, Sendable {
  let protocolVersion: Int
  let serverName: String
}

nonisolated struct RemoteVideoPayload: Codable, Sendable {
  let worktreeID: String
}
