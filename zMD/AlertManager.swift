import SwiftUI
import AppKit

/// Centralized alert management for zMD 2.0
/// Replaces silent failures with user-visible error messages
class AlertManager: ObservableObject {
    static let shared = AlertManager()

    @Published var currentAlert: AlertInfo?
    @Published var isShowingAlert = false

    private init() {}

    struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let style: AlertStyle

        enum AlertStyle {
            case error
            case warning
            case info
            case success
        }
    }

    // MARK: - Show Alerts

    func showError(_ title: String, message: String) {
        DispatchQueue.main.async {
            self.currentAlert = AlertInfo(title: title, message: message, style: .error)
            self.isShowingAlert = true
            self.showNSAlert(title: title, message: message, style: .critical)
        }
    }

    func showWarning(_ title: String, message: String) {
        DispatchQueue.main.async {
            self.currentAlert = AlertInfo(title: title, message: message, style: .warning)
            self.isShowingAlert = true
            self.showNSAlert(title: title, message: message, style: .warning)
        }
    }

    func showInfo(_ title: String, message: String) {
        DispatchQueue.main.async {
            self.currentAlert = AlertInfo(title: title, message: message, style: .info)
            self.isShowingAlert = true
            self.showNSAlert(title: title, message: message, style: .informational)
        }
    }

    func showSuccess(_ title: String, message: String) {
        DispatchQueue.main.async {
            self.currentAlert = AlertInfo(title: title, message: message, style: .success)
            self.isShowingAlert = true
            self.showNSAlert(title: title, message: message, style: .informational)
        }
    }

    // MARK: - Confirmation Dialogs

    /// Show a confirmation dialog and return the user's choice
    func showConfirmation(
        title: String,
        message: String,
        confirmButton: String = "OK",
        cancelButton: String = "Cancel",
        isDestructive: Bool = false
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = isDestructive ? .warning : .informational

        alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: cancelButton)

        if isDestructive {
            alert.buttons.first?.hasDestructiveAction = true
        }

        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    /// Show a dialog asking to reload a changed file
    func showFileChangedDialog(fileName: String) -> FileChangedAction {
        let alert = NSAlert()
        alert.messageText = "File Changed Externally"
        alert.informativeText = "\"\(fileName)\" has been modified by another application. Do you want to reload it?"
        alert.alertStyle = .informational

        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Ignore")
        alert.addButton(withTitle: "Ignore All")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .reload
        case .alertSecondButtonReturn:
            return .ignore
        default:
            return .ignoreAll
        }
    }

    enum FileChangedAction {
        case reload
        case ignore
        case ignoreAll
    }

    // MARK: - Native Alert

    private func showNSAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Export-specific errors

    func showExportError(_ format: String, error: Error) {
        showError(
            "Export Failed",
            message: "Failed to export as \(format): \(error.localizedDescription)"
        )
    }

    func showExportError(_ format: String, reason: String) {
        showError(
            "Export Failed",
            message: "Failed to export as \(format): \(reason)"
        )
    }

    func showFileLoadError(url: URL, error: Error) {
        showError(
            "Failed to Open File",
            message: "Could not open \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        )
    }

    func showFileSaveError(url: URL, error: Error) {
        showError(
            "Failed to Save File",
            message: "Could not save to \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        )
    }
}

// MARK: - SwiftUI View Modifier for Alerts

struct AlertViewModifier: ViewModifier {
    @ObservedObject var alertManager = AlertManager.shared

    func body(content: Content) -> some View {
        content
            .alert(
                alertManager.currentAlert?.title ?? "Error",
                isPresented: $alertManager.isShowingAlert,
                presenting: alertManager.currentAlert
            ) { _ in
                Button("OK") {
                    alertManager.isShowingAlert = false
                }
            } message: { alert in
                Text(alert.message)
            }
    }
}

extension View {
    func withAlertManager() -> some View {
        modifier(AlertViewModifier())
    }
}
