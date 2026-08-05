# 009 — Consolidate hand-typed springs into a Motion token

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: MEDIUM
- **Category**: Cohesion & tokens
- **Estimated scope**: 3 files, ~10 lines changed

## Problem

The codebase built the `Motion` enum explicitly as "the single edit point"
for animation (`zMD/SettingsManager.swift:32-34`), yet three hand-typed
near-duplicate springs and one exact duplicate of a token live outside it:

- `zMD/ToastManager.swift:46` — `.spring(response: 0.4, dampingFraction: 0.75)`
  (toast stack insertion; 400ms response also exceeds the 300ms UI budget).
- `zMD/WelcomeView.swift:178` — `.spring(response: 0.45, dampingFraction: 0.78)`
  (welcome icon entrance).
- `zMD/WelcomeView.swift:168` — `.easeOut(duration: 0.2)`, an exact hand-typed
  duplicate of `Motion.entrance`.

(A third spring, `TabBar.swift:118`, is removed by plan 008 — do not touch it
here.)

None of these honor Reduce Motion: the toast insertion spring animates the
existing toasts' reflow even when the setting is on.

## Target

One spring token, subtle by default (damping 0.8 = bounce in the 0.1–0.3
band), reduce-motion-aware, response inside the 300ms UI budget:

In `zMD/SettingsManager.swift`, after the `morph` property (line 57):

```swift
    /// Subtle spring for stack reflows and rare entrances (toasts, welcome
    /// icon). Bounce is intentionally quiet; nil under Reduce Motion.
    static var springy: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)
    }
```

Swaps (`withAnimation` accepts `Animation?`; `nil` = instant):

```swift
// zMD/ToastManager.swift:46 — target
            withAnimation(Motion.springy) {
```

```swift
// zMD/WelcomeView.swift:178 — target
        withAnimation(Motion.springy) {
```

```swift
// zMD/WelcomeView.swift:168 — target
            withAnimation(Motion.entrance) {
```

(The `WelcomeView.swift:168` line is inside the reduce-motion branch of
`animateEntrance()` — a grouped fade. Routing it through the token removes
the hand-typed duplicate; behavior is identical since `Motion.entrance` is
also `.easeOut(duration: 0.2)`.)

## Repo conventions to follow

- New tokens go in the `Motion` enum with a doc comment stating the use
  case, matching the style of `fast`/`entrance`/`standard`/`morph`
  (`zMD/SettingsManager.swift:41-57`).
- Reduce-motion handling lives inside the token (returns `nil`), matching
  `standard`/`morph` — never gated at call sites.

## Steps

1. `zMD/SettingsManager.swift`: insert the `springy` property (verbatim from
   Target) after line 57.
2. `zMD/ToastManager.swift:46`: replace the hardcoded spring with
   `Motion.springy`.
3. `zMD/WelcomeView.swift:178`: replace the hardcoded spring with
   `Motion.springy`.
4. `zMD/WelcomeView.swift:168`: replace `.easeOut(duration: 0.2)` with
   `Motion.entrance`.

## Boundaries

- Do NOT touch `zMD/TabBar.swift:118` — plan 008 owns it.
- Do NOT change toast layout, timing of the auto-dismiss (3s), or the toast
  view's `.transition` (`ToastManager.swift:96-103`) — the entrance
  transition itself is already correct and reduce-motion-aware.
- Do NOT change the welcome entrance's stagger delays — plan 010 owns those.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds. `grep -rn "spring(" zMD/` shows only the one definition inside `Motion.springy`.
- **Feel check**:
  - Trigger two or three toasts in quick succession: the stack reflows with
    a gentle, single settle — no sluggish 400ms arrival, no bounce.
  - Launch the app with no documents: the welcome icon springs in subtly
    (slightly quicker and calmer than before).
  - Reduce Motion ON: toasts and the welcome icon fade in place with no
    spring motion.
- **Done when**: all springs route through `Motion.springy` and the app has
  exactly one spring definition.
