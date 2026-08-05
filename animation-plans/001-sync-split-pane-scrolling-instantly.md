# 001 — Sync split-pane scrolling instantly

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: HIGH
- **Category**: Interruptibility / Performance
- **Estimated scope**: 2 files, ~15 lines changed

## Problem

Split-mode scroll sync animates the follow-pane with a fresh 150ms
`easeInEaseOut` tween on **every debounced scroll event** (~20×/second during
continuous scrolling). Each new event restarts the full duration from a
standstill (AppKit animation groups do not retarget mid-flight the way springs
do), so the follow-pane perpetually trails the user's gesture by ~150ms and
settles in visible steps. Scrolling is the highest-frequency gesture in the
app and split view is a headline feature — this lag is felt constantly.

`zMD/MarkdownTextView.swift:651-661` — current:

```swift
            isProgrammaticScroll = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isProgrammaticScroll = false
                }
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
```

`zMD/SourceEditorView.swift:396-406` — current (identical pattern):

```swift
            isProgrammaticScroll = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isProgrammaticScroll = false
                }
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
```

## Target

Sync is a mirror of the user's own gesture — it must track 1:1, not chase.
Set the bounds origin directly, with no animation context. The
`isProgrammaticScroll` flag (which stops the bounds-change observer from
re-broadcasting this motion as a user scroll) is set and cleared
synchronously around the mutation; the async completion handler goes away.

```swift
// both files — target
            isProgrammaticScroll = true
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
```

## Repo conventions to follow

- The `isProgrammaticScroll` guard pattern is load-bearing: the comment at
  `zMD/MarkdownTextView.swift:368-369` explains it prevents rebound loops in
  split mode. Keep it — just apply it synchronously.
- Do not touch `scrollToHeading` (`zMD/MarkdownTextView.swift:372-380`): a
  discrete jump to a heading is occasional and *should* stay animated. Its
  Reduce-Motion gap is handled by plan 003, not this one.

## Steps

1. In `zMD/MarkdownTextView.swift`, inside `func scrollToPercent(_ percent: CGFloat)`
   (starts at line 642), replace the `NSAnimationContext.runAnimationGroup`
   block (lines 651-661, quoted above) with the 4-line target above.
2. In `zMD/SourceEditorView.swift`, inside
   `func scrollToPercent(_ percent: CGFloat, in scrollView: NSScrollView)`
   (starts at line 388), replace the identical block (lines 396-406) with the
   same 4-line target.
3. Verify no other references to the removed completion-handler structure
   remain in either function (the `[weak self]` closure is deleted entirely).

## Boundaries

- Do NOT touch `scrollToHeading` in `MarkdownTextView.swift` (the 0.3s
  animated jump at lines 372-380).
- Do NOT touch the debounce timers (`syncDebounceTimer`, 50ms) or the
  `onScrollPercentChanged` broadcast path — sync cadence is unchanged, only
  the follow-pane's motion.
- Do NOT change any SwiftUI code; both edits are inside AppKit coordinators.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds with no new warnings.
- **Feel check**: open two documents, right-click one → open in split view,
  then scroll the left pane continuously with a trackpad:
  - The right pane tracks your fingers in lockstep — no trailing, no
    rubbery catch-up, no stepped settling after you stop.
  - Scroll fast to the bottom and stop abruptly: the follow-pane is already
    there, not arriving ~150ms late.
  - Scroll the right pane instead: same lockstep in reverse (no rebound loop
    — the `isProgrammaticScroll` guard still works).
- **Done when**: no `NSAnimationContext` remains in either `scrollToPercent`
  function and split scrolling tracks 1:1.
