# 003 — Honor Reduce Motion in movement tokens and AppKit scrolls

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: HIGH
- **Category**: Accessibility
- **Estimated scope**: 5 files, ~15 lines changed

## Problem

The `Motion` token system honors macOS's Reduce Motion setting only in
`standard`/`morph` (they return `nil`). `fast` and `entrance` never check it,
so *movement* leaks through at every site that uses them for position/size
changes. Separately, the AppKit heading-jump scroll hardcodes a 0.3s animated
scroll with no reduced-motion path. Reduce Motion means "fewer and gentler —
drop position changes, keep opacity/color feedback"; today the setting drops
only some movement.

`zMD/SettingsManager.swift:41-45` — current:

```swift
    /// Hover states, tiny state flips. 100–150ms class.
    static var fast: Animation { .easeOut(duration: 0.12) }
    /// Things appearing/entering (entrances want ease-out: fast start,
    /// settled end).
    static var entrance: Animation { .easeOut(duration: 0.2) }
```

Movement sites that bypass the setting today:

- `zMD/TabBar.swift:37,41` — 10% hover scale on the add-tab button.
- `zMD/WelcomeView.swift:62,66` — 3% hover scale on the Open File button.
- `zMD/WelcomeView.swift:106` — recents-list collapse on Clear.
- `zMD/ToastManager.swift:70` — remaining toasts slide on every dismissal.
- `zMD/MarkdownTextView.swift:372-375` — 0.3s animated heading jump.

(Other `fast`/`entrance` sites are being fixed by their own plans:
`ContentView.swift:88` by plan 004, `CommandPaletteView.swift:279` by 002,
`TabBar.swift:115,146` by 008, `ToastManager.swift:46` by 009. Do not touch
those here.)

## Target

Add movement-aware optional variants to `Motion` (mirroring how `standard`
returns `nil`), then swap the movement sites above. Hover sites keep their
color fade (`Motion.fast` stays) but drop the scale under Reduce Motion.

In `zMD/SettingsManager.swift`, after line 45 (`entrance`):

```swift
    /// Like `fast`, but nil under Reduce Motion — use for anything that
    /// changes position or size (scales, reflows, slides). Keep `fast` for
    /// color-only fades, which stay enabled either way.
    static var fastMovement: Animation? { reduceMotion ? nil : fast }
    /// Like `entrance`, but nil under Reduce Motion.
    static var entranceMovement: Animation? { reduceMotion ? nil : entrance }
```

Hover-scale sites — gate the scale value, keep the color animation:

```swift
// zMD/TabBar.swift:37 — target
.scaleEffect(addButtonHovered && !Motion.reduceMotion ? 1.1 : 1.0)
```

```swift
// zMD/WelcomeView.swift:62 — target
.scaleEffect(buttonHovered && !Motion.reduceMotion ? 1.03 : 1.0)
```

Animation swaps (`withAnimation` accepts an optional `Animation?`; `nil`
means the change applies instantly):

```swift
// zMD/WelcomeView.swift:106 — target
withAnimation(Motion.entranceMovement) {
```

```swift
// zMD/ToastManager.swift:70 — target
withAnimation(Motion.entranceMovement) {
```

AppKit heading jump — zero duration under Reduce Motion:

```swift
// zMD/MarkdownTextView.swift:372-375 — target
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.reduceMotion ? 0 : 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: clampedY))
```

## Repo conventions to follow

- The `Motion` enum is the declared "single edit point" for motion
  (`zMD/SettingsManager.swift:32-34`); the new variants follow the existing
  `standard`/`morph` pattern of returning `Animation?` — see lines 47-57.
- `Motion.reduceMotion` (`SettingsManager.swift:37-39`) already exists; use
  it, don't add a new environment read.

## Steps

1. `zMD/SettingsManager.swift`: insert `fastMovement` and `entranceMovement`
   (verbatim from Target) after the `entrance` property at line 45.
2. `zMD/TabBar.swift:37`: gate the hover scale as shown. Leave the
   `withAnimation(Motion.fast)` at line 41 alone — the color fade stays.
3. `zMD/WelcomeView.swift:62`: gate the hover scale as shown. Leave line 66
   alone.
4. `zMD/WelcomeView.swift:106`: change `Motion.entrance` to
   `Motion.entranceMovement`.
5. `zMD/ToastManager.swift:70`: change `Motion.entrance` to
   `Motion.entranceMovement`.
6. `zMD/MarkdownTextView.swift:373`: change `context.duration = 0.3` to the
   conditional from Target.

## Boundaries

- Do NOT make `fast`/`entrance` themselves optional — color-only hover fades
  (e.g. `FolderSidebarView.swift:39,137`, `OutlineView.swift:98`,
  `RecentFileButtonStyle.swift:14`) correctly stay animated under Reduce
  Motion and use these tokens.
- Do NOT touch the sites owned by plans 002, 004, 008, 009 (listed above).
- Do NOT touch the split-mode scroll sync (`scrollToPercent`) — plan 001
  removes that animation outright.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**: System Settings → Accessibility → Display → Reduce Motion:
  ON. Relaunch the app, then:
  - Hover the tab-bar "+" and the welcome "Open File" button: background
    color still fades in, but the button no longer grows.
  - Trigger two toasts (e.g. cause two quick errors) and let them dismiss:
    the remaining toast fades out but does not slide.
  - Click a heading in the outline: the editor jumps instantly instead of
    gliding for 0.3s.
  - Turn Reduce Motion OFF and repeat: all motion returns.
- **Done when**: with Reduce Motion on, no hover scale, toast slide, or
  animated scroll occurs anywhere, while color/opacity feedback remains.
