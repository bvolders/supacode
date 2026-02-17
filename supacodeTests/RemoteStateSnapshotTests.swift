import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteStateSnapshotTests {
  @Test func snapshotRoundTrips() throws {
    let snapshot = RemoteStateSnapshot(
      repositories: [
        RemoteRepository(
          id: "/tmp/repo",
          name: "my-project",
          worktrees: [
            RemoteWorktree(
              id: "/tmp/repo/wt-feature",
              name: "feature",
              detail: "feature/login",
              tabs: [
                RemoteTab(id: UUID(), title: "zsh", isDirty: false)
              ],
              info: RemoteWorktreeInfo(
                addedLines: 42,
                removedLines: 10,
                pullRequestNumber: 123,
                pullRequestTitle: "Add login",
                pullRequestState: "OPEN",
              ),
              taskStatus: .idle,
            ),
          ],
        ),
      ],
      selectedWorktreeID: "/tmp/repo/wt-feature",
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(RemoteStateSnapshot.self, from: data)
    #expect(decoded.repositories.count == 1)
    #expect(decoded.repositories[0].worktrees[0].name == "feature")
    #expect(decoded.repositories[0].worktrees[0].info?.addedLines == 42)
    #expect(decoded.selectedWorktreeID == "/tmp/repo/wt-feature")
  }

  @Test func snapshotFromDomainModels() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-main",
      name: "main",
      detail: "main",
      workingDirectory: URL(filePath: "/tmp/repo/wt-main"),
      repositoryRootURL: URL(filePath: "/tmp/repo"),
    )
    let remote = RemoteWorktree(from: worktree, tabs: [], info: nil, taskStatus: .idle)
    #expect(remote.id == "/tmp/repo/wt-main")
    #expect(remote.name == "main")
  }
}
