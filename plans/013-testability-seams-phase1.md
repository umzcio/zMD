# Plan 013: Extract a testable seam for DocumentManager's dirty-close/search-replace logic (Phase 1)

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report — this plan
> is explicitly phased and improvising past a STOP condition risks
> destabilizing the app's most consequential file. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/DocumentManager.swift`
> Given this file's churn history, a mismatch here is likely — re-read the
> live file carefully before proceeding, not just spot-checking excerpts.

## Status

- **Priority**: P3
- **Effort**: L (this plan is Phase 1 of a larger effort; treat it as
  complete in itself, not a partial deliverable — it must leave the
  codebase in a fully working, fully tested state, just with a narrower
  scope than "test everything in DocumentManager")
- **Risk**: MED — touches the app's most consequential file
  (save/dirty-tracking/close logic); the whole point is to do this without
  changing observable behavior, verified by characterization tests written
  *before* any extraction.
- **Depends on**: Plan 005 (establishes the testing pattern/conventions this
  plan follows) — not a hard blocker, but do 005 first if sequencing is
  flexible.
- **Category**: tech-debt (bundles test coverage)
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`DocumentManager` (1331 lines) is a singleton (`DocumentManager.shared`)
coupling in-memory document state to `NSSavePanel`, `NSAlert`, and
`UserDefaults`/security-scoped bookmarks — all in the same methods. This
means the highest-risk logic in the app (the code that decided, correctly,
after a prior audit found a real data-loss bug, whether to save/discard/
cancel on quit and close) can only be exercised by launching the actual app
and clicking through dialogs. `zMDTests/` currently has exactly 3 tests
that reach into this file's search/replace/dirty-state behavior by directly
manipulating `@Published` properties on the singleton (see
`RuntimeSmokeTests` in `zMDTests/InlineMarkdownTests.swift`) — a clever
workaround, but it means `saveDocument`, `loadDocument`, and
`closeDocument`/`resolveDirtyClose` (the actual dialog-driving logic) remain
completely untested, because those specific methods construct and run a
real `NSAlert`/`NSSavePanel` inline, which blocks in a test process.

This plan does NOT attempt to test everything — it phases the highest-value,
lowest-risk slice first: **characterize the already-in-memory-testable
behavior** (search, replace, dirty-flag transitions, `updateContent`) that
the existing `RuntimeSmokeTests` pattern already proves is reachable, and
**extract the dirty-close decision logic** (`resolveDirtyClose`'s *decision*,
not its `NSAlert` presentation) behind a seam that can be tested without a
real dialog. Full save/load/close testability (which requires either
dependency-injecting the save-panel/alert-presentation layer, or restructuring
around a protocol) is explicitly deferred to a future Phase 2 — attempting
it in one pass on this file is the kind of high-blast-radius change this
plan's risk rating is warning about.

## Current state

