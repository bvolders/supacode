import Foundation

enum RemoteAction: Codable, Equatable, Sendable {
  case selectWorktree(id: String)
  case createWorktree(repositoryID: String, branchName: String)
  case deleteWorktree(id: String)
  case createTab(worktreeID: String)
  case closeTab(worktreeID: String, tabID: UUID)
  case selectTab(worktreeID: String, tabID: UUID)
  case runScript(worktreeID: String, script: String)
  case stopRunScript(worktreeID: String)
}

enum RemoteInputEvent: Codable, Equatable, Sendable {
  case key(RemoteKeyEvent)
  case mouse(RemoteMouseEvent)
  case text(RemoteTextInput)
  case resize(RemoteResize)
}

nonisolated struct RemoteKeyEvent: Codable, Equatable, Sendable {
  let keyCode: UInt16
  let characters: String?
  let modifiers: Set<RemoteModifier>
  let isKeyDown: Bool
}

enum RemoteModifier: String, Codable, Sendable {
  case shift
  case control
  case option
  case command
}

nonisolated struct RemoteMouseEvent: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
  let button: Int
  let isDown: Bool
  let modifiers: Set<RemoteModifier>
}

nonisolated struct RemoteTextInput: Codable, Equatable, Sendable {
  let text: String
  let worktreeID: String
}

nonisolated struct RemoteResize: Codable, Equatable, Sendable {
  let worktreeID: String
  let width: UInt32
  let height: UInt32
}
