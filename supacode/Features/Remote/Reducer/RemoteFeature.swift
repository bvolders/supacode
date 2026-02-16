import ComposableArchitecture
import Foundation

@Reducer
struct RemoteFeature {
  @ObservableState
  struct State: Equatable {
    var isServerEnabled = false
    var connectedClientName: String?
    var connectedServerName: String?
    var discoveredServers: [DiscoveredServer] = []
    var remoteRepositories: [RemoteRepository] = []
    var remoteSelectedWorktreeID: String?
    var isBrowsing = false
  }

  enum Action {
    case toggleServer
    case startBrowsing
    case stopBrowsing
    case connectToServer(DiscoveredServer)
    case disconnect
    case remoteServerEvent(RemoteServerEvent)
    case remoteConnectionEvent(RemoteConnectionEvent)
    case sendRemoteAction(RemoteAction)
  }

  @Dependency(\.remoteServerClient) private var remoteServerClient
  @Dependency(\.remoteConnectionClient) private var remoteConnectionClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .toggleServer:
        state.isServerEnabled.toggle()
        if state.isServerEnabled {
          return .run { send in
            try remoteServerClient.start()
            for await event in remoteServerClient.events() {
              await send(.remoteServerEvent(event))
            }
          }
        } else {
          remoteServerClient.stop()
          state.connectedClientName = nil
          return .none
        }

      case .startBrowsing:
        state.isBrowsing = true
        remoteConnectionClient.startBrowsing()
        return .run { send in
          for await event in remoteConnectionClient.events() {
            await send(.remoteConnectionEvent(event))
          }
        }

      case .stopBrowsing:
        state.isBrowsing = false
        remoteConnectionClient.stopBrowsing()
        return .none

      case .connectToServer(let server):
        remoteConnectionClient.connect(server)
        return .none

      case .disconnect:
        remoteConnectionClient.disconnect()
        state.connectedServerName = nil
        state.remoteRepositories = []
        state.remoteSelectedWorktreeID = nil
        return .none

      case .sendRemoteAction(let remoteAction):
        remoteConnectionClient.sendAction(remoteAction)
        return .none

      case .remoteServerEvent(let event):
        switch event {
        case .clientConnected(let name):
          state.connectedClientName = name
        case .clientDisconnected:
          state.connectedClientName = nil
        case .actionReceived, .inputReceived, .videoRequested, .videoStopped:
          break
        }
        return .none

      case .remoteConnectionEvent(let event):
        switch event {
        case .connected(let serverName):
          state.connectedServerName = serverName
        case .disconnected:
          state.connectedServerName = nil
          state.remoteRepositories = []
          state.remoteSelectedWorktreeID = nil
        case .stateSnapshotReceived(let snapshot):
          state.remoteRepositories = snapshot.repositories
          state.remoteSelectedWorktreeID = snapshot.selectedWorktreeID
        case .serversChanged(let servers):
          state.discoveredServers = servers
        }
        return .none
      }
    }
  }
}
