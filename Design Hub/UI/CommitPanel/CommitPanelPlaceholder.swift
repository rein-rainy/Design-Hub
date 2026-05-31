import SwiftUI

// Placeholder — replace this view with your own commit UI
struct CommitPanelPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Commit Panel")
                .font(.headline)
            Text("Replace CommitPanelPlaceholder with your UI")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Close") {
                CommitPanelController.shared.hide()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(32)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(width: 480, height: 320)
        .background(.clear)
    }
}

#Preview {
    CommitPanelPlaceholder()
}
