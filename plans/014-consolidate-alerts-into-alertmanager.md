# Plan 014: Route the dirty-close/window-close confirmation dialogs through AlertManager

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/AlertManager.swift zMD/DocumentManager.swift zMD/zMDApp.swift`
> On a mismatch, re-read live code before proceeding.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW — behavior-preserving consolidation, not a redesign.
- **Depends on**: Plan 013 (if 013 lands first, its `DirtyCloseConfirming`
  seam is the natural place for the `NSAlert` construction this plan
  consolidates — do this plan's change inside
  `NSAlertDirtyCloseConfirmer.confirmDirtyClose` if it exists, otherwise
  inside `DocumentManager.resolveDirtyClose` directly). Not a hard
  blocker either way — this plan works standalone if 013 hasn't landed.
- **Category**: tech-debt
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`AlertManager` is the app's stated centralized alert wrapper (its own doc
comment says "All user-facing alerts now flow through `showNSAlert`" — a
claim from a prior cleanup pass), and it already models one/two-button
info/error dialogs and one specific three-button case
(`showFileChangedDialog`). But the app's most consequential three-button
confirmation — "Save / Don't Save / Cancel" for a dirty document — is
still hand-built as a raw `NSAlert()` directly inside
`DocumentManager.resolveDirtyClose`, and a related window-close confirmation
flow lives separately in `zMDApp.swift`'s `WindowCloseDelegate`. This is the
one alert pattern in the app not actually centralized despite the stated
convention, and a prior audit's own account of a past bug (double-prompting
on tab close) traced directly to this kind of split ownership between
multiple close paths.

## Current state

- `zMD/AlertManager.swift` — centralized alert wrapper; read in full
  (already done for this plan — reproduced relevant parts below).
- `zMD/DocumentManager.swift` — `resolveDirtyClose`, builds its own
  `NSAlert` inline.
- `zMD/zMDApp.swift` — `WindowCloseDelegate` (find and read this type in
  full before starting; this plan's excerpt of `DocumentManager` doesn't
  cover it).

`AlertManager`'s existing three-button pattern to follow (already
established convention in this exact file — match its style):

```swift
// zMD/AlertManager.swift:54-92 (showFileChangedDialog — existing 2-and-3-button pattern)
func showFileChangedDialog(fileName: String, hasUnsavedChanges: Bool = false) -> FileChangedAction {
    let alert = NSAlert()
    alert.messageText = "File Changed Externally"
    if hasUnsavedChanges {
        alert.informativeText = "\"\(fileName)\" has been modified by another application, and you have unsaved local changes. Reloading will permanently discard your edits."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard My Changes & Reload")
        alert.addButton(withTitle: "Keep My Changes")
        alert.addButton(withTitle: "Ignore All Future Changes")
        alert.buttons.first?.hasDestructiveAction = true
    } else {
        alert.informativeText = "\"\(fileName)\" has been modified by another application. Do you want to reload it?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Ignore")
        alert.addButton(withTitle: "Ignore All")
    }

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
```

The dirty-close alert this plan moves into `AlertManager`, following the
exact pattern above:

```swift
// zMD/DocumentManager.swift:653-660 (inside resolveDirtyClose)
let alert = NSAlert()
alert.messageText = "Save changes to \(document.name)?"
alert.informativeText = "If you don't save, your changes will be lost."
alert.alertStyle = .warning
alert.addButton(withTitle: "Save")
alert.addButton(withTitle: "Don't Save")
alert.addButton(withTitle: "Cancel")
alert.buttons[1].hasDestructiveAction = true

