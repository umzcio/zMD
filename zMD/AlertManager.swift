import SwiftUI
import AppKit

/// Centralized alert management for zMD.
/// Wraps NSAlert for app-modal confirmation and error dialogs.
/// Previously also exposed a `@Published currentAlert` + `AlertViewModifier` / `withAlertManager()`
/// pipeline for SwiftUI-native alerts that no code actually consumed — that surface was removed
/// during the audit cleanup. All user-facing alerts now flow through `showNSAlert`.
class AlertManager {
    static let shared = AlertManager()

    private init() {}

    // MARK: - Show Alerts

    func showError(_ title: String, message: String) {
        DispatchQueue.main.async {
            self.showNSAlert(title: title, message: message, style: .critical)
        }
    }

    func showInfo(_ title: String, message: String) {
        DispatchQueue.main.async {
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

// (Removed: AlertViewModifier / withAlertManager — never referenced.)
