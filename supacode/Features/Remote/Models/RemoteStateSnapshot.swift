import Foundation

nonisolated struct RemoteStateSnapshot: Codable, Equatable, Sendable {
  let repositories: [RemoteRepository]
  let selectedWorktreeID: String?
}

nonisolated struct RemoteRepository: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let worktrees: [RemoteWorktree]
}

nonisolated struct RemoteWorktree: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let detail: String
  let tabs: [RemoteTab]
  let info: RemoteWorktreeInfo?
  let taskStatus: RemoteTaskStatus

  init(
    id: String,
    name: String,
    detail: String,
    tabs: [RemoteTab],
    info: RemoteWorktreeInfo?,
    taskStatus: RemoteTaskStatus
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.tabs = tabs
    self.info = info
    self.taskStatus = taskStatus
  }

  init(
    from worktree: Worktree,
    tabs: [RemoteTab],
    info: RemoteWorktreeInfo?,
    taskStatus: RemoteTaskStatus
  ) {
    self.id = worktree.id
    self.name = worktree.name
    self.detail = worktree.detail
    self.tabs = tabs
    self.info = info
    self.taskStatus = taskStatus
  }
}

nonisolated struct RemoteTab: Codable, Equatable, Sendable {
  let id: UUID
  let title: String
  let isDirty: Bool
}

nonisolated struct RemoteWorktreeInfo: Codable, Equatable, Sendable {
  let addedLines: Int?
  let removedLines: Int?
  let pullRequestNumber: Int?
  let pullRequestTitle: String?
  let pullRequestState: String?

  init(
    addedLines: Int? = nil,
    removedLines: Int? = nil,
    pullRequestNumber: Int? = nil,
    pullRequestTitle: String? = nil,
    pullRequestState: String? = nil
  ) {
    self.addedLines = addedLines
    self.removedLines = removedLines
    self.pullRequestNumber = pullRequestNumber
    self.pullRequestTitle = pullRequestTitle
    self.pullRequestState = pullRequestState
  }

  init(from info: WorktreeInfoEntry) {
    self.addedLines = info.addedLines
    self.removedLines = info.removedLines
    self.pullRequestNumber = info.pullRequest?.number
    self.pullRequestTitle = info.pullRequest?.title
    self.pullRequestState = info.pullRequest?.state
  }
}

enum RemoteTaskStatus: String, Codable, Equatable, Sendable {
  case idle
  case running
}