- `zMD/DocumentManager.swift` — the target file.
- `zMDTests/InlineMarkdownTests.swift` — existing test file; its
  `RuntimeSmokeTests` class already establishes the pattern of driving
  `DocumentManager.shared` directly with save/restore of prior state (read
  it in full before starting — it's your template for Step 2).

The dirty-close decision logic, currently entangled with `NSAlert`
presentation in one function:

```swift
// zMD/DocumentManager.swift:648-675
private enum DirtyCloseAction { case proceed, discard, cancel, deferToSave }

private func resolveDirtyClose(_ document: MarkdownDocument, onSaveFinished: ((Bool) -> Void)? = nil) -> DirtyCloseAction {
    guard document.isDirty else { return .proceed }

    let alert = NSAlert()
    alert.messageText = "Save changes to \(document.name)?"
    alert.informativeText = "If you don't save, your changes will be lost."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Don't Save")
    alert.addButton(withTitle: "Cancel")
    alert.buttons[1].hasDestructiveAction = true

    switch alert.runModal() {
    case .alertFirstButtonReturn: // Save
        saveDocument(id: document.id) { success in
            DispatchQueue.main.async {
                onSaveFinished?(success)
            }
        }
        return .deferToSave
    case .alertSecondButtonReturn: // Don't Save
        return .discard
    default: // Cancel
        return .cancel
    }
}
```

Its callers (already partially read — re-read in full, this excerpt may be
incomplete):

```swift
// zMD/DocumentManager.swift:677-687 (closeDocument)
func closeDocument(_ document: MarkdownDocument) {
    switch resolveDirtyClose(document, onSaveFinished: { [weak self] success in
        guard success else { return }
        self?.closeDocumentWithoutPrompt(id: document.id)
    }) {
    case .cancel, .deferToSave:
        return
    case .proceed, .discard:
        closeDocumentWithoutPrompt(id: document.id)
    }
}
```

```swift
// zMD/DocumentManager.swift:732-769 (prepareForTermination — the C1 quit-safety fix)
func prepareForTermination(completion: @escaping (Bool) -> Void) -> TerminationPreparation {
    prepareForTermination(discardedDirtyDocuments: [], completion: completion)
}

private func prepareForTermination(discardedDirtyDocuments: Set<UUID>, completion: @escaping (Bool) -> Void) -> TerminationPreparation {
    guard let document = openDocuments.first(where: { $0.isDirty && !discardedDirtyDocuments.contains($0.id) }) else {
        return .terminateNow
    }

    switch resolveDirtyClose(document, onSaveFinished: { [weak self] success in
        guard success, let self = self else {
            completion(false)
            return
        }
        switch self.prepareForTermination(discardedDirtyDocuments: discardedDirtyDocuments, completion: completion) {
        case .terminateNow:
            completion(true)
        case .cancel:
            completion(false)
        case .terminateLater:
            break
        }
    }) {
    case .cancel:
        return .cancel
    case .deferToSave:
        return .terminateLater
    case .discard:
        var nextDiscarded = discardedDirtyDocuments
        nextDiscarded.insert(document.id)
        return prepareForTermination(discardedDirtyDocuments: nextDiscarded, completion: completion)
    case .proceed:
        var nextDiscarded = discardedDirtyDocuments
        nextDiscarded.insert(document.id)
        return prepareForTermination(discardedDirtyDocuments: nextDiscarded, completion: completion)
    }
}
```

Note the recursive, multi-document quit-safety logic in
`prepareForTermination` is genuinely subtle (this is exactly the code a
prior audit's Critical finding was about) — the whole point of this plan is
to make this testable *without changing its behavior at all*.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |

## Scope

**In scope**:
- `zMD/DocumentManager.swift` — `resolveDirtyClose`, `closeDocument`,
  `prepareForTermination` (both overloads) only. Do NOT touch
  `saveDocument`, `loadDocument`, `closeDocumentWithoutPrompt`, or any
  other method not directly in this call chain.
- `zMDTests/InlineMarkdownTests.swift` (or a new
  `zMDTests/DocumentManagerDirtyCloseTests.swift`) — new characterization
  and seam tests.

**Out of scope**:
- `saveDocument`/`loadDocument` — genuinely entangled with `NSSavePanel`
  and disk I/O; making those testable is Phase 2, not this plan. Do not
  attempt it here even if it looks tempting mid-refactor.
- `ExportManager`'s testability (TEST-03 from the audit) — separate file,
  separate future plan, not bundled here.
- Any UI/dialog *wording* or *button* changes — this plan changes internal
  structure only, never user-facing behavior.

## Git workflow

- Branch: `advisor/013-documentmanager-testability-phase1`
- Recommended commit sequence (each independently buildable/testable —
  this matters more here than in smaller plans, given the risk level):
  1. Characterization tests for existing in-memory-reachable behavior
     (search/replace/dirty-flag — extends the existing `RuntimeSmokeTests`
     coverage; no production code change yet).
  2. Extract the *decision* seam (Step 2 below) — production code change,
     verified against the tests from commit 1 plus new decision-seam tests,
     with zero behavior change.

## Steps

### Step 1: Extend characterization tests for already-testable behavior

Before changing any production code, add tests that lock in current
behavior for the in-memory-reachable slice `RuntimeSmokeTests` doesn't yet
cover. Model these directly on the existing pattern (save/restore
`DocumentManager.shared` state around each test):

- `updateContent` setting `isDirty = true` and scheduling (or not
  scheduling, when `autoSaveEnabled` is false) an autosave timer.
- `hasUnsavedChanges()` returning `true`/`false` correctly across multiple
  open documents with mixed dirty states.
- `closeDocument` on a **non-dirty** document closing immediately with no
  alert shown (i.e., the `guard document.isDirty else { return .proceed }`
  fast path) — this is testable today with zero refactor, since the alert
  path is never reached for a clean document.

**Verify**: `xcodebuild ... test -destination 'platform=macOS'` → all pass, including the new characterization tests.

### Step 2: Extract the dirty-close *decision* from its `NSAlert` *presentation*

Introduce a protocol for "ask the user what to do about a dirty document,"
with the real `NSAlert`-driving implementation as the production default and
a test double available for tests:

```swift
protocol DirtyCloseConfirming {
    /// Returns the user's choice for a single dirty document, synchronously.
    /// (Matches resolveDirtyClose's current synchronous NSAlert.runModal() contract —
    /// this seam does not change sync/async behavior, only who decides the answer.)
    func confirmDirtyClose(for document: MarkdownDocument) -> DocumentManager.DirtyCloseAction
}

final class NSAlertDirtyCloseConfirmer: DirtyCloseConfirming {
    func confirmDirtyClose(for document: MarkdownDocument) -> DocumentManager.DirtyCloseAction {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.name)?"
        alert.informativeText = "If you don't save, your changes will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
```

Note this changes `DirtyCloseAction`'s shape slightly — the original enum
conflates "what the user chose" (`save`/`discard`/`cancel`) with "what the
caller should do next" (`.deferToSave` for the async-save-in-progress case).
Keep `DocumentManager`'s existing `DirtyCloseAction` enum and its
`.proceed`/`.discard`/`.cancel`/`.deferToSave` cases **exactly as they
are** for the caller-facing contract (`closeDocument`, `prepareForTermination`
must not change) — introduce the new protocol's return type as a *simpler*
concept (`.save`/`.discard`/`.cancel`, the raw user choice) and have
`resolveDirtyClose` translate between the two, preserving 100% of its
current behavior:

```swift
private var dirtyCloseConfirmer: DirtyCloseConfirming = NSAlertDirtyCloseConfirmer()

private func resolveDirtyClose(_ document: MarkdownDocument, onSaveFinished: ((Bool) -> Void)? = nil) -> DirtyCloseAction {
    guard document.isDirty else { return .proceed }

    switch dirtyCloseConfirmer.confirmDirtyClose(for: document) {
    case .save:
        saveDocument(id: document.id) { success in
            DispatchQueue.main.async {
                onSaveFinished?(success)
            }
        }
        return .deferToSave
    case .discard:
        return .discard
    case .cancel:
        return .cancel
    }
}
```

Add a test-only way to swap `dirtyCloseConfirmer` (e.g. make the property
`internal` rather than `private`, or add an `internal` setter/init
parameter reachable from `@testable import zMD` — match whatever access-
control pattern the existing `ExportManager.safeDOCXHyperlinkURL` testable-
exposure already establishes in this codebase, per Plan 004's Step 3 note
about that same pattern).

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`. Then re-run Step 1's characterization tests — they must still pass unchanged (proves zero behavior change from the extraction).

### Step 3: Add seam-driven tests for `prepareForTermination`'s multi-document logic

This is the actual payoff — with the confirmer swappable, you can now test
the recursive multi-dirty-document quit logic without a real dialog:

```swift
final class FakeDirtyCloseConfirmer: DirtyCloseConfirming {
    var responses: [DocumentManager.DirtyCloseAction]  // consumed in order, one per call
    private var callIndex = 0
    init(responses: [DocumentManager.DirtyCloseAction]) { self.responses = responses }
    func confirmDirtyClose(for document: MarkdownDocument) -> DocumentManager.DirtyCloseAction {
        defer { callIndex += 1 }
        return callIndex < responses.count ? responses[callIndex] : .cancel
    }
}
```

(Adjust this fake's shape to whatever the actual protocol/enum ends up
being after Step 2 — the sketch above assumes the protocol's return type
IS `DirtyCloseAction` directly for simplicity, but Step 2 as written keeps
a translation layer; pick whichever is cleaner once you're actually writing
the code, and keep the fake's shape consistent with the real protocol.)

Write at minimum:
- Two dirty documents, user chooses "Discard" for both → `prepareForTermination`
  eventually calls `completion(true)` (terminate proceeds) with both marked
  discarded.
- Two dirty documents, user chooses "Cancel" on the first → termination is
  cancelled (`completion(false)` or `.cancel` returned) and the *second*
  document is never even asked about (confirm the fake's `callIndex` is 1,
  not 2, after — this pins the "cancel stops the whole chain" behavior).
- One dirty document, user chooses "Save" → verify the flow defers correctly
  (`.terminateLater` returned, `onSaveFinished` eventually drives completion)
  — you'll need `saveDocument` to actually complete without a real
  `NSSavePanel`; use a document that's *not* untitled (has a real,
  writable `url`) so `saveDocument`'s untitled-panel branch is skipped and
  it writes directly to disk (a temp file, cleaned up in the test's
  `defer`) — this exercises real disk I/O in the test, which is
  acceptable here since it's the *existing* documented behavior for
  non-untitled saves, not something this plan is introducing.

**Verify**: `xcodebuild ... test -destination 'platform=macOS'` → all pass, including the new multi-document termination tests.

## Test plan

- Step 1: characterization tests for `updateContent`/`hasUnsavedChanges`/
  clean-document-close.
- Step 3: seam-driven tests for `prepareForTermination`'s multi-document
  recursive logic — covering discard-all, cancel-stops-chain, and
  save-then-continue.
- All new tests follow the save/restore-`DocumentManager.shared`-state
  pattern already established in `RuntimeSmokeTests`.
- Verification: `xcodebuild ... test -destination 'platform=macOS'` → all
  pass, both before and after Step 2's extraction (Step 2's own verify
  step explicitly checks this).

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass, including all new tests from Steps 1 and 3
- [ ] Step 1's characterization tests pass identically before AND after Step 2's extraction (confirms zero behavior change)
- [ ] `closeDocument` and `prepareForTermination`'s public signatures and `DirtyCloseAction`'s public cases are unchanged (confirm with `git diff` — only their *internals* should differ)
- [ ] The new `DirtyCloseConfirming` protocol has both a production (`NSAlertDirtyCloseConfirmer`) and test (`FakeDirtyCloseConfirmer`) implementation
- [ ] No files outside scope modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any excerpt above doesn't match the live file — this file has had
  substantial churn historically; re-read the ENTIRE relevant section (not
  just the excerpted lines) before making any change, and if the actual
  current logic differs meaningfully in shape (not just line numbers) from
  what's described here, stop and report rather than adapting a
  possibly-wrong mental model of subtle recursive logic.
- Any existing test (not just the ones you're adding) starts failing after
  Step 2's extraction — this means the extraction changed real behavior,
  which violates this plan's core constraint. Do not "fix" the test to
  match new behavior; revert the extraction and report what broke.
- You find yourself wanting to also touch `saveDocument`/`loadDocument` to
  "finish the job" — don't. That's explicitly Phase 2, deliberately
  deferred because it's a bigger, riskier change than this plan's scope.

## Maintenance notes

- **Phase 2** (deferred, not part of this plan): making `saveDocument` and
  `loadDocument` testable requires a similar seam for `NSSavePanel`
  presentation and file I/O — likely a `FileIOProviding`/`SavePanelPresenting`
  protocol pair, following the exact pattern this plan established for
  `DirtyCloseConfirming`. Whoever picks that up should treat this plan's
  `DirtyCloseConfirming` extraction as the reference pattern for style and
  risk-management (characterize first, extract with zero behavior change,
  verify old tests still pass, then add new seam-driven tests).
- `ExportManager`'s equivalent testability work (pure XML/HTML generation
  vs. `NSSavePanel`/disk-write shell) is a structurally similar problem in
  a different file — not bundled here, would be its own plan following the
  same pattern.
