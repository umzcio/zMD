import SwiftUI
import WebKit

struct HelpView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("zMD Help")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                // Visible, labeled close button. Previously this was an empty-title invisible
                // button that worked for Escape but announced nothing to screen readers.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Help")
            }
            .padding()

            Divider()

            // Help content
            HelpWebView()
        }
        .frame(width: 800, height: 600)
    }
}

struct HelpWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(HelpHTML.content, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
