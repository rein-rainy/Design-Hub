import SwiftUI

struct CommitPanelPlaceholder: View {
    let message: PluginMessage
    let layerDiff: LayerDiff?
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var commitMessage: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File saved")
                .font(.headline)
            TextField("Enter commit message", text: $commitMessage)
                .font(.body)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .padding(15)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                )
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                .frame(height: 36)
                .overlay(alignment: .leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(Color(NSColor.secondaryLabelColor))
                        Text(message.payload.name)
                            .font(.body)
                            .foregroundStyle(Color(NSColor.labelColor))
                        Spacer()
                        if let diff = layerDiff, !diff.isEmpty {
                            if diff.added.count > 0 {
                                Text("+\(diff.added.count)")
                                    .font(.callout)
                                    .foregroundStyle(Color(NSColor.systemGreen))
                            }
                            if diff.removed.count > 0 {
                                Text("-\(diff.removed.count)")
                                    .font(.callout)
                                    .foregroundStyle(Color(NSColor.systemRed))
                            }
                        }
                    }
                    .padding(15)
                }

            HStack(spacing: 8) {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.body)
                        .foregroundStyle(Color(NSColor.labelColor))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    onCommit(commitMessage)
                } label: {
                    Text("Commit")
                        .font(.body)
                        .foregroundStyle(colorScheme == .dark ? .black : .white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white : Color.black)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(alignment: .leading)
        .padding(24)
        .glassEffect(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .frame(width: 380, height: 320)
        .background(.clear)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
    }
}
