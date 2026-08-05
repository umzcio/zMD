# 002 — Remove command palette scroll animation

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: HIGH
- **Category**: Purpose & frequency
- **Estimated scope**: 1 file, 2 lines changed

## Problem

The command palette animates its scroll position on **every arrow-key
press**. Holding ↓ (key repeat) streams a sequence of 120ms `easeOut` tweens
that constantly restart mid-flight, so the list visibly trails the selection
highlight. Keyboard navigation in a command palette is a 100+-times/day
action — the rule for that frequency class is *no animation, ever* (Raycast
and Spotlight scroll instantly). The app's own palette already gets this
right for open/close (instant, no transition); the scroll is the one leak.

`zMD/CommandPaletteView.swift:278-282` — current:

```swift
                    .onChange(of: selectedIndex) { _ in
                        withAnimation(Motion.fast) {
                            proxy.scrollTo(selectedIndex, anchor: .center)
                        }
                    }
```

## Target

```swift
// target
                    .onChange(of: selectedIndex) { _ in
                        proxy.scrollTo(selectedIndex, anchor: .center)
                    }
```

## Repo conventions to follow

- The palette's presentation is deliberately instant — see
  `zMD/ContentView.swift:142-148`, where `CommandPaletteView` is a bare
  conditional overlay with no `.transition`. This plan extends the same
  decision to its internal scrolling.
- No replacement animation token: the fix is deletion, not substitution.

## Steps

1. In `zMD/CommandPaletteView.swift`, lines 278-282, delete the
   `withAnimation(Motion.fast) { ... }` wrapper so `proxy.scrollTo` is called
   directly, exactly as the target above.

## Boundaries

- Do NOT add a transition or animation anywhere else in the palette — the
  row highlight (`CommandRow(isSelected:)`) is already unanimated and stays
  that way.
- Do NOT touch `QuickOpenView.swift` — it has no animated scroll and is
  already correct.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**: open the command palette (⌘⇧P), then:
  - Hold ↓ for several seconds: the selection and the list position move in
    perfect lockstep; the list never lags or glides after you release the key.
  - Tap ↑/↓ repeatedly as fast as possible: every keypress lands instantly,
    with zero motion blur between positions.
  - Jump from the first to the last command with many items visible: the
    list snaps to center the selection immediately.
- **Done when**: `withAnimation` no longer appears in
  `CommandPaletteView.swift` and keyboard navigation is instant.
