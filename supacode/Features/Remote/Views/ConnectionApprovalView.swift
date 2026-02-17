import SwiftUI

struct ConnectionApprovalView: View {
  let clientName: String
  let onApprove: () -> Void
  let onDeny: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "network.badge.shield.half.filled")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Text("Connection Request")
        .font(.headline)

      Text("\(clientName) wants to connect to this Mac.")
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        Button("Deny") {
          onDeny()
        }
        .keyboardShortcut(.escape)

        Button("Allow") {
          onApprove()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 300)
  }
}
