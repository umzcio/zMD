# 022 — Normalize entrance scales to the physical range (tabs, toasts)

- **Status**: TODO
- **Commit**: `6b2ae29`
- **Severity**: LOW
- **Category**: Physicality & origin
- **Estimated scope**: 2 files, ~4 lines

## Problem

Two entrance animations scale from `0.8` — deeper than the physical
0.9–0.97 range the audit prescribes (elements shouldn't appear to grow from
far away; a shallow scale + fade reads as "arriving," a deep one reads as
"zooming in"). Tab insertion additionally animates under the container's
`.easeInOut`, but entrances want ease-out (fast start, settled end).

```swift
// zMD/TabBar.swift:17-20 — current
.transition(.asymmetric(
    insertion: .opacity.combined(with: .scale(scale: 0.8)),
    removal: .opacity.combined(with: .scale(scale: 0.8))
))
```

```swift
// zMD/ToastManager.swift:94-97 — current
.transition(.asymmetric(
    insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.8)).combined(with: .opacity),
    removal: .opacity
))
```

## Target

```swift
// zMD/TabBar.swift — target
.transition(.asymmetric(
    insertion: .opacity.combined(with: .scale(scale: 0.95)),
    removal: .opacity.combined(with: .scale(scale: 0.95))
))
```

```swift
// zMD/ToastManager.swift — target (only the scale value changes)
.transition(.asymmetric(
    insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.95)).combined(with: .opacity),
    removal: .opacity
))
```

Coordination note: if Plan 020 has landed, `TabBar.swift`'s transition may
already read `Motion.scaleOrFade()` — in that case this plan's TabBar work
is already done (the helper's default is 0.95) and only the ToastManager
scale value needs changing (inside whatever reduce-motion-aware wrapper 020
created there). If 020 has NOT landed, apply the literal edits above.

The tab container's `.easeInOut(duration: 0.2)` at `TabBar.swift:23` drives
both insertion and removal; SwiftUI can't easily split easing per direction
on a container-level `.animation(value:)`, and re-architecting that isn't
worth it for a tab bar — the scale normalization is the meaningful change
here. Leave the container animation as-is (or `Motion.standard` post-020).

## Repo conventions to follow

- These are the only two `.scale(scale:)` transition sites in the app
  (verify with `grep -rn "scale(scale:" zMD/*.swift`) — after this plan,
  every scale entrance in the codebase sits at 0.95.

## Steps

1. Change `0.8` → `0.95` in both `TabBar.swift` transition lines (or
   confirm 020's helper already covers TabBar; see coordination note).
2. Change `0.8` → `0.95` in `ToastManager.swift`'s insertion transition.
3. Build.

## Boundaries

- Do NOT touch the toast's spring (`ToastManager.swift:46`) or its
  removal transition — the in/out asymmetry is correct as designed.
- Do NOT touch the dirty-dot block in TabBar (Plan 021 owns it).
- If the lines don't match (drift), STOP and report.

## Verification

- **Mechanical**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`.
- **Feel check**:
  - Open a new tab (⌘N) and close one (⌘W): tabs should subtly "arrive"
    rather than visibly zoom up from small. If you can screen-record and
    step frame-by-frame, the first visible frame of a new tab should
    already be near full size.
  - Save a file to trigger a toast: same check — the toast slides in from
    the right with only a whisper of scale.
- **Done when**: `grep -rn "scale(scale: 0.8" zMD/*.swift` returns no hits
  and both feel checks pass.
