# 011 — Use an entrance curve for the focus-exit pill hover

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: LOW
- **Category**: Easing & duration
- **Estimated scope**: 1 file, 1 line changed

## Problem

The focus-mode exit pill appears on hover with `Motion.standard` — the
easeInOut *layout morph* curve:

`zMD/ContentView.swift:130-134` — current:

```swift
            .onHover { hovering in
                withAnimation(Motion.standard) {
                    showFocusExitPill = hovering
                }
            }
```

Two issues: ease-in-out starts slow, so the pill's appearance lags the cursor
by design (hover feedback wants a fast-starting ease-out); and because
`Motion.standard` returns `nil` under Reduce Motion, the pill pops with zero
feedback for those users — even though its transition
(`Motion.slideOrFade(edge: .top)`, line 123) already degrades to a pure fade
that would be perfectly fine to animate.

## Target

```swift
// target
            .onHover { hovering in
                withAnimation(Motion.entrance) {
                    showFocusExitPill = hovering
                }
            }
```

`Motion.entrance` is `.easeOut(duration: 0.2)` — the fast-starting entrance
curve, inside the 125–200ms popover budget. It stays non-nil under Reduce
Motion, so reduced-motion users keep the fade (position change is already
dropped by `slideOrFade`).

## Repo conventions to follow

- Token swap only — `Motion.entrance` is the app's declared curve for
  "things appearing/entering" (`zMD/SettingsManager.swift:43-45`).

## Steps

1. `zMD/ContentView.swift:131`: change `withAnimation(Motion.standard)` to
   `withAnimation(Motion.entrance)`.

## Boundaries

- Do NOT touch the pill's `.transition(Motion.slideOrFade(edge: .top))` at
  line 123 — already correct.
- Do NOT change the hover hit-area, the pill's styling, or the
  `Motion.standard` usages elsewhere (layout morphs — correct there).
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**: enter focus mode (⌘⇧F) and move the cursor to the top edge:
  - The pill starts appearing the instant the cursor arrives — no slow ramp.
  - Move away and back repeatedly: it responds crisply each time.
  - Reduce Motion ON: the pill fades in (no slide) instead of popping.
- **Done when**: the pill appears with `Motion.entrance`.
