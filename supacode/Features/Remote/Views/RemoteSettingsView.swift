import ComposableArchitecture
import SwiftUI

struct RemoteSettingsView: View {
  let remoteStore: StoreOf<RemoteFeature>

  @State private var manualAddress = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        serverSection
        clientSection
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Server Section

  @ViewBuilder
  private var serverSection: some View {
    Section("Host Mode") {
      Toggle(
        "Enable Remote Server",
        isOn: .init(
          get: { remoteStore.isServerEnabled },
          set: { _ in remoteStore.send(.toggleServer) }
        ))

      if remoteStore.isServerEnabled {
        LabeledContent("Status") {
          Text("Advertising")
            .foregroundStyle(.secondary)
        }
      }
    }

    if let pendingName = remoteStore.pendingConnectionName,
      let code = remoteStore.activePairingCode
    {
      Section("Pairing Request") {
        PairingCodeView(
          code: code,
          clientName: pendingName,
          onApprove: { remoteStore.send(.approveConnection) },
          onDeny: { remoteStore.send(.denyConnection) },
        )
        .frame(maxWidth: .infinity)
      }
    }

    if let clientName = remoteStore.connectedClientName {
      Section("Connected Client") {
        LabeledContent("Client") {
          Text(clientName)
        }
      }
    }
  }

  // MARK: - Client Section

  @ViewBuilder
  private var clientSection: some View {
    Section("Connect to Remote") {
      if remoteStore.connectedServerName == nil {
        Toggle(
          "Browse for Servers",
          isOn: .init(
            get: { remoteStore.isBrowsing },
            set: { newValue in
              remoteStore.send(newValue ? .startBrowsing : .stopBrowsing)
            }
          ))
      }

      if remoteStore.isBrowsing, !remoteStore.discoveredServers.isEmpty {
        ForEach(remoteStore.discoveredServers) { server in
          HStack {
            Label(server.name, systemImage: "desktopcomputer")
            Spacer()
            Button("Connect") {
              remoteStore.send(.connectToServer(server))
            }
          }
        }
      }

      if remoteStore.connectedServerName == nil, !remoteStore.isReconnecting {
        HStack {
          TextField("host:port", text: $manualAddress)
            .textFieldStyle(.roundedBorder)
          Button("Connect") {
            remoteStore.send(.connectToAddress(manualAddress))
            manualAddress = ""
          }
          .disabled(manualAddress.isEmpty)
        }
      }
    }

    if let serverName = remoteStore.connectedServerName {
      Section("Connected Server") {
        LabeledContent("Server") {
          Text(serverName)
        }
        Button("Disconnect") {
          remoteStore.send(.disconnect)
        }
      }
    }

    if remoteStore.isReconnecting {
      Section("Reconnecting") {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Reconnecting (attempt \(remoteStore.reconnectAttempt)/\(RemoteFeature.maxReconnectAttempts))...")
            .foregroundStyle(.secondary)
        }
        Button("Cancel Reconnection") {
          remoteStore.send(.cancelReconnect)
        }
      }
    }
  }
}
