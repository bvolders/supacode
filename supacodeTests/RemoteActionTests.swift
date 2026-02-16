import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteActionTests {
  @Test func selectWorktreeRoundTrips() throws {
    let action = RemoteAction.selectWorktree(id: "/tmp/repo/wt-feature")
    let data = try JSONEncoder().encode(action)
    let decoded = try JSONDecoder().decode(RemoteAction.self, from: data)
    #expect(decoded == action)
  }

  @Test func createWorktreeRoundTrips() throws {
    let action = RemoteAction.createWorktree(
      repositoryID: "/tmp/repo",
      branchName: "feature/login",
    )
    let data = try JSONEncoder().encode(action)
    let decoded = try JSONDecoder().decode(RemoteAction.self, from: data)
    #expect(decoded == action)
  }

  @Test func keyEventRoundTrips() throws {
    let action = RemoteInputEvent.key(
      RemoteKeyEvent(
        keyCode: 0,
        characters: "a",
        modifiers: [.shift],
        isKeyDown: true,
      )
    )
    let data = try JSONEncoder().encode(action)
    let decoded = try JSONDecoder().decode(RemoteInputEvent.self, from: data)
    #expect(decoded == action)
  }
}
