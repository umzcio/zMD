import SwiftUI

/// Header bar for a two-file split pane: file name, a Rendered|Edit toggle bound to that
/// pane's mode, and an optional close button (used only on the secondary pane).
struct SplitPaneHeader: View {
    let name: String
    @Binding var mode: SplitPaneMode
    let onClose: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            Picker("View Mode", selection: $mode) {
                Text("Rendered").tag(SplitPaneMode.rendered)
                Text("Edit").tag(SplitPaneMode.edit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Split Pane")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
    }
}
