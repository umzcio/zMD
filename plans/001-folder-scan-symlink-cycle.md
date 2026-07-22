# Plan 001: Guard the folder-sidebar tree scan against symlink cycles

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/FolderManager.swift`
> If that file changed since this plan was written, compare the "Current
> state" excerpt below against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`FolderManager.buildTree` recursively walks every directory in a user-opened
folder with no cycle guard. `URL.resourceValues(forKeys: [.isDirectoryKey])`
resolves symlinks, so a directory symlink that points back at one of its own
ancestors (a cycle) is silently followed. There's no visited-set, no
`.isSymbolicLinkKey` check, and no recursion-depth cap. The result is
unbounded recursion → stack exhaustion → a hard crash (`EXC_BAD_ACCESS`).

This is worse than a one-off crash because `restoreFolder()` re-opens the
*last* folder on every app launch (`FolderManager.swift:121-140` calls
`setFolder(url)`, which triggers the same `buildTree`). If a user's folder
ever contains a symlink cycle — not exotic; self-referential or
parent-referential symlinks show up in real dev trees — the app becomes
unable to launch at all until the user manually clears
`UserDefaults` (`bookmarkKey`) outside the app, which most users won't know
how to do.

## Current state

- `zMD/FolderManager.swift` — folder-sidebar state, file-tree building,
  security-scoped bookmark persistence. Single file for this fix.

The vulnerable function, read in full from the current tree:

```swift
// zMD/FolderManager.swift:144-188
private func buildTree(at url: URL, relativeTo root: URL) -> [FileTreeItem] {
    let fileManager = FileManager.default
    guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
        return []
    }

    var directories: [FileTreeItem] = []
    var files: [FileTreeItem] = []

    for item in contents {
        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let relativePath = item.path.replacingOccurrences(of: root.path, with: "")

        if isDir {
            let children = buildTree(at: item, relativeTo: root)
            // Only include directories that contain markdown files (directly or nested)
            if containsMarkdownFiles(children) {
                directories.append(FileTreeItem(
                    id: relativePath,
                    url: item,
                    name: item.lastPathComponent,
                    isDirectory: true,
                    children: children
                ))
            }
        } else {
            let ext = item.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                files.append(FileTreeItem(
                    id: relativePath,
                    url: item,
                    name: item.lastPathComponent,
                    isDirectory: false,
                    children: nil
                ))
            }
        }
    }

    // Sort: directories first (alpha), then files (alpha)
    directories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    return directories + files
}
```

Both call sites run this off-main already (no main-thread concern here):

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
// zMD/FolderManager.swift:99-104 (refreshFileTreeAsync)
DispatchQueue.global(qos: .userInitiated).async { [weak self, folderURL] in
    let tree = self?.buildTree(at: folderURL, relativeTo: folderURL) ?? []
    DispatchQueue.main.async {
        self?.fileTree = tree
    }
}
```

- Repo convention for this kind of fix: prefer the smallest correct guard,
  not a rewrite. This codebase's error-handling style is `try?` +
  early-return with a comment explaining the non-obvious "why" (see the
  comment above `refreshFileTreeAsync` at `FolderManager.swift:88-91`
  documenting the self-write-suppression rationale) — match that style: one
  or two lines of comment on *why* the guard exists, not what it does.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all tests pass |

## Scope

**In scope** (the only files you should modify):
- `zMD/FolderManager.swift`
- `zMDTests/InlineMarkdownTests.swift` — or a new `zMDTests/FolderManagerTests.swift` if you prefer a separate file (either is fine; `FolderManager.buildTree` is `private`, so see Step 2 for how to reach it from a test).

**Out of scope** (do NOT touch, even though they look related):
- `FolderManager.refreshFileTreeAsync`'s self-write-suppression logic and the
  concurrent-scan race — those are Plan 007. Don't fix them here; keep this
  change scoped to the recursion guard only.
- `DirectoryWatcher.swift` — unrelated (FSEvents plumbing, not the tree
  builder).

## Git workflow

- Branch: `advisor/001-folder-symlink-cycle` (repo has no established
  branch-naming convention from git log; this is a reasonable default —
  adjust if the operator specifies otherwise).
