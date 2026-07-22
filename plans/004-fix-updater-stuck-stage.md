# Plan 004: Fix the updater's stuck "ready" stage after "Later", and add a downgrade guard

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/UpdateManager.swift zMD/zMDApp.swift`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

Two independent issues in the same area, bundled because they're both small
and both touch `UpdateManager`'s stage state machine:

**1. Stuck "ready" stage.** `downloadAndInstall()` guards re-entrancy with
`guard stage == .idle else { return }` — correct, it stops rapid double-clicks
from queuing parallel installs. But the sheet's "Later" button
(`onLater` closure) only resets `stage` back to `.idle` when the stage is
`.failed`. If a user gets to `.ready` (update downloaded, installed,
awaiting relaunch) and clicks "Later" instead of "Relaunch", `stage` stays
`.ready` forever (for the rest of the app session). The next time they
trigger "Check for Updates", the sheet reopens still in `.ready`, and
`downloadAndInstall()`'s guard now permanently no-ops "Update Now" — the
updater is effectively dead until the user quits and relaunches the app.

**2. No downgrade floor.** `installFromDMG` verifies the downloaded DMG's
code signature and Team ID (both correct, strong checks), but nothing
prevents *installing an older, legitimately-signed version* if the release
feed ever serves one (compromised release pipeline, or a manually-crafted
GitHub release pointing at an old signed DMG). `isNewerVersion` is only
consulted before *showing* the update prompt, not before the actual
install — so if `downloadAndInstall()` is somehow invoked with a stale
`downloadURL`, there's no floor stopping the install itself.

Both are small, contained fixes to the same file/area, hence one plan.

## Current state

- `zMD/UpdateManager.swift` — updater state machine, download, verify,
  install.
- `zMD/zMDApp.swift` — the SwiftUI sheet UI (`UpdateAvailableSheet` usage)
  that drives `onLater`/stage-dependent buttons.

The re-entrancy guard:

```swift
// zMD/UpdateManager.swift:119-127
func downloadAndInstall() {
    // Re-entrancy guard: ignore extra clicks once we're past idle. Previously rapid clicks
    // on the "Update Now" button queued multiple downloads + installs in parallel.
    guard stage == .idle else { return }

    guard let url = downloadURL else {
        stage = .failed("No DMG download URL available. Download manually from GitHub.")
        return
    }
    ...
```

The "Later" handler that only resets on `.failed`:

```swift
// zMD/zMDApp.swift:60-74
UpdateAvailableSheet(
    updateManager: updateManager,
    onViewOnGitHub: {
        if let url = URL(string: "https://github.com/umzcio/zMD/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    },
    onLater: {
        updateManager.showingUpdateAlert = false
        // Reset to idle so reopening the sheet starts at release notes.
        if case .failed = updateManager.stage {
            updateManager.stage = .idle
        }
    }
)
```

The `.ready` stage's button row, which offers "Later" — the trigger for the
stuck state:

```swift
// zMD/zMDApp.swift:612-624 (inside the sheet's stage-dependent button switch)
case .ready:
    Button("Later", action: onLater)
        .keyboardShortcut(.cancelAction)
    Spacer()
    Button("Relaunch zMD") { updateManager.relaunchAfterUpdate() }
        .keyboardShortcut(.defaultAction)
case .failed:
```

Version comparison, used only at prompt time today:

```swift
// zMD/UpdateManager.swift:395-412
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
```

`currentVersion` — find its definition (likely reads
`Bundle.main.infoDictionary?["CFBundleShortVersionString"]`, following the
pattern used in `SettingsView.swift`'s `AboutTab` — grep `currentVersion` in
`UpdateManager.swift` to confirm before writing Step 2).

`installFromDMG` and `latestVersion` — you'll need to locate where
`latestVersion` (the remote version string) is stored on `UpdateManager` and
where `installFromDMG` is invoked from, to know where to insert the
downgrade check. Read `UpdateManager.swift:180-284` (already partially
excerpted in this repo's audit) to confirm the exact call chain before
Step 3 — the check belongs right before the mount/copy work begins, not
inside `reportError` or the mount logic itself.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |

## Scope

**In scope**:
- `zMD/UpdateManager.swift`
- `zMD/zMDApp.swift` (only the `onLater` closure and its stage-reset logic)

**Out of scope**:
- The download/verify/install pipeline's signature and Team-ID checks —
  already correct, don't touch.
- `hdiutil attach` happening before signature verification — a previously
  documented accepted risk (per this repo's prior audit); not this plan's
  concern.
- Any UI redesign of the update sheet beyond the minimal `onLater` fix.

## Git workflow

- Branch: `advisor/004-updater-stuck-stage`
- One or two commits (stuck-stage fix, downgrade guard) — either grouping
  is fine given both are small; match repo commit style.

## Steps

### Step 1: Reset `stage` to `.idle` on "Later" regardless of stage

Change the `onLater` closure in `zMD/zMDApp.swift` to unconditionally reset
`stage`, not just when `.failed`. The installed update (if any) already sits
in `/Applications` at this point — going back to `.idle` doesn't lose
anything; "Relaunch" is still reachable next time the user chooses to act on
it, and a "Check for Updates" won't see a newer remote version once the user
has already downloaded/installed this one (verify this claim by reading
`checkForUpdates`'s comparison logic — if it would show the sheet again for
a version already installed-but-not-relaunched, note this as a UX quirk in
your final report, but it's out of scope to fix here since it's a separate,
pre-existing behavior, not something this fix introduces).

```swift
onLater: {
    updateManager.showingUpdateAlert = false
    updateManager.stage = .idle
}
```

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`. Then manually confirm (see Test plan) that clicking "Later" after `.ready` allows a subsequent "Check for Updates" to re-enable "Update Now".

### Step 2: Add a downgrade guard to `downloadAndInstall`

Right after the existing `guard stage == .idle` and `guard let url =
downloadURL` checks in `downloadAndInstall()`, add a check that
`latestVersion` (the version this download corresponds to) is still newer
than `currentVersion`, using the existing `isNewerVersion` helper — don't
duplicate its logic:

```swift
func downloadAndInstall() {
    guard stage == .idle else { return }

    guard let url = downloadURL else {
        stage = .failed("No DMG download URL available. Download manually from GitHub.")
        return
    }

    guard isNewerVersion(remote: latestVersion, current: currentVersion) else {
        stage = .failed("This update is not newer than the installed version. Refusing to install.")
        return
    }

    // ... existing HTTPS scheme guard and remaining logic unchanged
```

(Confirm the exact property name for the stored remote version —
`latestVersion` is the name used in the recon excerpt at
`UpdateManager.swift:108`; verify it's still accurate in the current file
before using it.)

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 3: Add a regression test for the version-comparison guard

`isNewerVersion` is `private`. Either:
- (a) temporarily change its access level to `internal` so it's reachable
  from `@testable import zMD` (matches how `ExportManager.safeDOCXHyperlinkURL`
  and `ExportManager.extractMathFromMarkdown` are already exercised from
  tests per `zMDTests/InlineMarkdownTests.swift:73-87` — check their actual
  access level in `ExportManager.swift` to confirm this is the established
  pattern before copying it), or
- (b) test the guard indirectly through `downloadAndInstall()`'s observable
  effect on `stage`.

Prefer (a) if the existing pattern confirms it — it's simpler and matches
established repo convention. Add to `zMDTests/InlineMarkdownTests.swift` (or
a new file):

```swift
func testIsNewerVersionRejectsEqualAndOlderVersions() {
    let manager = UpdateManager.shared
    XCTAssertFalse(manager.isNewerVersion(remote: "2.7.1", current: "2.7.1"))
    XCTAssertFalse(manager.isNewerVersion(remote: "2.6.0", current: "2.7.1"))
    XCTAssertTrue(manager.isNewerVersion(remote: "2.7.2", current: "2.7.1"))
    XCTAssertTrue(manager.isNewerVersion(remote: "3.0.0", current: "2.7.1"))
}
```

If `isNewerVersion` cannot be reached even with an access-level change
(e.g. it depends on other private state you can't set up in a test), fall
back to option (b): drive `latestVersion`/`downloadURL`/`stage` directly on
`UpdateManager.shared` (save/restore around the test, following the
save/restore pattern in `RuntimeSmokeTests` at
`zMDTests/InlineMarkdownTests.swift:90-121`), call `downloadAndInstall()`
with `latestVersion` set to something not newer than `currentVersion`, and
assert `stage` becomes `.failed` rather than proceeding to download.

**Verify**: `xcodebuild ... test -destination 'platform=macOS'` → all pass, including the new test.

## Test plan

- New test from Step 3 — pin the downgrade-guard behavior.
- Manual verification of Step 1 (no automated UI test infrastructure exists
  for this): drive the app, get to the `.ready` stage (you can simulate this
  by manually setting `UpdateManager.shared.stage = .ready` in a debug
  build if you don't want to actually download a real update — note in your
  report which approach you used), click "Later", then trigger "Check for
  Updates" again and confirm "Update Now" is clickable (not permanently
  disabled).

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass, including the new downgrade-guard test
- [ ] Manual verification: "Later" from `.ready` no longer permanently disables "Update Now"
- [ ] `grep -n "case .failed = updateManager.stage" zMD/zMDApp.swift` returns no matches (the conditional reset is gone, replaced by an unconditional one)
- [ ] No files outside scope modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `onLater`'s current logic, or the `.ready` stage's button layout, doesn't
  match the excerpts above — re-read live code, don't guess at the fix.
- `isNewerVersion` cannot be made testable via either option (a) or (b)
  without touching files outside this plan's scope — report back rather
  than expanding scope to refactor `UpdateManager`'s architecture.
- Setting `stage = .idle` unconditionally in `onLater` causes some other
  observable regression you notice while testing (e.g. it re-triggers a
  download automatically) — if `stage == .idle` has any side effect beyond
  enabling the "Update Now" button elsewhere in the codebase, stop and
  report that coupling instead of shipping a fix that causes a new bug.

## Maintenance notes

- The downgrade guard (Step 2) only protects the `downloadAndInstall` entry
  point. If a future change adds another path that can call
  `installFromDMG` directly (bypassing `downloadAndInstall`), that path
  needs the same guard — it is not currently structured to be
  un-bypassable, just harder to reach accidentally.
- If `UpdateManager`'s stage enum grows new cases in the future, revisit
  `onLater`'s reset logic — this fix makes it stage-agnostic (always resets
  to `.idle`), which should remain correct for new stages unless a future
  stage specifically needs "Later" to preserve some in-progress state
  (unlikely, but worth a second look if that ever comes up).
