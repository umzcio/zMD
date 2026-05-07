import SwiftUI
import AppKit
import Security

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

    private let lastCheckKey = DefaultsKeys.lastUpdateCheckDate
    private let checkIntervalHours: Double = Timing.updateCheckIntervalHours

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Auto-check on launch (silent, once per 24h). The timestamp is now stamped only after the
    /// request actually succeeds — previously it was stamped eagerly, so a network failure on
    /// launch silently suppressed the next 24h of checks.
    func checkOnLaunchIfNeeded() {
        let lastCheck = UserDefaults.standard.double(forKey: lastCheckKey)
        let now = Date().timeIntervalSince1970
        let hoursSinceLastCheck = (now - lastCheck) / 3600

        if lastCheck == 0 || hoursSinceLastCheck >= checkIntervalHours {
            checkForUpdates(silent: true)
        }
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
                let rawBody = json["body"] as? String ?? ""
                let body = self.stripMarkdown(rawBody)

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

                // Only record a successful check — failures (handled above in the error/parse
                // guards) leave the timestamp untouched so the next launch will retry.
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)

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

        // Use a default-queue session so the completion fires off main; we hop to main only
        // for the small amount of UI state-flipping. The big work (mount/copy/detach) runs on
        // a background queue inside installFromDMG to keep the main thread responsive — the
        // previous code blocked main for several seconds, freezing the UI and risking watchdog kills.
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    AlertManager.shared.showError( "Download Failed", message: error.localizedDescription)
                }
                return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    AlertManager.shared.showError( "Download Failed", message: "No file was downloaded.")
                }
                return
            }

            // Copy off URLSession's temp area before that gets cleaned up.
            let stableDMGPath = FileManager.default.temporaryDirectory.appendingPathComponent("zMD-update.dmg")
            try? FileManager.default.removeItem(at: stableDMGPath)
            do {
                try FileManager.default.copyItem(at: tempURL, to: stableDMGPath)
            } catch {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    AlertManager.shared.showError("Update Failed", message: "Could not prepare DMG: \(error.localizedDescription)")
                }
                return
            }

            // Heavy work (hdiutil + /Applications copy) on a background queue.
            DispatchQueue.global(qos: .userInitiated).async {
                self.installFromDMG(at: stableDMGPath)
            }
        }
        task.resume()
    }

    /// Install the new app bundle. MUST be called off main — runs hdiutil subprocesses,
    /// codesign verification, and an /Applications copy that together can take several seconds.
    /// Hops to main only for the relaunch prompt at the end.
    private func installFromDMG(at stableDMGPath: URL) {
        let fileManager = FileManager.default

        func reportError(_ message: String, detachVolume: String? = nil) {
            if let v = detachVolume {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", v, "-quiet"]
                try? detach.run()
                detach.waitUntilExit()
            }
            try? fileManager.removeItem(at: stableDMGPath)
            DispatchQueue.main.async {
                self.isDownloading = false
                AlertManager.shared.showError("Update Failed", message: message)
            }
        }

        // Mount the DMG
        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountProcess.arguments = ["attach", stableDMGPath.path, "-nobrowse", "-plist"]
        let pipe = Pipe()
        mountProcess.standardOutput = pipe
        mountProcess.standardError = FileHandle.nullDevice

        do {
            try mountProcess.run()
            mountProcess.waitUntilExit()
        } catch {
            reportError("Could not mount DMG: \(error.localizedDescription)")
            return
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: outputData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            reportError("Could not read DMG mount info.")
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
            reportError("Could not find DMG mount point.")
            return
        }

        let volumeURL = URL(fileURLWithPath: volumePath)
        guard let contents = try? fileManager.contentsOfDirectory(at: volumeURL, includingPropertiesForKeys: nil),
              let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            reportError("No app found in DMG.", detachVolume: volumePath)
            return
        }

        // Verify the downloaded bundle: codesign valid AND same Team ID as the running process.
        // Without this, a compromised release URL or any future TLS issue could silently
        // replace /Applications/zMD.app with arbitrary code that auto-launches.
        guard let teamID = currentTeamID() else {
            reportError("Cannot determine current bundle Team ID; refusing to auto-install.", detachVolume: volumePath)
            return
        }
        switch verifySignature(at: appURL, requireTeamID: teamID) {
        case .ok:
            break
        case .invalid(let reason):
            reportError("Downloaded app failed signature check: \(reason). Aborting auto-install.", detachVolume: volumePath)
            return
        }

        let destURL = URL(fileURLWithPath: "/Applications/zMD.app")

        do {
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: appURL, to: destURL)
        } catch {
            reportError("Could not install app: \(error.localizedDescription)", detachVolume: volumePath)
            return
        }

        // Detach + cleanup
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", volumePath, "-quiet"]
        try? detach.run()
        detach.waitUntilExit()
        try? fileManager.removeItem(at: stableDMGPath)

        // Hop to main for the relaunch prompt.
        DispatchQueue.main.async {
            self.isDownloading = false
            let shouldRelaunch = AlertManager.shared.showConfirmation(
                title: "Update Installed",
                message: "zMD \(self.latestVersion) has been installed to /Applications. Relaunch now?",
                confirmButton: "Relaunch",
                cancelButton: "Later"
            )
            if shouldRelaunch { self.relaunch() }
        }
    }

    // MARK: - Code-signing verification

    private enum VerifyResult {
        case ok
        case invalid(String)
    }

    /// The Team ID of the currently-running process bundle. Used as the trust anchor for
    /// auto-update — the new bundle MUST be signed by the same team or we refuse to install.
    private func currentTeamID() -> String? {
        var staticCode: SecStaticCode?
        let bundleURL = Bundle.main.bundleURL
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func verifySignature(at url: URL, requireTeamID expectedTeamID: String) -> VerifyResult {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return .invalid("Cannot create static code reference")
        }
        // Strict signature check: covers tampering, broken signatures, missing resources.
        // Default flags (empty set) perform a strict validation including resource hashes.
        let validity = SecStaticCodeCheckValidity(code, [], nil)
        guard validity == errSecSuccess else {
            return .invalid("codesign validity \(validity)")
        }
        // Team ID check: must match the running app to prevent swap-in of an unrelated signed app.
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let foundTeamID = dict[kSecCodeInfoTeamIdentifier as String] as? String else {
            return .invalid("Could not extract Team ID from new bundle")
        }
        guard foundTeamID == expectedTeamID else {
            return .invalid("Team ID mismatch: expected \(expectedTeamID), got \(foundTeamID)")
        }
        return .ok
    }

    private func relaunch() {
        let appPath = "/Applications/zMD.app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", appPath]
        do {
            try task.run()
        } catch {
            // Previously this used `try?` and then terminated anyway — so if `open` failed
            // (missing binary, permission issue) the user was left with nothing running.
            AlertManager.shared.showError("Relaunch Failed", message: error.localizedDescription)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func isNewerVersion(remote: String, current: String) -> Bool {
        // Strip semver pre-release/build metadata (everything after the first '-' or '+') so
        // `2.5.3-rc1` parses as `[2,5,3]` instead of `[2,5]` (L9). The current shipped version
        // never has metadata, so this only affects how we compare against tagged pre-releases.
        let cleanRemote = remote.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? remote
        let cleanCurrent = current.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? current
        let remoteParts = cleanRemote.split(separator: ".").compactMap { Int($0) }
        let currentParts = cleanCurrent.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(remoteParts.count, currentParts.count)
        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    private func stripMarkdown(_ text: String) -> String {
        var result = text
        // Remove headings
        result = result.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        // Collapse links [text](url) → text so release notes don't show raw URLs.
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        // Remove bold/italic markers
        result = result.replacingOccurrences(of: "\\*{1,3}(.+?)\\*{1,3}", with: "$1", options: .regularExpression)
        // Remove bullet markers
        result = result.replacingOccurrences(of: "(?m)^\\s*[-*]\\s+", with: "- ", options: .regularExpression)
        // Collapse multiple blank lines
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
