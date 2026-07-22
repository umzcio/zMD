# Plan 007: Fix folder-sidebar refresh drop and scan-ordering race, add lifecycle tests

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/FolderManager.swift zMD/DirectoryWatcher.swift`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: Plan 001 (touches the same file, `FolderManager.swift` —
  land Plan 001 first to avoid merge friction, though the changes are in
  different functions and shouldn't conflict).
- **Category**: bug (bundles test coverage for the same subsystem)
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

Two related bugs in the folder-sidebar refresh path, plus a coverage gap
for the same subsystem — bundled because fixing the bugs without a test
means they can silently regress, and the two bugs are close enough in the
same file that reviewing/testing them together is more efficient than three
separate round-trips.

**1. Suppression window silently drops a legitimate external edit.** After
zMD saves a file itself, `refreshFileTreeAsync()` suppresses the *next*
FSEvents-triggered rescan for 800ms (`selfWriteSuppressionWindow`) to avoid
a redundant O(N) tree scan reacting to the app's own write. The code
comment claims "the next debounce will catch them" (referring to a
different external edit that might land inside that window) — but nothing
actually reschedules a rescan; the function just `return`s. If the *only*
FS event in that 800ms window is the coincidentally-timed external edit,
it's dropped entirely: the sidebar won't reflect that change until some
*later, unrelated* directory event happens to trigger a fresh scan.

**2. Concurrent scans can publish out of order.** Both `setFolder` and
`refreshFileTreeAsync` dispatch `buildTree` onto `DispatchQueue.global()` —
a *concurrent* queue, not serial — with no generation token. If two scans
overlap (rapid external changes, or the initial load overlapping with an
early watcher event), whichever finishes last wins on the main-thread
publish, even if it started from an *older* snapshot. Net effect: the
sidebar can show stale contents until some later event forces another scan.

**3. No test coverage** exists for `DirectoryWatcher`/`FolderManager`'s
FSEvents lifecycle at all — by contrast, the analogous `FileWatcher` (for
individual open documents) already has a lifecycle regression test in
`zMDTests/InlineMarkdownTests.swift` pinning its own past fd-teardown bug.
This plan adds the sidebar-side equivalent.

## Current state

- `zMD/FolderManager.swift` — folder-sidebar state and file-tree building.
- `zMD/DirectoryWatcher.swift` — FSEvents wrapper, debounces and calls back
  into `FolderManager`.

The suppression-drop bug:

```swift
// zMD/FolderManager.swift:88-105
/// Rebuild file tree on a background queue; publish back to main.
/// The DirectoryWatcher fires this after its 300ms debounce, so rapid-fire external edits
/// produce one background rebuild each — still O(N) per event, but at least the main thread
/// stays responsive.
private func refreshFileTreeAsync() {
    guard let folderURL = folderURL else { return }
    // Suppress the rebuild if it was almost certainly caused by our own save. Without this,
    // every save in folder mode triggers a full O(N) tree scan (M8).
    if Date().timeIntervalSince(lastSelfWriteAt) < Self.selfWriteSuppressionWindow {
        return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self, folderURL] in
        let tree = self?.buildTree(at: folderURL, relativeTo: folderURL) ?? []
        DispatchQueue.main.async {
            self?.fileTree = tree
        }
    }
}
```

The concurrent-scan-race sites (note both dispatch to the same *concurrent*
global queue with no ordering token):

```swift
// zMD/FolderManager.swift:74-79 (setFolder)
DispatchQueue.global(qos: .userInitiated).async { [weak self, url] in
    let tree = self?.buildTree(at: url, relativeTo: url) ?? []
    DispatchQueue.main.async {
        self?.fileTree = tree
    }
}
```

```swift
// zMD/FolderManager.swift:99-104 (refreshFileTreeAsync, same block quoted above)
```

`DirectoryWatcher`'s debounce/callback shape, for context on timing (full
file, already read):

```swift
// zMD/DirectoryWatcher.swift:85-90
private func handleChange() {
    debounceTimer?.invalidate()
    debounceTimer = Timer.scheduledTimer(withTimeInterval: Timing.directoryWatcherDebounce, repeats: false) { [weak self] _ in
        self?.onChange()
    }
}
```

`Timing.directoryWatcherDebounce` and `Timing.directoryWatcherLatency` — find
their values (grep `Timing` struct, likely in `SettingsManager.swift` given
the `Timing.autoSaveDebounce` reference already seen there) before writing
the test in Step 3, since the test needs to wait longer than these values.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |
| Find Timing constants | `grep -n "directoryWatcherDebounce\|directoryWatcherLatency\|selfWriteSuppressionWindow" zMD/*.swift` | shows the values |

## Scope

**In scope**:
- `zMD/FolderManager.swift`
- `zMDTests/InlineMarkdownTests.swift` (or a new `FolderManagerTests.swift` —
  same judgment call as Plan 001's Step 2; if Plan 001 already created a
  separate `FolderManagerTests.swift` file, add to that one instead of
  duplicating).

**Out of scope**:
- `zMD/DirectoryWatcher.swift` — read-only for this plan; its debounce
  behavior is correct as-is, the bug is in how `FolderManager` reacts to it.
- Plan 001's symlink-cycle fix — separate concern, separate plan, even
  though it's the same file.

## Git workflow

- Branch: `advisor/007-folder-sidebar-lifecycle`
- Recommend two commits: one for the suppression-drop fix, one for the
  scan-ordering fix + tests (or three if you prefer one test file addition
  per fix — either is fine).

## Steps

### Step 1: Fix the suppression-window drop with a deferred rescan

When a rescan is suppressed because it's within the self-write window,
schedule exactly one deferred rescan to fire just after the window closes,
instead of dropping the event entirely. Use a single reusable timer so
rapid-fire suppressed events don't stack up multiple deferred rescans:

```swift
private var deferredRescanTimer: Timer?

private func refreshFileTreeAsync() {
    guard let folderURL = folderURL else { return }
    let elapsed = Date().timeIntervalSince(lastSelfWriteAt)
    if elapsed < Self.selfWriteSuppressionWindow {
        // Suppressed because this is almost certainly an echo of our own save. But if this
        // FS event turns out to be the ONLY one in the suppression window (a genuine external
        // edit landing in the same ~800ms as our save), dropping it silently leaves the
        // sidebar stale with no future event to correct it. Schedule one rescan just past the
        // window to catch that case, coalescing if we're already scheduled.
        deferredRescanTimer?.invalidate()
        let remaining = Self.selfWriteSuppressionWindow - elapsed
        deferredRescanTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            self?.performTreeScan(for: folderURL)
        }
        return
    }
    performTreeScan(for: folderURL)
}

private func performTreeScan(for folderURL: URL) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self, folderURL] in
        let tree = self?.buildTree(at: folderURL, relativeTo: folderURL) ?? []
        DispatchQueue.main.async {
            self?.fileTree = tree
        }
    }
}
```

(This introduces `performTreeScan` as a shared helper — reuse it in Step 2
for `setFolder` as well, so both call sites go through the same
scan-issuing path, which also makes Step 2's ordering fix apply uniformly.)

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 2: Fix scan-ordering with a monotonic generation token

Add a scan-generation counter that increments on every new scan request;
each in-flight scan captures its own generation number when started, and
the main-thread publish only applies if that generation is still the
latest one issued (i.e., no newer scan has since been requested):

```swift
private var scanGeneration = 0

private func performTreeScan(for folderURL: URL) {
    scanGeneration += 1
    let generation = scanGeneration
    DispatchQueue.global(qos: .userInitiated).async { [weak self, folderURL] in
        let tree = self?.buildTree(at: folderURL, relativeTo: folderURL) ?? []
        DispatchQueue.main.async {
            guard let self = self, generation == self.scanGeneration else { return }
            self.fileTree = tree
        }
    }
}
```

Update `setFolder`'s initial scan (`FolderManager.swift:74-79`) to call this
same `performTreeScan(for:)` helper instead of its own inline
`DispatchQueue.global` block, so both entry points share the generation
counter.

This does not make scans strictly serial (they still run concurrently on
the global queue) — it only ensures a stale (superseded) result is dropped
rather than published. This is the minimal correct fix; a fully serial queue
(alternative: a dedicated serial `DispatchQueue`, matching the
`docxExportQueue` pattern used elsewhere in this codebase for a similar
overlapping-work concern) is also acceptable if you find the generation-token
approach awkward to wire through both call sites — pick whichever you find
cleaner, but the generation-token approach is preferred since it avoids
adding a new queue and is a smaller diff.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 3: Add lifecycle tests

Add tests modeled on the existing `FileWatcher` lifecycle test pattern at
`zMDTests/InlineMarkdownTests.swift:190-214` (`testFileWatcherSurvivesIgnoredAtomicRenameAndReportsLaterEdit`)
— that test builds a real temp directory, drives real file operations, and
uses `XCTestExpectation` with a generous timeout since FSEvents timing is
inherently async and can't be mocked cleanly.

```swift
final class FolderManagerLifecycleTests: XCTestCase {
    func testExternalEditWithinSuppressionWindowIsEventuallyReflected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-folder-suppress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.md")
        try "initial".write(to: fileA, atomically: true, encoding: .utf8)

        let manager = FolderManager()
        manager.setFolder(root)

        // Give the initial scan time to complete and publish.
        let initialScan = expectation(description: "initial scan completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { initialScan.fulfill() }
        wait(for: [initialScan], timeout: 3.0)
        XCTAssertTrue(manager.fileTree.contains { $0.name == "a.md" })

        // Simulate zMD's own save (marks the suppression window), then immediately write a
        // SECOND file externally within that window — this is the exact scenario the bug drops.
        manager.noteSelfWrite(at: fileA)
        let fileB = root.appendingPathComponent("b.md")
        try "external".write(to: fileB, atomically: true, encoding: .utf8)

        // Wait past the suppression window (800ms) plus the deferred-rescan timer plus the
        // DirectoryWatcher's own debounce, with margin.
        let eventuallyReflected = expectation(description: "b.md eventually appears in sidebar")
        var attempts = 0
        func poll() {
            attempts += 1
            if manager.fileTree.contains(where: { $0.name == "b.md" }) {
                eventuallyReflected.fulfill()
            } else if attempts < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
            }
        }
        poll()
        wait(for: [eventuallyReflected], timeout: 6.0)
    }
}
```

Adjust polling/timeout numbers if `Timing.selfWriteSuppressionWindow`,
`Timing.directoryWatcherDebounce`, or `Timing.directoryWatcherLatency`
(found via the grep in "Commands you will need") are larger than assumed
here — the test must wait comfortably longer than the sum of all three.

If `FolderManager`'s initializer is private/inaccessible (same caveat as
Plan 001, Step 2), fall back to driving `FolderManager.shared` with
save/restore of its `folderURL`/`fileTree` state around the test, following
the pattern in `RuntimeSmokeTests`.

**Verify**: `xcodebuild ... test -destination 'platform=macOS'` → passes. Confirm the test fails (times out) if you temporarily revert Step 1's fix, to prove it's a real regression pin.

## Test plan

- `testExternalEditWithinSuppressionWindowIsEventuallyReflected` (Step 3) —
  the primary pin for bug #1. Must fail without Step 1's fix.
- No dedicated test written for bug #2 (scan-ordering race) — it's
  inherently timing-dependent and hard to reproduce deterministically in a
  unit test without artificially injecting delays into `buildTree`, which
  would require a testability seam this plan doesn't otherwise need. Verify
  bug #2's fix by code review (the generation-token guard is straightforward
  to read correctness from) rather than a flaky timing test. If you want to
  add a determinism-forcing test anyway (e.g. inject an artificial delay via
  a test-only hook), that's a reasonable stretch goal but not required for
  Done criteria.

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass, including the new lifecycle test
- [ ] The new test fails (times out) when Step 1's fix is temporarily reverted
- [ ] `grep -n "scanGeneration" zMD/FolderManager.swift` shows the new generation-token guard used at both `setFolder` and `refreshFileTreeAsync`'s scan-issuing paths
- [ ] No files outside scope modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `refreshFileTreeAsync`/`setFolder`'s current structure doesn't match the
  excerpts (drifted) — re-read live code before editing.
- The suppression-window test is flaky (fails intermittently across 3+ local
  runs) even after adjusting timeouts generously — FSEvents timing on CI
  runners can differ from local; report this rather than either disabling
  the test or setting an unreasonably long timeout that makes the suite slow.
- `FolderManager`'s initializer is fully inaccessible and `.shared` cannot
  be safely driven in a test either — report back rather than changing
  `FolderManager`'s access modifiers as a side effect of this plan.

## Maintenance notes

- The `performTreeScan` helper introduced in Step 1/2 is now the single
  path both `setFolder` and `refreshFileTreeAsync` use to issue a scan —
  any future third call site (if one is added) should route through it too,
  to keep the generation-token guard meaningful.
- If `buildTree`'s cost ever becomes a real bottleneck on very large
  directory trees, the generation-token approach in Step 2 does NOT cancel
  an in-flight (soon-to-be-stale) scan — it just discards its result. A
  future optimization could add actual cancellation (e.g. checking the
  generation token periodically *during* the recursive walk, not just at
  publish time), but that's out of scope here since `buildTree`'s cost
  hasn't been shown to be a problem in practice — don't add that complexity
  speculatively.
