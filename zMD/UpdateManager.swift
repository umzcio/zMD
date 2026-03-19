import SwiftUI
import AppKit

class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private let repoOwner = "umzcio"
    private let repoName = "zMD"

    @Published var isChecking = false
    @Published var showingUpdateAlert = false
    @Published var latestVersion: String = ""
    @Published var releaseNotes: String = ""
    @Published var downloadURL: URL?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates(silent: Bool = false) {
        guard !isChecking else { return }
        isChecking = true

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            isChecking = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false

                if let error = error {
                    if !silent {
                        AlertManager.shared.showError( "Update Check Failed", message: error.localizedDescription)
                    }
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    if !silent {
                        AlertManager.shared.showError( "Update Check Failed", message: "Could not parse release information.")
                    }
                    return
                }

                let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let body = json["body"] as? String ?? ""

                // Find DMG asset
                var dmgURL: URL?
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           name.hasSuffix(".dmg"),
                           let urlStr = asset["browser_download_url"] as? String,
                           let url = URL(string: urlStr) {
                            dmgURL = url
                            break
                        }
                    }
                }

                if self.isNewerVersion(remote: remoteVersion, current: self.currentVersion) {
                    self.latestVersion = remoteVersion
                    self.releaseNotes = body
                    self.downloadURL = dmgURL
                    self.showingUpdateAlert = true
                } else if !silent {
                    AlertManager.shared.showInfo( "You're Up to Date", message: "zMD \(self.currentVersion) is the latest version.")
                }
            }
        }.resume()
    }

    func downloadAndInstall() {
        guard let url = downloadURL else {
            AlertManager.shared.showError( "Download Failed", message: "No DMG download URL available. Please download manually from GitHub.")
            return
        }

        isDownloading = true
        downloadProgress = 0

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDownloading = false

                if let error = error {
                    AlertManager.shared.showError( "Download Failed", message: error.localizedDescription)
                    return
                }

                guard let tempURL = tempURL else {
                    AlertManager.shared.showError( "Download Failed", message: "No file was downloaded.")
                    return
                }

                self.installFromDMG(at: tempURL)
            }
        }
        task.resume()
    }

    private func installFromDMG(at dmgPath: URL) {
        let fileManager = FileManager.default

        // Copy DMG to a stable temp location (download temp files get cleaned up)
        let stableDMGPath = fileManager.temporaryDirectory.appendingPathComponent("zMD-update.dmg")
        try? fileManager.removeItem(at: stableDMGPath)
        do {
            try fileManager.copyItem(at: dmgPath, to: stableDMGPath)
        } catch {
            AlertManager.shared.showError( "Update Failed", message: "Could not prepare DMG: \(error.localizedDescription)")
            return
        }

        // Mount the DMG
        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountProcess.arguments = ["attach", stableDMGPath.path, "-nobrowse", "-quiet", "-plist"]

        let pipe = Pipe()
        mountProcess.standardOutput = pipe

        do {
            try mountProcess.run()
            mountProcess.waitUntilExit()
        } catch {
            AlertManager.shared.showError( "Update Failed", message: "Could not mount DMG: \(error.localizedDescription)")
            return
        }

        // Parse mount point from plist output
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: outputData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            AlertManager.shared.showError( "Update Failed", message: "Could not read DMG mount info.")
            return
        }

        var mountPoint: String?
        for entity in entities {
            if let mp = entity["mount-point"] as? String {
                mountPoint = mp
                break
            }
        }

        guard let volumePath = mountPoint else {
            AlertManager.shared.showError( "Update Failed", message: "Could not find DMG mount point.")
            return
        }

        // Find .app in the mounted volume
        let volumeURL = URL(fileURLWithPath: volumePath)
        guard let contents = try? fileManager.contentsOfDirectory(at: volumeURL, includingPropertiesForKeys: nil),
              let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            // Detach
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", volumePath, "-quiet"]
            try? detach.run()
            AlertManager.shared.showError( "Update Failed", message: "No app found in DMG.")
            return
        }

        let destURL = URL(fileURLWithPath: "/Applications/zMD.app")

        // Remove old app and copy new one
        do {
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: appURL, to: destURL)
        } catch {
            // Detach
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", volumePath, "-quiet"]
            try? detach.run()
            AlertManager.shared.showError( "Update Failed", message: "Could not install app: \(error.localizedDescription)")
            return
        }

        // Detach DMG
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", volumePath, "-quiet"]
        try? detach.run()

        // Clean up temp DMG
        try? fileManager.removeItem(at: stableDMGPath)

        // Prompt to relaunch
        let shouldRelaunch = AlertManager.shared.showConfirmation(
            title: "Update Installed",
            message: "zMD \(latestVersion) has been installed to /Applications. Relaunch now?",
            confirmButton: "Relaunch",
            cancelButton: "Later"
        )

        if shouldRelaunch {
            relaunch()
        }
    }

    private func relaunch() {
        let appPath = "/Applications/zMD.app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", appPath]
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func isNewerVersion(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(remoteParts.count, currentParts.count)
        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }
}
