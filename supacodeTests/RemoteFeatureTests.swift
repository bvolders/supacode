import ComposableArchitecture
import Testing

@testable import supacode

@MainActor
struct RemoteFeatureTests {
  @Test func toggleServerStartsAndStops() async {
    let startCalled = LockIsolated(false)
    let stopCalled = LockIsolated(false)
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteServerClient.start = { startCalled.withValue { $0 = true } }
      $0.remoteServerClient.stop = { stopCalled.withValue { $0 = true } }
      $0.remoteServerClient.events = { AsyncStream { $0.finish() } }
    }

    await store.send(.toggleServer) {
      $0.isServerEnabled = true
    }
    #expect(startCalled.value)

    await store.send(.toggleServer) {
      $0.isServerEnabled = false
    }
    #expect(stopCalled.value)
  }

  @Test func stateSnapshotUpdatesRemoteRepositories() async {
    let snapshot = RemoteStateSnapshot(
      repositories: [
        RemoteRepository(
          id: "/tmp/repo",
          name: "my-project",
          worktrees: [
            RemoteWorktree(
              id: "/tmp/repo/wt-main",
              name: "main",
              detail: "main",
              tabs: [],
              info: nil,
              taskStatus: .idle,
            ),
          ],
        ),
      ],
      selectedWorktreeID: nil,
    )

    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }

    await store.send(.remoteConnectionEvent(.stateSnapshotReceived(snapshot))) {
      $0.remoteRepositories = snapshot.repositories
    }
  }

  @Test func disconnectClearsRemoteState() async {
    var state = RemoteFeature.State()
    state.connectedServerName = "Test Mac"
    state.remoteRepositories = [
      RemoteRepository(id: "r1", name: "repo", worktrees: []),
    ]
    state.remoteSelectedWorktreeID = "wt1"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.disconnect = {}
    }

    await store.send(.disconnect) {
      $0.connectedServerName = nil
      $0.remoteRepositories = []
      $0.remoteSelectedWorktreeID = nil
    }
  }

  @Test func serverEventClientConnectedUpdatesState() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }

    await store.send(.remoteServerEvent(.clientConnected(name: "iPhone"))) {
      $0.connectedClientName = "iPhone"
    }
  }

  @Test func serverEventClientDisconnectedClearsClientName() async {
    var state = RemoteFeature.State()
    state.connectedClientName = "iPhone"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    }

    await store.send(.remoteServerEvent(.clientDisconnected)) {
      $0.connectedClientName = nil
    }
  }

  @Test func connectionEventConnectedSetsServerName() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }

    await store.send(.remoteConnectionEvent(.connected(serverName: "MacBook Pro"))) {
      $0.connectedServerName = "MacBook Pro"
    }
  }

  @Test func connectionEventDisconnectedClearsRemoteState() async {
    var state = RemoteFeature.State()
    state.connectedServerName = "MacBook Pro"
    state.remoteRepositories = [
      RemoteRepository(id: "r1", name: "repo", worktrees: []),
    ]
    state.remoteSelectedWorktreeID = "wt1"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    }

    await store.send(.remoteConnectionEvent(.disconnected)) {
      $0.connectedServerName = nil
      $0.remoteRepositories = []
      $0.remoteSelectedWorktreeID = nil
    }
  }

  @Test func startBrowsingSetsFlagAndCallsClient() async {
    let browseCalled = LockIsolated(false)
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.startBrowsing = { browseCalled.withValue { $0 = true } }
      $0.remoteConnectionClient.events = { AsyncStream { $0.finish() } }
    }

    await store.send(.startBrowsing) {
      $0.isBrowsing = true
    }
    #expect(browseCalled.value)
  }

  @Test func stopBrowsingClearsFlagAndCallsClient() async {
    let stopCalled = LockIsolated(false)
    var state = RemoteFeature.State()
    state.isBrowsing = true

    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.stopBrowsing = { stopCalled.withValue { $0 = true } }
    }

    await store.send(.stopBrowsing) {
      $0.isBrowsing = false
    }
    #expect(stopCalled.value)
  }

  @Test func sendRemoteActionForwardsToClient() async {
    let sentAction = LockIsolated<RemoteAction?>(nil)
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.sendAction = { action in
        sentAction.withValue { $0 = action }
      }
    }

    await store.send(.sendRemoteAction(.selectWorktree(id: "wt-1")))
    #expect(sentAction.value == .selectWorktree(id: "wt-1"))
  }

  @Test func toggleServerOffClearsConnectedClient() async {
    var state = RemoteFeature.State()
    state.isServerEnabled = true
    state.connectedClientName = "iPhone"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteServerClient.stop = {}
    }

    await store.send(.toggleServer) {
      $0.isServerEnabled = false
      $0.connectedClientName = nil
    }
  }
}
