import ComposableArchitecture
import Network
import Testing

@testable import supacode

@MainActor
struct RemoteFeatureTests {
  private static let testServer = DiscoveredServer(
    id: "test-server",
    name: "Test Mac",
    endpoint: NWEndpoint.hostPort(host: "127.0.0.1", port: 9999),
  )

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
      RemoteRepository(id: "r1", name: "repo", worktrees: [])
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

  @Test func serverEventClientConnectedSetsPendingState() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }
    store.exhaustivity = .off
    await store.send(.remoteServerEvent(.clientConnected(name: "iPhone")))
    #expect(store.state.pendingConnectionName == "iPhone")
    #expect(store.state.activePairingCode?.count == 6)
    #expect(Int(store.state.activePairingCode ?? "") != nil)
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

  @Test func serverEventClientDisconnectedClearsPendingConnection() async {
    var state = RemoteFeature.State()
    state.pendingConnectionName = "iPhone"
    state.activePairingCode = "123456"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    }

    await store.send(.remoteServerEvent(.clientDisconnected)) {
      $0.pendingConnectionName = nil
      $0.activePairingCode = nil
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
      RemoteRepository(id: "r1", name: "repo", worktrees: [])
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

  // MARK: - Connection Approval Tests

  @Test func approveConnectionMovePendingToConnected() async {
    var state = RemoteFeature.State()
    state.pendingConnectionName = "iPhone"
    state.activePairingCode = "123456"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    }

    await store.send(.approveConnection) {
      $0.connectedClientName = "iPhone"
      $0.pendingConnectionName = nil
      $0.activePairingCode = nil
    }
  }

  @Test func approveConnectionDoesNothingWithoutPending() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }

    await store.send(.approveConnection)
  }

  @Test func denyConnectionClearsPendingAndDisconnectsClient() async {
    let disconnectClientCalled = LockIsolated(false)
    var state = RemoteFeature.State()
    state.pendingConnectionName = "iPhone"
    state.activePairingCode = "123456"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteServerClient.disconnectClient = { disconnectClientCalled.withValue { $0 = true } }
    }

    await store.send(.denyConnection) {
      $0.pendingConnectionName = nil
      $0.activePairingCode = nil
    }
    #expect(disconnectClientCalled.value)
  }

  @Test func toggleServerOffClearsPendingConnection() async {
    var state = RemoteFeature.State()
    state.isServerEnabled = true
    state.pendingConnectionName = "iPhone"
    state.activePairingCode = "123456"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteServerClient.stop = {}
    }

    await store.send(.toggleServer) {
      $0.isServerEnabled = false
      $0.pendingConnectionName = nil
      $0.activePairingCode = nil
    }
  }

  // MARK: - Pairing Code Tests

  @Test func clientConnectedGeneratesPairingCode() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }
    store.exhaustivity = .off
    await store.send(.remoteServerEvent(.clientConnected(name: "iPhone")))
    #expect(store.state.pendingConnectionName == "iPhone")
    #expect(store.state.activePairingCode?.count == 6)
    #expect(Int(store.state.activePairingCode ?? "") != nil)
  }

  @Test func approveConnectionClearsPairingCode() async {
    var state = RemoteFeature.State()
    state.pendingConnectionName = "iPhone"
    state.activePairingCode = "123456"
    let store = TestStore(initialState: state) {
      RemoteFeature()
    }
    await store.send(.approveConnection) {
      $0.connectedClientName = "iPhone"
      $0.pendingConnectionName = nil
      $0.activePairingCode = nil
    }
  }

  @Test func denyConnectionClearsPairingCode() async {
    let disconnectClientCalled = LockIsolated(false)
    var state = RemoteFeature.State()
    state.pendingConnectionName = "iPhone"
    state.activePairingCode = "123456"
    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteServerClient.disconnectClient = { disconnectClientCalled.withValue { $0 = true } }
    }
    await store.send(.denyConnection) {
      $0.pendingConnectionName = nil
      $0.activePairingCode = nil
    }
    #expect(disconnectClientCalled.value)
  }

  @Test func toggleServerOffClearsPairingCode() async {
    var state = RemoteFeature.State()
    state.isServerEnabled = true
    state.activePairingCode = "123456"
    state.pendingConnectionName = "iPhone"
    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteServerClient.stop = {}
    }
    await store.send(.toggleServer) {
      $0.isServerEnabled = false
      $0.pendingConnectionName = nil
      $0.activePairingCode = nil
    }
  }

  // MARK: - Reconnection Tests

  @Test func connectToServerSavesLastConnectedServer() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.connect = { _ in }
    }

    await store.send(.connectToServer(Self.testServer)) {
      $0.lastConnectedServer = Self.testServer
    }
  }

  @Test func disconnectEventTriggersReconnectWhenServerKnown() async {
    let clock = TestClock()
    let connectCalled = LockIsolated(false)

    var state = RemoteFeature.State()
    state.connectedServerName = "Test Mac"
    state.lastConnectedServer = Self.testServer

    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteConnectionClient.connect = { _ in connectCalled.withValue { $0 = true } }
    }

    await store.send(.remoteConnectionEvent(.disconnected)) {
      $0.connectedServerName = nil
      $0.remoteRepositories = []
      $0.remoteSelectedWorktreeID = nil
      $0.isReconnecting = true
    }

    await store.receive(\.attemptReconnect) {
      $0.reconnectAttempt = 1
    }

    await clock.advance(by: .seconds(1))
    #expect(connectCalled.value)
  }

  @Test func disconnectEventDoesNotReconnectWithoutLastServer() async {
    var state = RemoteFeature.State()
    state.connectedServerName = "Test Mac"

    let store = TestStore(initialState: state) {
      RemoteFeature()
    }

    await store.send(.remoteConnectionEvent(.disconnected)) {
      $0.connectedServerName = nil
      $0.remoteRepositories = []
      $0.remoteSelectedWorktreeID = nil
    }
  }

  @Test func manualDisconnectCancelsReconnection() async {
    var state = RemoteFeature.State()
    state.connectedServerName = "Test Mac"
    state.isReconnecting = true
    state.reconnectAttempt = 3
    state.lastConnectedServer = Self.testServer

    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.disconnect = {}
    }

    await store.send(.disconnect) {
      $0.isReconnecting = false
      $0.reconnectAttempt = 0
      $0.lastConnectedServer = nil
      $0.connectedServerName = nil
      $0.remoteRepositories = []
      $0.remoteSelectedWorktreeID = nil
    }
  }

  @Test func successfulReconnectResetsAttemptCounter() async {
    var state = RemoteFeature.State()
    state.isReconnecting = true
    state.reconnectAttempt = 5
    state.lastConnectedServer = Self.testServer

    let store = TestStore(initialState: state) {
      RemoteFeature()
    }

    await store.send(.remoteConnectionEvent(.connected(serverName: "Test Mac"))) {
      $0.connectedServerName = "Test Mac"
      $0.isReconnecting = false
      $0.reconnectAttempt = 0
    }
  }

  @Test func exponentialBackoffDelayCalculation() async {
    let clock = TestClock()
    let connectAttempts = LockIsolated(0)

    var state = RemoteFeature.State()
    state.isReconnecting = true
    state.lastConnectedServer = Self.testServer

    let store = TestStore(initialState: state) {
      RemoteFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteConnectionClient.connect = { _ in connectAttempts.withValue { $0 += 1 } }
    }

    // First attempt: 1 second delay
    await store.send(.attemptReconnect) {
      $0.reconnectAttempt = 1
    }
    await clock.advance(by: .seconds(1))
    #expect(connectAttempts.value == 1)

    // Second attempt: 2 second delay
    await store.send(.attemptReconnect) {
      $0.reconnectAttempt = 2
    }
    await clock.advance(by: .seconds(2))
    #expect(connectAttempts.value == 2)

    // Third attempt: 4 second delay
    await store.send(.attemptReconnect) {
      $0.reconnectAttempt = 3
    }
    await clock.advance(by: .seconds(4))
    #expect(connectAttempts.value == 3)
  }

  @Test func maxReconnectAttemptsStopsReconnecting() async {
    var state = RemoteFeature.State()
    state.isReconnecting = true
    state.reconnectAttempt = 10
    state.lastConnectedServer = Self.testServer

    let store = TestStore(initialState: state) {
      RemoteFeature()
    }

    await store.send(.attemptReconnect) {
      $0.isReconnecting = false
      $0.reconnectAttempt = 0
      $0.lastConnectedServer = nil
    }
  }

  @Test func cancelReconnectClearsReconnectionState() async {
    var state = RemoteFeature.State()
    state.isReconnecting = true
    state.reconnectAttempt = 3
    state.lastConnectedServer = Self.testServer

    let store = TestStore(initialState: state) {
      RemoteFeature()
    }

    await store.send(.cancelReconnect) {
      $0.isReconnecting = false
      $0.reconnectAttempt = 0
      $0.lastConnectedServer = nil
    }
  }

  @Test func attemptReconnectDoesNothingWhenNotReconnecting() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }

    await store.send(.attemptReconnect)
  }

  // MARK: - Manual Connection Tests

  @Test func connectToAddressWithValidHostPort() async {
    let connectedServer = LockIsolated<DiscoveredServer?>(nil)
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.connect = { server in
        connectedServer.withValue { $0 = server }
      }
    }

    await store.send(.connectToAddress("192.168.1.100:9847")) {
      $0.lastConnectedServer = DiscoveredServer(
        id: "manual-192.168.1.100:9847",
        name: "192.168.1.100:9847",
        endpoint: NWEndpoint.hostPort(
          host: NWEndpoint.Host("192.168.1.100"),
          port: NWEndpoint.Port(rawValue: 9847)!,
        ),
      )
    }
    #expect(connectedServer.value?.id == "manual-192.168.1.100:9847")
  }

  @Test func connectToAddressWithHostname() async {
    let connectedServer = LockIsolated<DiscoveredServer?>(nil)
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.connect = { server in
        connectedServer.withValue { $0 = server }
      }
    }

    await store.send(.connectToAddress("my-mac.tail12345.ts.net:9847")) {
      $0.lastConnectedServer = DiscoveredServer(
        id: "manual-my-mac.tail12345.ts.net:9847",
        name: "my-mac.tail12345.ts.net:9847",
        endpoint: NWEndpoint.hostPort(
          host: NWEndpoint.Host("my-mac.tail12345.ts.net"),
          port: NWEndpoint.Port(rawValue: 9847)!,
        ),
      )
    }
    #expect(connectedServer.value?.name == "my-mac.tail12345.ts.net:9847")
  }

  @Test func connectToAddressWithInvalidFormat() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }
    // Missing port — should not crash, should not change state
    await store.send(.connectToAddress("192.168.1.100"))
  }

  @Test func connectToAddressWithInvalidPort() async {
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    }
    // Port out of range
    await store.send(.connectToAddress("192.168.1.100:99999"))
  }

  @Test func connectToAddressWithIPv6() async {
    let connectedServer = LockIsolated<DiscoveredServer?>(nil)
    let store = TestStore(initialState: RemoteFeature.State()) {
      RemoteFeature()
    } withDependencies: {
      $0.remoteConnectionClient.connect = { server in
        connectedServer.withValue { $0 = server }
      }
    }

    await store.send(.connectToAddress("[::1]:9847")) {
      $0.lastConnectedServer = DiscoveredServer(
        id: "manual-[::1]:9847",
        name: "[::1]:9847",
        endpoint: NWEndpoint.hostPort(
          host: NWEndpoint.Host("::1"),
          port: NWEndpoint.Port(rawValue: 9847)!,
        ),
      )
    }
    #expect(connectedServer.value != nil)
  }
}