switch alert.runModal() {
```

You'll need to also find and read `WindowCloseDelegate` in
`zMD/zMDApp.swift` (search for that type name) to see whether it builds its
own separate `NSAlert` for the same "unsaved changes" decision, or whether
it already calls into `DocumentManager.closeDocument`/`resolveDirtyClose`
(the earlier fable-report remediation may have already consolidated this —
confirm before assuming there's a second inline `NSAlert` to move).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |
| Find WindowCloseDelegate | `grep -n "WindowCloseDelegate" zMD/zMDApp.swift` | shows the type and its usage |

## Scope

**In scope**:
- `zMD/AlertManager.swift` — add the new confirmation method.
- `zMD/DocumentManager.swift` — `resolveDirtyClose` (or
  `NSAlertDirtyCloseConfirmer` if Plan 013 landed first), replace inline
  `NSAlert` construction with a call into `AlertManager`.
- `zMD/zMDApp.swift` — only if `WindowCloseDelegate` genuinely has its own
  separate inline `NSAlert` for the same decision (confirm first).

**Out of scope**:
- `AlertManager.showFileChangedDialog` — already correctly centralized,
  don't touch it, just match its style.
- Any change to the actual button wording/behavior — this is purely
  "move the construction, keep the exact same alert."

## Git workflow

- Branch: `advisor/014-consolidate-dirty-close-alert`
- One commit.

## Steps

### Step 1: Add a dirty-close confirmation method to `AlertManager`

```swift
enum DirtyCloseResponse {
    case save
    case dontSave
    case cancel
}

func showDirtyCloseConfirmation(documentName: String) -> DirtyCloseResponse {
    let alert = NSAlert()
    alert.messageText = "Save changes to \(documentName)?"
    alert.informativeText = "If you don't save, your changes will be lost."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Don't Save")
    alert.addButton(withTitle: "Cancel")
    alert.buttons[1].hasDestructiveAction = true

    switch alert.runModal() {
    case .alertFirstButtonReturn: return .save
    case .alertSecondButtonReturn: return .dontSave
    default: return .cancel
    }
}
```

Place it near `showFileChangedDialog` (same "Confirmation Dialogs" `MARK`
section) to match the file's existing organization.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 2: Replace `resolveDirtyClose`'s inline alert with the new method

```swift
private func resolveDirtyClose(_ document: MarkdownDocument, onSaveFinished: ((Bool) -> Void)? = nil) -> DirtyCloseAction {
    guard document.isDirty else { return .proceed }

    switch alertManager.showDirtyCloseConfirmation(documentName: document.name) {
    case .save:
        saveDocument(id: document.id) { success in
            DispatchQueue.main.async {
                onSaveFinished?(success)
            }
        }
        return .deferToSave
    case .dontSave:
        return .discard
    case .cancel:
        return .cancel
    }
}
```

(`alertManager` — confirm `DocumentManager` already has an `AlertManager`
instance property, likely `private let alertManager = AlertManager.shared`
matching the pattern seen in `ExportManager.swift:8` — if `DocumentManager`
doesn't already have this, add it following that same pattern rather than
calling `AlertManager.shared` inline.)

If Plan 013 has already landed and `resolveDirtyClose`'s `NSAlert`
construction now lives inside `NSAlertDirtyCloseConfirmer.confirmDirtyClose`
instead, apply this same replacement there instead — the target logic is
identical, only its current location differs.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`. Re-run the full test suite — this must not change `resolveDirtyClose`'s observable behavior (all of Plan 013's characterization tests, if that plan has landed, must still pass unchanged; if 013 hasn't landed, manually verify Save/Don't Save/Cancel each still produce identical outcomes by driving the app).

### Step 3: Consolidate `WindowCloseDelegate` if it has a separate inline alert

Only if Step 0's investigation (grep for `WindowCloseDelegate`) confirms it
builds its own separate `NSAlert` for the same "unsaved changes" question:
replace that inline construction with the same
`AlertManager.showDirtyCloseConfirmation` call, translating its response
into whatever `WindowCloseDelegate` currently does with the three outcomes
(likely: proceed with close / save-then-close / cancel-the-close). If
`WindowCloseDelegate` already delegates to `DocumentManager.closeDocument`
(which itself calls `resolveDirtyClose`) rather than building its own
alert, there's nothing to do here — confirm this and skip to Done criteria.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`. Manually verify window-close with a dirty document still prompts exactly once (not twice — this is the specific historical bug class this consolidation is meant to prevent recurrence of).

## Test plan

- If Plan 013 has landed: its characterization tests (Step 1 of that plan)
  must pass unchanged after this plan's `AlertManager` extraction — proves
  zero behavior change.
- If Plan 013 has not landed: no automated test covers `resolveDirtyClose`'s
  alert-driven behavior (it requires a real `NSAlert.runModal()`, which
  blocks in a test process) — verify manually: dirty document, tab close →
  Save/Don't Save/Cancel each behave identically to before this change;
  dirty document, window close → same; dirty document, ⌘Q → same (per the
  `prepareForTermination` chain).
- Existing `zMDTests/` suite must fully pass regardless.

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass
- [ ] `grep -n "NSAlert()" zMD/DocumentManager.swift` no longer shows the dirty-close alert construction (it's now in `AlertManager.swift`)
- [ ] Manual verification (or Plan 013's characterization tests, if present) confirms Save/Don't Save/Cancel behavior is unchanged across tab-close, window-close, and quit paths
- [ ] Window-close with a dirty document prompts exactly once, not twice
- [ ] No files outside scope modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `WindowCloseDelegate`'s actual structure doesn't match either assumption
  in Step 3 (neither "has its own inline alert" nor "already delegates to
  `closeDocument`") — read its real logic and adapt, don't force it into
  one of the two assumed shapes.
- Manual verification finds the dirty-close prompt now behaves even subtly
  differently (different button order, different default/cancel key
  binding via `.hasDestructiveAction`/button order) — this must be a pure
  move, not a redesign; if the `AlertManager` version differs from the
  original in ANY observable way, fix the `AlertManager` method to match
  the original exactly rather than accepting the drift.

## Maintenance notes

- Once this lands, any *new* multi-button confirmation dialog added to the
  app should go into `AlertManager` from the start, following either this
  method or `showFileChangedDialog` as the reference pattern — inline
  `NSAlert()` construction outside `AlertManager` should be treated as a
  code-review flag going forward.
