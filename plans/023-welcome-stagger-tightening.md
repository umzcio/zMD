# 023 — Tighten the welcome-screen stagger and spring

- **Status**: TODO
- **Commit**: `6b2ae29`
- **Severity**: LOW
- **Category**: Cohesion (personality)
- **Estimated scope**: 1 file (`zMD/ContentView.swift`), ~10 lines

## Problem

The welcome screen staggers its elements in 100ms steps, so the last
element (recent files) lands ~850ms after appear — the audit's stagger
range is 30–80ms per step, and beyond that the sequence reads as draggy
rather than orchestrated. The icon spring (`dampingFraction: 0.6`) is also
bouncier than this crisp, native productivity app's personality; welcome is
a rare surface where delight is allowed, but the delight budget should read
"polished," not "playful toy."

```swift
// zMD/ContentView.swift:558-573 — current
.onAppear {
    withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
        showIcon = true
        iconBounce = true
    }
    withAnimation(.easeOut(duration: 0.4).delay(0.15)) {
        showSubtitle = true
    }
    withAnimation(.easeOut(duration: 0.4).delay(0.25)) {
        showButton = true
    }
    withAnimation(.easeOut(duration: 0.4).delay(0.35)) {
        showHint = true
    }
    withAnimation(.easeOut(duration: 0.4).delay(0.45)) {
        showRecents = true
    }
}
```

## Target

60ms stagger steps starting after a 100ms lead-in for the icon, and a
calmer spring:

```swift
// target
.onAppear {
    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
        showIcon = true
        iconBounce = true
    }
    withAnimation(.easeOut(duration: 0.35).delay(0.10)) {
        showSubtitle = true
    }
    withAnimation(.easeOut(duration: 0.35).delay(0.16)) {
        showButton = true
    }
    withAnimation(.easeOut(duration: 0.35).delay(0.22)) {
        showHint = true
    }
    withAnimation(.easeOut(duration: 0.35).delay(0.28)) {
        showRecents = true
    }
}
```

Last element now lands ~630ms after appear instead of ~850ms; each step is
60ms; the icon settles with a slight, dignified overshoot instead of a
wobble. Reduce Motion (if Plan 020 landed): wrap the whole block so that
when `Motion.reduceMotion` is true, all five flags are set with a single
`withAnimation(.easeOut(duration: 0.2))` — one gentle group fade, no
offsets. The `offset(y:)` modifiers on the elements (e.g.
`ContentView.swift:551-552`) can stay; under the single grouped animation
they'll move only 8pt over 200ms, which is acceptable — do not restructure
the view for this.

## Repo conventions to follow

- This is the app's only staggered sequence; the pattern (state flags +
  delayed `withAnimation` in `onAppear`) stays exactly as-is — only values
  change.

## Steps

1. Apply the value changes in the Target block to
   `zMD/ContentView.swift:558-573` (locate by content if drifted).
2. If Plan 020 has landed, add the `Motion.reduceMotion` grouped-fade
   branch described above.
3. Build.

## Boundaries

- Do NOT touch the welcome view's layout, copy, or the recent-files list.
- Do NOT remove the stagger entirely — welcome is a rare surface where
  sequenced entrance is earned.
- If the block doesn't match (drift), STOP and report.

## Verification

- **Mechanical**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`.
- **Feel check**: quit and relaunch the app with no documents open (welcome
  shows):
  - The full sequence completes in well under a second; nothing feels like
    it's waiting for its turn.
  - The icon settles with at most one visible overshoot — no wobble.
  - Screen-record + step frames if unsure: recents should be fully visible
    by ~0.7s after first paint.
- **Done when**: both feel checks pass.
