import SwiftUI
import AppKit
import Security

/// Update wizard stage. Drives the single update sheet end-to-end so the user sees one
/// dialog whose contents change as the install progresses, instead of a stack of separate
/// confirmation/error/relaunch alerts (each of which the user previously had to click through,
/// and could double-click into multiple installs).
enum UpdateStage: Equatable {
    case idle               // showing release notes + "Update Now" / "Later"
    case downloading        // progress spinner; button hidden
    case installing         // verifying signature, mounting DMG, copying to /Applications
    case ready              // installed; "Relaunch" / "Later"
    case failed(String)     // error message; "Close" only
}

class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private let repoOwner = "umzcio"
    private let repoName = "zMD"

    @Published var isChecking = false
    @Published var showingUpdateAlert = false
    @Published var latestVersion: String = ""
    @Published var releaseNotes: String = ""
    @Published var downloadURL: URL?
    @Published var stage: UpdateStage = .idle

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
        // Re-entrancy guard: ignore extra clicks once we're past idle. Previously rapid clicks
        // on the "Update Now" button queued multiple downloads + installs in parallel.
        guard stage == .idle else { return }

        guard let url = downloadURL else {
            stage = .failed("No DMG download URL available. Download manually from GitHub.")
            return
        }

        // Downgrade guard: refuse to install unless the downloaded release is actually newer
        // than what's running. `isNewerVersion` is normally only consulted before *showing* the
        // update prompt — this re-checks right before the install itself, so a stale/tampered
        // `downloadURL` (e.g. a compromised release feed pointing at an old, legitimately-signed
        // DMG) can't be installed just because `downloadAndInstall()` got invoked somehow.
        guard isNewerVersion(remote: latestVersion, current: currentVersion) else {
            stage = .failed("This update is not newer than the installed version. Refusing to install.")
            return
        }

        // S5: defense-in-depth — refuse a non-HTTPS artifact URL before downloading. GitHub
        // release assets are always HTTPS and ATS already blocks cleartext, but an explicit guard
        // ensures the downloaded bundle can never arrive over an untrusted transport.
        guard url.scheme == "https" else {
            stage = .failed("Update download URL is not HTTPS. Download manually from GitHub.")
            return
        }

        stage = .downloading

        // Use a default-queue session so the completion fires off main; we hop to main only
        // for the small amount of UI state-flipping. The big work (mount/copy/detach) runs on
        // a background queue inside installFromDMG to keep the main thread responsive — the
        // previous code blocked main for several seconds, freezing the UI and risking watchdog kills.
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.stage = .failed(error.localizedDescription)
                }
                return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self.stage = .failed("No file was downloaded.")
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
                    self.stage = .failed("Could not prepare DMG: \(error.localizedDescription)")
                }
                return
            }

            // Transition to installing; hdiutil + /Applications copy on background queue.
            DispatchQueue.main.async { self.stage = .installing }
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
                self.stage = .failed(message)
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
        // Stage the copy beside the destination first, then swap. Deleting the installed app
        // BEFORE copying meant a failed copy (disk full, I/O error on the mounted DMG) left the
        // user with no app on disk at all — the error dialog was cold comfort after the bundle
        // was already gone.
        let stagingURL = URL(fileURLWithPath: "/Applications/.zMD.app.update")

        do {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            try fileManager.copyItem(at: appURL, to: stagingURL)
            // Copy succeeded — only now is it safe to displace the installed bundle.
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
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

        // Transition to ready stage — the wizard sheet renders the "Relaunch" button
        // automatically and the user clicks it to invoke `relaunchAfterUpdate()`. Replaces a
        // separate AlertManager confirmation that appeared on top of the wizard sheet.
        DispatchQueue.main.async {
            self.stage = .ready
        }
    }

    /// Public entry point invoked by the wizard sheet's "Relaunch" button.
    func relaunchAfterUpdate() {
        relaunch()
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
        // Detached background trampoline: a backgrounded subshell that polls `kill -0 <pid>` until
        // our process exits, THEN opens the newly-installed app. The ( ... ) & disown construct
        // is critical: without it, the trampoline shell was a direct child of zMD and got reaped
        // alongside zMD on terminate, so `open` never ran. Now: outer sh exits immediately,
        // backgrounded subshell is orphaned to launchd, survives zMD's termination, then opens
        // the new app once the old PID is gone. Output redirected to a log for postmortem
        // debugging if relaunch ever fails again.
        let appPath = "/Applications/zMD.app"
        let myPid = ProcessInfo.processInfo.processIdentifier
        // S4: log to the per-user temporary directory (/var/folders/.../T), not world-writable /tmp.
        // The previous fixed /tmp/zmd-relaunch.log path let a local attacker pre-create it as a
        // symlink and redirect these appends to a victim-writable file (CWE-377). The path is also
        // single-quoted in the redirects below as defense in depth.
        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-relaunch.log").path
        let script = """
        ( echo "[$(date)] trampoline waiting for PID \(myPid)" >> '\(logPath)'; \
          while kill -0 \(myPid) 2>/dev/null; do sleep 0.1; done; \
          sleep 0.5; \
          echo "[$(date)] PID gone, opening \(appPath)" >> '\(logPath)'; \
          open -n '\(appPath)' >> '\(logPath)' 2>&1; \
          echo "[$(date)] open exit=$?" >> '\(logPath)' ) &
        disown
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        // Detach standard streams so the shell doesn't keep an inheritable file descriptor
        // pointing at zMD's stdio.
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            AlertManager.shared.showError("Relaunch Failed", message: error.localizedDescription)
            return
        }
        // Wait briefly for the outer sh to fork+disown the background subshell before we
        // terminate. Without this small gap there's a race where zMD exits before the subshell
        // has been backgrounded.
        task.waitUntilExit()

        // Force-exit instead of NSApplication.terminate(nil). v2.5.11 left the trampoline
        // spinning forever because terminate(nil) goes through applicationShouldTerminate, which
        // SwiftUI returns .terminateCancel for when a modal sheet (the update wizard itself) is
        // up — confirmed via /tmp/zmd-relaunch.log showing the same PID polled for 30+ seconds
        // across repeated Relaunch clicks. exit(0) bypasses the AppKit terminate handshake.
        DispatchQueue.main.async {
            // Dismiss the sheet first so SwiftUI gets a chance to tear down its modal state.
            self.showingUpdateAlert = false
            // Hop another runloop tick, then hard-exit.
            DispatchQueue.main.async {
                exit(0)
            }
        }
    }

    // Not private: exercised directly from InlineMarkdownTests via `@testable import zMD`,
    // matching the pattern used for ExportManager.safeDOCXHyperlinkURL / extractMathFromMarkdown.
    func isNewerVersion(remote: String, current: String) -> Bool {
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
