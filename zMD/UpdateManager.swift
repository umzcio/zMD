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
        guard Self.isTrustedDownloadURL(url, initial: true) else {
            stage = .failed("Update download URL is not a zMD GitHub release asset. Download manually from GitHub.")
            return
        }
        let advertisedVersion = latestVersion
        let currentVersion = self.currentVersion

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
            // Redirects are followed automatically; make sure they ended on GitHub's asset host.
            if let finalURL = response?.url, !Self.isTrustedDownloadURL(finalURL, initial: false) {
                DispatchQueue.main.async {
                    self.stage = .failed("Update download was redirected off GitHub. Download manually from GitHub.")
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
                self.installFromDMG(at: stableDMGPath, advertisedVersion: advertisedVersion, currentVersion: currentVersion)
            }
        }
        task.resume()
    }

    /// Install the new app bundle. MUST be called off main — runs hdiutil subprocesses,
    /// codesign verification, and an /Applications copy that together can take several seconds.
    /// Hops to main only for the relaunch prompt at the end.
    private nonisolated func installFromDMG(at stableDMGPath: URL, advertisedVersion: String, currentVersion: String) {
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
        // The checks below follow symlinks but the copy does not, so a symlinked `.app` used to
        // be verified as its target and installed as a dangling link (security finding, 2026-11).
        guard Self.isRealDirectory(appURL) else {
            reportError("The app in the DMG is not a real bundle. Aborting auto-install.", detachVolume: volumePath)
            return
        }

        // Verify the downloaded bundle before touching /Applications: Developer ID + notarized +
        // zMD's team and identifier, then the bundle's own identity and version.
        if case .invalid(let reason) = Self.verifySignature(at: appURL) {
            reportError("Downloaded app failed signature check: \(reason). Aborting auto-install.", detachVolume: volumePath)
            return
        }
        if case .invalid(let reason) = Self.verifyBundleIdentity(at: appURL, advertisedVersion: advertisedVersion, currentVersion: currentVersion) {
            reportError("Downloaded app was rejected: \(reason). Aborting auto-install.", detachVolume: volumePath)
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
            // Verify what will actually be installed — the staged copy — before the installed
            // bundle is removed.
            guard Self.isRealDirectory(stagingURL),
                  Self.verifySignature(at: stagingURL) == .ok,
                  Self.verifyBundleIdentity(at: stagingURL, advertisedVersion: advertisedVersion, currentVersion: currentVersion) == .ok else {
                try? fileManager.removeItem(at: stagingURL)
                reportError("The staged update failed verification. Aborting auto-install.", detachVolume: volumePath)
                return
            }
            // Copy verified — only now is it safe to displace the installed bundle.
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

    /// The code requirement a downloaded update must satisfy before anything in /Applications
    /// is touched: Apple's root, a Developer ID Application leaf from zMD's own team, zMD's
    /// bundle identifier, and a notarization ticket.
    ///
    /// The old check compared `kSecCodeInfoTeamIdentifier` against the running app with no
    /// requirement. That string is copied from whatever certificate signed the bundle, so a
    /// self-generated certificate whose OU claimed the public Team ID passed (security finding,
    /// 2026-11). Team and identifier are fixed strings — never read from the download.
    nonisolated static let teamID = "5JJ6G6A84S"
    nonisolated static let bundleIdentifier = "com.zmd.app"
    nonisolated static let updateRequirement =
        "anchor apple generic"
        + " and identifier \"\(bundleIdentifier)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"      // Developer ID CA
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"  // Developer ID Application
        + " and certificate leaf[subject.OU] = \"\(teamID)\""
        + " and notarized"

    nonisolated enum VerifyResult: Equatable {
        case ok
        case invalid(String)
    }

    /// Strict, nested-code, all-architecture validation against `updateRequirement`.
    nonisolated static func verifySignature(at url: URL) -> VerifyResult {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return .invalid("Cannot create static code reference")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(updateRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return .invalid("Cannot build the update code requirement")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode
                               | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks)
        let validity = SecStaticCodeCheckValidity(code, flags, requirement)
        guard validity == errSecSuccess else {
            return .invalid("not a notarized zMD release signed by the zMD team (\(validity))")
        }
        return .ok
    }

    /// After the signature check (which seals Info.plist): the bundle must BE zMD and must be
    /// the version the release advertised, and that version must be newer than the running
    /// one. The feed's `tag_name` alone proves nothing — a high tag could carry an old build or
    /// another app from the same team.
    nonisolated static func verifyBundleIdentity(at url: URL, advertisedVersion: String, currentVersion: String) -> VerifyResult {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String else {
            return .invalid("Cannot read the downloaded app's Info.plist")
        }
        guard identifier == bundleIdentifier else {
            return .invalid("the downloaded app is \(identifier), not zMD")
        }
        guard isNewerVersion(remote: version, current: currentVersion) else {
            return .invalid("the downloaded app is version \(version), not newer than \(currentVersion)")
        }
        guard !isNewerVersion(remote: version, current: advertisedVersion),
              !isNewerVersion(remote: advertisedVersion, current: version) else {
            return .invalid("the downloaded app is version \(version) but the release says \(advertisedVersion)")
        }
        return .ok
    }

    /// A directory that is not itself a symbolic link.
    nonisolated static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return false }
        return values.isSymbolicLink == false && values.isDirectory == true
    }

    /// Release assets are served from github.com and redirected to GitHub's asset CDN. Anything
    /// else is refused before (initial URL) and after (final URL) the download.
    nonisolated static func isTrustedDownloadURL(_ url: URL, initial: Bool) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        if initial {
            return host == "github.com" && url.path.lowercased().hasPrefix("/umzcio/zmd/releases/download/")
        }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
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
        Self.isNewerVersion(remote: remote, current: current)
    }

    nonisolated static func isNewerVersion(remote: String, current: String) -> Bool {
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
