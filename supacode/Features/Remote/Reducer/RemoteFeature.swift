import ComposableArchitecture
import Foundation
import Network

private enum CancelID {
  static let reconnect = "remote.reconnect"
}

@Reducer
struct RemoteFeature {
  @ObservableState
  struct State: Equatable {
    var isServerEnabled = false
    var connectedClientName: String?
    var pendingConnectionName: String?
    var activePairingCode: String?
    var connectedServerName: String?
    var discoveredServers: [DiscoveredServer] = []
    var remoteRepositories: [RemoteRepository] = []
    var remoteSelectedWorktreeID: String?
    var isBrowsing = false
    var isReconnecting = false
    var reconnectAttempt = 0
    var lastConnectedServer: DiscoveredServer?
  }

  static let maxReconnectAttempts = 10

  enum Action {
    case toggleServer
    case startBrowsing
    case stopBrowsing
    case connectToServer(DiscoveredServer)
    case connectToAddress(String)
    case disconnect
    case remoteServerEvent(RemoteServerEvent)
    case remoteConnectionEvent(RemoteConnectionEvent)
    case sendRemoteAction(RemoteAction)
    case approveConnection
    case denyConnection
    case sendWelcome
    case sendStateSnapshot(RemoteStateSnapshot)
    case forwardToApp(RemoteAction)
    case attemptReconnect
    case cancelReconnect
  }

  @Dependency(\.remoteServerClient) private var remoteServerClient
  @Dependency(\.remoteConnectionClient) private var remoteConnectionClient
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .toggleServer:
        state.isServerEnabled.toggle()
        if state.isServerEnabled {
          let serverClient = remoteServerClient
          return .run { send in
            try await serverClient.start()
            for await event in await serverClient.events() {
              await send(.remoteServerEvent(event))
            }
          }
        } else {
          remoteServerClient.stop()
          state.connectedClientName = nil
          state.pendingConnectionName = nil
          state.activePairingCode = nil
          return .none
        }

      case .startBrowsing:
        state.isBrowsing = true
        let connectionClient = remoteConnectionClient
        connectionClient.startBrowsing()
        return .run { send in
          for await event in await connectionClient.events() {
            await send(.remoteConnectionEvent(event))
          }
        }

      case .stopBrowsing:
        state.isBrowsing = false
        remoteConnectionClient.stopBrowsing()
        return .none

      case .connectToServer(let server):
        state.lastConnectedServer = server
        remoteConnectionClient.connect(server)
        return .none

      case .connectToAddress(let address):
        guard let server = Self.parseAddress(address) else {
          return .none
        }
        state.lastConnectedServer = server
        remoteConnectionClient.connect(server)
        return .none

      case .disconnect:
        state.isReconnecting = false
        state.reconnectAttempt = 0
        state.lastConnectedServer = nil
        remoteConnectionClient.disconnect()
        state.connectedServerName = nil
        state.remoteRepositories = []
        state.remoteSelectedWorktreeID = nil
        return .cancel(id: CancelID.reconnect)

      case .sendRemoteAction(let remoteAction):
        remoteConnectionClient.sendAction(remoteAction)
        return .none

      case .remoteServerEvent(let event):
        switch event {
        case .clientConnected(let name):
          state.pendingConnectionName = name
          state.activePairingCode = String(format: "%06d", Int.random(in: 0...999_999))
          return .none
        case .clientDisconnected:
          state.connectedClientName = nil
          state.pendingConnectionName = nil
          state.activePairingCode = nil
          return .none
        case .actionReceived(let action):
          return .send(.forwardToApp(action))
        case .inputReceived, .videoRequested, .videoStopped:
          return .none
        }

      case .approveConnection:
        if let name = state.pendingConnectionName {
          state.connectedClientName = name
          state.pendingConnectionName = nil
          state.activePairingCode = nil
        }
        return .send(.sendWelcome)

      case .sendWelcome:
        remoteServerClient.sendWelcome()
        return .none

      case .sendStateSnapshot(let snapshot):
        remoteServerClient.sendStateSnapshot(snapshot)
        return .none

      case .denyConnection:
        state.pendingConnectionName = nil
        state.activePairingCode = nil
        remoteServerClient.disconnectClient()
        return .none

      case .forwardToApp:
        return .none

      case .remoteConnectionEvent(let event):
        switch event {
        case .connected(let serverName):
          state.connectedServerName = serverName
          state.isReconnecting = false
          state.reconnectAttempt = 0
        case .disconnected:
          state.connectedServerName = nil
          state.remoteRepositories = []
          state.remoteSelectedWorktreeID = nil
          if state.lastConnectedServer != nil {
            state.isReconnecting = true
            return .send(.attemptReconnect)
          }
        case .stateSnapshotReceived(let snapshot):
          state.remoteRepositories = snapshot.repositories
          state.remoteSelectedWorktreeID = snapshot.selectedWorktreeID
        case .serversChanged(let servers):
          state.discoveredServers = servers
        }
        return .none

      case .attemptReconnect:
        guard state.isReconnecting, let server = state.lastConnectedServer else {
          return .none
        }
        if state.reconnectAttempt >= Self.maxReconnectAttempts {
          state.isReconnecting = false
          state.reconnectAttempt = 0
          state.lastConnectedServer = nil
          return .none
        }
        state.reconnectAttempt += 1
        let attempt = state.reconnectAttempt
        let delay = min(pow(2.0, Double(attempt - 1)), 30.0)
        let connectionClient = remoteConnectionClient
        return .run { [clock] _ in
          try await clock.sleep(for: .seconds(delay))
          await connectionClient.connect(server)
        }
        .cancellable(id: CancelID.reconnect, cancelInFlight: true)

      case .cancelReconnect:
        state.isReconnecting = false
        state.reconnectAttempt = 0
        state.lastConnectedServer = nil
        return .cancel(id: CancelID.reconnect)
      }
    }
  }

  private static func parseAddress(_ address: String) -> DiscoveredServer? {
    let host: String
    let portString: String

    if address.hasPrefix("[") {
      // IPv6: [::1]:9847
      guard let closeBracket = address.firstIndex(of: "]") else { return nil }
      host = String(address[address.index(after: address.startIndex)..<closeBracket])
      let afterBracket = address.index(after: closeBracket)
      guard afterBracket < address.endIndex, address[afterBracket] == ":" else { return nil }
      portString = String(address[address.index(after: afterBracket)...])
    } else {
      // IPv4 or hostname: host:port
      guard let lastColon = address.lastIndex(of: ":") else { return nil }
      host = String(address[..<lastColon])
      portString = String(address[address.index(after: lastColon)...])
    }

    guard let portNumber = UInt16(portString), portNumber > 0 else { return nil }
    guard let nwPort = NWEndpoint.Port(rawValue: portNumber) else { return nil }

    let id = "manual-\(address)"
    return DiscoveredServer(
      id: id,
      name: address,
      endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
    )
  }
}
