# Plan 017: Decide and consolidate the help surface — native .help bundle vs. HelpView sheet

> **Executor instructions**: This is a decision-plus-mechanical-cleanup
> plan, not a pure design spike — the decision itself is made *in* this
> plan (see "Why this matters" and the Recommendation below); your job is
> to execute the mechanical consequence of that decision and verify it.
> Follow the plan step by step, verifying each step. If a "STOP conditions"
> trigger occurs, stop and report. Update `plans/README.md`'s status row
> when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- Info.plist zMD/zMDApp.swift zMD/HelpView.swift`
> and `ls zMD/zMD.help` — confirm the bundle still exists as described
> before proceeding.

## Status

- **Priority**: P3 (direction)
- **Effort**: S (deletion path) — this plan recommends deletion, which is
  the smaller of the two options; if the plan owner instead wants the
  bundle wired up via `NSHelpManager`, that's a different, S-M plan not
  written here (see Maintenance notes).
- **Risk**: LOW — removing an unreferenced bundle.
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

The app ships **two** separate, non-overlapping help contents:

1. `zMD/zMD.help/Contents/Resources/en.lproj/index.html` — a real,
   populated Apple Help Book, registered in `Info.plist`
   (`CFBundleHelpBookFolder`/`CFBundleHelpBookName`) and copied into the
   app bundle at build time.
2. `zMD/HelpView.swift` — a SwiftUI sheet (`HelpView`) that loads its own
   separately-written HTML into a `WKWebView`, shown via a custom
   `$showingHelp` state flag, replacing the standard macOS Help menu
   behavior.

The Help menu is wired to show `HelpView` (`zMDApp.swift`), not to
`NSHelpManager`/`openHelpAnchor` (confirmed: no call to either exists
anywhere in the codebase). This means the `.help` bundle is built, signed,
and shipped inside every release, registered in `Info.plist` as if it's the
real help system — but **no code path ever opens it**. It's dead weight
with a maintenance trap attached: two help contents to keep in sync
(currently already drifted — `HelpView`'s content and the `.help` bundle's
content are not identical), one of which no user can ever reach.

**Recommendation (made here, not deferred to the executor):** delete the
orphaned `.help` bundle and its `Info.plist` registration; keep
`HelpView.swift` as the one, reachable help surface. Rationale: `HelpView`
is the one actually wired to the Help menu and ⌘? shortcut; rewriting the
Help menu to use `NSHelpManager` instead would mean losing `HelpView`'s
custom sheet UI (with its visible/accessible close button, deliberately
built per its own code comment fixing a prior accessibility issue) for the
generic system Help Viewer — a downgrade with no clear upside. Deletion is
also the lower-risk, smaller change. If the plan owner disagrees and wants
the native Help Book instead, that reverses which file to delete — flag
this clearly in your final report so it's an easy decision to override if
wrong, but proceed with the deletion path as written unless told otherwise
before starting.

## Current state

`Info.plist` registration to remove — locate and read the exact keys
(the audit that surfaced this finding cited these key names but you must
confirm exact current values before deleting):

```bash
grep -n "CFBundleHelpBookFolder\|CFBundleHelpBookName" Info.plist
```

The `.help` bundle to remove:

```bash
find zMD/zMD.help -type f
```

Confirm this bundle is referenced in the Xcode project (it must be, to be
copied into the build product) — find its build-phase membership:

```bash
grep -n "zMD.help" zMD.xcodeproj/project.pbxproj
```

`HelpView.swift` — already read in full; this is the surface being kept,
unchanged by this plan except possibly gaining content merged in from the
deleted bundle if it has anything `HelpView` currently lacks (see Step 2).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Confirm no remaining references | `grep -rn "zMD.help\|CFBundleHelpBook\|NSHelpManager\|openHelpAnchor" zMD/ Info.plist zMD.xcodeproj/project.pbxproj` | no matches after cleanup |
| Confirm built app no longer contains the bundle | `ls "$(find /Users/*/Library/Developer/Xcode/DerivedData -maxdepth 1 -name 'zMD-*' -print -quit)/Build/Products/Debug/zMD.app/Contents/Resources/" \| grep -i help` (adjust DerivedData path glob if it doesn't resolve; this is a sanity check, not load-bearing for Done criteria if the path can't be resolved in your environment) | no `.help` bundle present |

## Scope

**In scope**:
- `Info.plist` — remove the `CFBundleHelpBookFolder`/`CFBundleHelpBookName` keys.
- `zMD.xcodeproj/project.pbxproj` — remove the `.help` bundle's build-phase
  membership and file references (this requires editing the `.pbxproj`
  directly — the same kind of edit this repo's own `CLAUDE.md` describes as
  needed "Ruby script to modify .pbxproj" for *additions*; for a *removal*,
  carefully deleting the corresponding `PBXFileReference`/`PBXBuildFile`/
  group-membership/build-phase entries by hand is more standard than
  writing a script for a one-time deletion — but back up the file or work
  on a branch so a mistake is easily reverted, and verify the build
  succeeds immediately after).
- `zMD/zMD.help/` — delete the directory from disk (git remove).
- `zMD/HelpView.swift` — only if Step 2 finds unique content worth merging
  in from the deleted bundle.

**Out of scope**:
- `HelpView.swift`'s own content/structure beyond the possible merge in
  Step 2 — this plan doesn't redesign the help sheet.
- The Help menu wiring itself (`zMDApp.swift`'s `.commands`/`$showingHelp`)
  — already correctly points at `HelpView`; nothing to change there.

## Git workflow

- Branch: `advisor/017-remove-orphaned-help-bundle`
- One commit for the deletion + Info.plist/pbxproj cleanup, a second if
  Step 2 produces a content merge into `HelpView.swift`.

## Steps

### Step 1: Confirm the bundle is genuinely unreferenced by any code path

```bash
grep -rn "NSHelpManager\|openHelpAnchor\|CFBundleHelpBook" zMD/ Info.plist
```

Expected: only the `Info.plist` registration itself, no code reference.
This confirms the "orphaned" premise before deleting anything — if this
grep surfaces a live code reference this plan's recon missed, stop (see
STOP conditions).

### Step 2: Diff the two help contents for anything worth preserving

Read `zMD/zMD.help/Contents/Resources/en.lproj/index.html` in full and
compare its section list against `HelpView.swift`'s `helpHTML` content.
If the `.help` bundle documents anything genuinely useful that `HelpView`
currently lacks (e.g., a keyboard shortcut or feature `HelpView`'s content
omits), merge that specific content into `HelpView.swift`'s `helpHTML`
string, matching its existing HTML structure/style exactly. Do not do a
wholesale content replacement — cherry-pick only what's missing and
accurate (don't copy over anything from the `.help` bundle that's itself
stale/wrong).

**Verify**: if you made a merge edit, `xcodebuild ... build` → `** BUILD SUCCEEDED **` (confirms the Swift string literal is still valid).

### Step 3: Remove the `Info.plist` registration

Delete the `CFBundleHelpBookFolder` and `CFBundleHelpBookName` keys (and
their values) from `Info.plist`.

**Verify**: `grep -n "CFBundleHelpBook" Info.plist` → no matches.

### Step 4: Remove the bundle from the Xcode project and disk

In `zMD.xcodeproj/project.pbxproj`, find and remove every entry referencing
`zMD.help` — this typically means a `PBXFileReference` (or a folder
reference, since `.help` bundles are often added as a blue "folder
reference" rather than individual file references — check which pattern
this project uses via the grep from "Current state"), its corresponding
`PBXBuildFile` entry (if any — folder references sometimes skip this), its
membership in the app target's "Copy Bundle Resources" (or similar) build
phase, and its parent group's `children` list entry.

Then remove the directory from disk and stage the removal in git:

```bash
git rm -r zMD/zMD.help
```

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`. Then confirm the build product no longer contains the bundle (the DerivedData check in "Commands you will need").

