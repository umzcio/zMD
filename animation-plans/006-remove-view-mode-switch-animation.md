# 006 — Remove the view-mode switch animation

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: MEDIUM
- **Category**: Purpose & frequency
- **Estimated scope**: 1 file, 1 line deleted

## Problem

`zMD/NormalContentView.swift:66-71` — current:

```swift
                        DocumentViewModeContent(
                            document: document,
                            selectedHeadingId: $selectedHeadingId
                        )
                        .animation(Motion.fast, value: documentManager.viewMode)
```

View-mode switching (source / preview / split) is bound to ⌘1/⌘2/⌘3 — a
tens-to-hundreds-per-day keyboard action, the frequency class that should not
animate. Worse, the modifier can't even do its job: `DocumentViewModeContent`
swaps whole view trees (`NSTextView`-based editor ↔ `WKWebView`-based
preview), which a 120ms implicit layout animation cannot interpolate. The
content hard-swaps regardless — the modifier is pure cost (extra layout
passes on every mode change) with zero visible benefit.

## Target

```swift
// target — the modifier line is simply gone
                        DocumentViewModeContent(
                            document: document,
                            selectedHeadingId: $selectedHeadingId
                        )
```

## Repo conventions to follow

- Precedent: tab switching (`zMD/TabBar.swift:164-166`) and the command
  palette are deliberately instant for the same frequency reason. This change
  makes mode switching consistent with them.
- No replacement animation: the fix is deletion.

## Steps

1. In `zMD/NormalContentView.swift`, delete line 70
   (`.animation(Motion.fast, value: documentManager.viewMode)`).

## Boundaries

- Do NOT touch the split-view branch above (lines 32-64) or the
  `.animation` modifiers handled by plan 005 (lines 77-78) — unless plan 005
  has already removed them.
- Do NOT add a crossfade or any substitute transition — the swap is instant
  by design.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**: open a markdown file and press ⌘1 / ⌘2 / ⌘3 repeatedly:
  - The content swaps instantly on each keystroke; no flicker, no 120ms
    dead zone where neither view is interactive.
  - Spam the shortcuts in quick succession: every press registers
    immediately.
- **Done when**: the modifier is gone and mode switching is instant.
