# 005 — Drive sidebar animations from their toggles, not broad modifiers

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: MEDIUM
- **Category**: Performance
- **Estimated scope**: 3 files, ~8 lines changed

## Problem

`zMD/NormalContentView.swift:77-78` — current:

```swift
        .animation(Motion.standard, value: folderManager.isShowingFolderSidebar)
        .animation(Motion.standard, value: showOutline)
```

These modifiers sit on the outer HStack that holds the folder sidebar, the
outline, **and** the entire editor/preview subtree. They are broad implicit
modifiers: *any* animatable change anywhere in that subtree that coincides
with a sidebar/outline state change gets swept into the 200ms interpolation —
not just the panel insert. The panel transitions themselves
(`Motion.slideOrFade` at lines 13 and 28) don't need this blanket coverage;
they need the *toggle itself* to be wrapped in animation at the call site.

(The 200ms editor-width morph when a panel opens is inherent to animating a
sidebar and is kept deliberately — it matches the app's grammar. What this
plan removes is the accidental scope, not the intended motion.)

## Target

Delete both modifiers. Wrap the two folder-sidebar mutations in
`withAnimation(Motion.standard)` at their source in `FolderManager` (the
outline toggle at `zMD/TabBar.swift:62-66` is already wrapped — that's the
exemplar).

`zMD/FolderManager.swift:81` — current:

```swift
        isShowingFolderSidebar = true
```

```swift
// target
        withAnimation(Motion.standard) {
            isShowingFolderSidebar = true
        }
```

`zMD/FolderManager.swift:155` — current:

```swift
        isShowingFolderSidebar = false
```

```swift
// target
        withAnimation(Motion.standard) {
            isShowingFolderSidebar = false
        }
```

## Repo conventions to follow

- Exemplar — the outline toggle already does exactly this at
  `zMD/TabBar.swift:62-66`:

  ```swift
      Button(action: {
          withAnimation(Motion.standard) {
              showOutline.toggle()
          }
  ```

- `Motion.standard` returns `nil` under Reduce Motion
  (`zMD/SettingsManager.swift:51-53`), so wrapped toggles degrade to instant
  automatically, and `Motion.slideOrFade` drops the slide. No extra gating.
- `withAnimation` is safe to call from `FolderManager`: both mutations already
  happen on the main thread (they drive `@Published` UI state directly).

## Steps

1. `zMD/NormalContentView.swift`: delete lines 77-78 (the two `.animation`
   modifiers on the outer HStack).
2. `zMD/FolderManager.swift:81`: wrap `isShowingFolderSidebar = true` in
   `withAnimation(Motion.standard)` as shown.
3. `zMD/FolderManager.swift:155`: wrap `isShowingFolderSidebar = false` the
   same way.

## Boundaries

- Do NOT remove or alter the `.transition(Motion.slideOrFade(...))` modifiers
  at `NormalContentView.swift:13` and `:28` — they carry the motion.
- Do NOT touch `TabBar.swift:62-66`; it is already correct.
- Do NOT add any new `.animation(value:)` modifier to replace the deleted
  ones — if a sidebar toggle site exists that isn't wrapped, wrap that site,
  never re-add the blanket modifier. (As of the commit stamp, lines 81 and
  155 are the only two writers of `isShowingFolderSidebar`; verify with a
  grep for `isShowingFolderSidebar =` before editing.)
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds. `grep -n "isShowingFolderSidebar =" zMD/*.swift` shows writes only inside `withAnimation` blocks.
- **Feel check**:
  - Open a folder (File → Open Folder): the sidebar slides in from the
    leading edge over ~200ms and the editor narrows smoothly — identical to
    before.
  - Close the folder: mirrored.
  - Toggle the outline (sidebar button in the tab bar): unchanged behavior.
  - Switch tabs *while* a sidebar animation is running: no stray animated
    glitches in the editor (previously the broad modifier could sweep
    unrelated changes into the interpolation).
  - Reduce Motion ON: panels fade in place, no slide.
- **Done when**: the outer HStack has no `.animation` modifiers and all three
  panel toggles still animate exactly as before.