## Test plan

No automated test covers `Info.plist`/bundle-resource contents. Verify
manually: launch the built app, open Help (⌘? or the Help menu item),
confirm `HelpView`'s sheet still opens and displays correctly (unaffected
by this plan's changes to the *other*, now-deleted help surface).

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `grep -rn "CFBundleHelpBook\|zMD.help" Info.plist zMD.xcodeproj/project.pbxproj zMD/` returns no matches
- [ ] `zMD/zMD.help/` no longer exists on disk (`git status` shows it removed)
- [ ] Manual verification: Help menu (⌘?) still opens `HelpView`'s sheet correctly in the built app
- [ ] Any content merged from the deleted bundle (Step 2, if applicable) is present in `HelpView.swift` and renders correctly
- [ ] `plans/README.md` status row updated

## STOP conditions

- Step 1's grep finds a live code reference to `NSHelpManager`/
  `openHelpAnchor`/the help bundle that this plan's recon missed — this
  contradicts the "orphaned" premise; stop and report, don't delete
  something that turns out to be reachable.
- Removing the `.pbxproj` entries by hand causes the project to fail to
  open in Xcode or produces a build error unrelated to the help bundle
  itself (a sign the manual edit corrupted something else nearby) — revert
  the `.pbxproj` change and report; don't attempt increasingly aggressive
  manual edits to a corrupted project file.

## Maintenance notes

- If the plan owner reverses this decision later (keeps the native `.help`
  Book instead of `HelpView`), the mirror-image plan would: wire the Help
  menu to `NSHelpManager.shared.openHelpAnchor` instead of showing
  `HelpView`, delete `HelpView.swift` and its `$showingHelp` state, and
  keep `zMD/zMD.help/` + its `Info.plist` registration. That's a
  meaningfully different (and slightly larger, since it touches menu-command
  wiring) plan than this one — not written here since this plan's
  recommendation is the other direction.
- Whoever next updates keyboard-shortcut documentation should know there is
  now exactly one help surface (`HelpView.swift`) to keep in sync with
  actual shortcuts — not two.