- One commit for the fix, one for the test, or combined — match whatever
  granularity the rest of the branch's commits use. Recent commit style in
  this repo: short imperative subject line, blank line, body explaining
  *why*, e.g. `fix: editor could save one document's text into another file
  on tab switch` (see `git log --oneline -10`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a symlink guard to `buildTree`

Change `buildTree` to skip any directory entry that is itself a symbolic
link. This is the cheapest complete fix: `.isDirectoryKey` follows the
symlink to classify it as a directory, but you can independently ask whether
the *entry itself* is a symlink via `.isSymbolicLinkKey`, and skip recursing
into it if so. A symlinked directory is excluded from the sidebar entirely
(same as any other item the scan can't safely walk) rather than partially
included — that's the simplest behavior to reason about and test.

Modify the resource-key fetch and the directory branch:

```swift
for item in contents {
    let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let isDir = resourceValues?.isDirectory ?? false
    let isSymlink = resourceValues?.isSymbolicLink ?? false
    let relativePath = item.path.replacingOccurrences(of: root.path, with: "")

    if isDir {
        // Skip symlinked directories — buildTree resolves .isDirectoryKey through
        // symlinks with no cycle detection, so a directory symlink pointing back at
        // an ancestor (or itself) recurses until the stack overflows and the app
        // crashes. Since restoreFolder() re-opens the last folder on every launch,
        // an unguarded cycle here is a crash-on-launch loop a user can't self-fix.
        guard !isSymlink else { continue }
        let children = buildTree(at: item, relativeTo: root)
        ...
```

Keep the rest of the function (the `else` file branch, sorting, return)
unchanged.

**Verify**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` → `** BUILD SUCCEEDED **`

### Step 2: Add a regression test with a real symlink cycle

`buildTree` is `private`, so drive it through the public entry point,
`setFolder(_:)`, using a temp directory you construct with an actual
self-referential symlink — this is the only way to prove the guard works
end-to-end rather than asserting on internals.

Add to `zMDTests/InlineMarkdownTests.swift` (a new `XCTestCase` subclass at
the bottom of the file, after `RuntimeSmokeTests`, is fine — or a new file;
match whichever you find cleaner) something structurally like:

```swift
final class FolderManagerTests: XCTestCase {
    func testFolderScanDoesNotRecurseIntoSymlinkCycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmd-symlink-cycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A real markdown file so the folder isn't filtered out as empty.
        try "hello".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        // A directory symlink pointing back at `root` itself — the simplest cycle.
        let cycleLink = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: cycleLink, withDestinationURL: root)

        let manager = FolderManager()
        let done = expectation(description: "tree scan completes without crashing")

        // setFolder dispatches the scan async and publishes fileTree on main;
        // poll briefly rather than relying on a Combine subscription to keep this
        // test dependency-free.
        manager.setFolder(root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            done.fulfill()
        }
        wait(for: [done], timeout: 3.0)

        // Reaching here without a crash/timeout is the primary assertion. Also
        // confirm the real file surfaced and the cyclic symlink did not appear
        // as a nested directory entry.
        XCTAssertTrue(manager.fileTree.contains { $0.name == "note.md" })
        XCTAssertFalse(manager.fileTree.contains { $0.name == "loop" })
    }
}
```

Check `FolderManager`'s initializer is accessible for a fresh instance (not
just `.shared`) before writing this — if `init()` is private, either add an
`internal`/test-only initializer or drive the test through
`FolderManager.shared` instead (save/restore its `fileTree`/`folderURL`
around the test the same way `RuntimeSmokeTests` saves/restores
`DocumentManager.shared` state, per the existing pattern at
`zMDTests/InlineMarkdownTests.swift:92-121`). Prefer a fresh instance if
possible — it avoids polluting shared state — but match whichever the actual
type allows.

**Verify**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` → all tests pass, including this new one. Confirm it actually exercises the guard by temporarily reverting Step 1 and re-running — the test must fail (timeout or crash) without the fix, and pass with it.

## Test plan

- New test: `testFolderScanDoesNotRecurseIntoSymlinkCycle` (Step 2) — the
  primary regression pin. It must fail without Step 1's fix (verify this
  before finishing) and pass with it.
- No existing test structurally matches this (folder scanning has zero prior
  coverage) — this is a fresh characterization test, not a modification.
- Verification: `xcodebuild ... test -destination 'platform=macOS'` → all
  pass.

## Done criteria

- [ ] `xcodebuild ... build` exits with `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` exits 0; the new symlink-cycle test exists and passes
- [ ] The new test fails (crash or timeout) when Step 1's guard is temporarily reverted — confirms the test is real, not a false-positive
- [ ] `grep -n "isSymbolicLinkKey" zMD/FolderManager.swift` finds the new guard
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `buildTree`'s signature or resource-key usage at `FolderManager.swift:144-188`
  doesn't match the excerpt above (the codebase has drifted since this plan
  was written).
- `FolderManager`'s initializer cannot be reached at all in tests (neither a
  fresh instance nor safely driving `.shared`) — report back with what you
  found rather than restructuring `FolderManager`'s singleton pattern to fit.
- The build fails for a reason unrelated to this change (pre-existing
  breakage) — report it, don't attempt an unrelated fix.

## Maintenance notes

- If `buildTree` is ever converted to use `FileManager.enumerator(at:...)`
  instead of manual recursion (a plausible future perf refactor — see Plan
  013's testability-seam work, which touches adjacent code), that
  enumerator also needs `.skipsSubdirectoryDescendants` handling for
  symlinked directories, or `.isSymbolicLinkKey` filtering in the
  `while let item = enumerator.nextObject()` loop. Don't assume switching
  APIs preserves this fix automatically.
- This fix does not address Plan 007's self-write-suppression drop or
  concurrent-scan-ordering race — those are separate, independent bugs in
  the same file. Do not conflate their fixes with this one.
