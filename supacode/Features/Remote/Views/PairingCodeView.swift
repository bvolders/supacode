import SwiftUI

struct PairingCodeView: View {
  let code: String
  let clientName: String
  let onApprove: () -> Void
  let onDeny: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "lock.shield")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Text("Pairing Request")
        .font(.headline)

      Text("\(clientName) wants to connect.")
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)

      Text("Verify this code matches on the client:")
        .font(.caption)
        .foregroundStyle(.tertiary)

      Text(code)
        .font(.system(size: 36).monospaced())
        .tracking(8)
        .padding(.vertical, 8)

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
    .frame(width: 320)
  }
}
