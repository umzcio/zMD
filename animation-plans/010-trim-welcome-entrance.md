# 010 — Trim the welcome entrance to the UI budget

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: LOW
- **Category**: Easing & duration
- **Estimated scope**: 1 file, 4 lines changed

## Problem

The welcome screen's choreographed entrance runs four elements at 350ms
each — over the 300ms UI animation budget — and this is not a first-run-only
screen: it shows on every launch *and* every time the user closes their last
tab. The decorative stagger delays access to the New/Open buttons.

`zMD/WelcomeView.swift:182-193` — current:

```swift
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
```

(The easing itself — ease-out for entrances — is correct, and the
reduce-motion branch at lines 167-177 is already correct. Only the durations
and delays change. The icon spring at line 178 is owned by plan 009.)

## Target

250ms durations (inside budget) with 50ms stagger steps (inside the 30–80ms
stagger band), trimming the full sequence from ~630ms to ~450ms:

```swift
// target
        withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
            showSubtitle = true
        }
        withAnimation(.easeOut(duration: 0.25).delay(0.10)) {
            showButton = true
        }
        withAnimation(.easeOut(duration: 0.25).delay(0.15)) {
            showHint = true
        }
        withAnimation(.easeOut(duration: 0.25).delay(0.20)) {
            showRecents = true
        }
```

## Repo conventions to follow

- These four values stay hand-typed by necessity (each has its own delay);
  the `Motion` token system has no stagger construct and this plan does not
  add one — the win here is budget compliance, not tokenization.
- Keep the existing `opacity`/`offset` entrance mechanism
  (`WelcomeView.swift:71-72` and siblings) untouched.

## Steps

1. `zMD/WelcomeView.swift:182`: `0.35).delay(0.10)` → `0.25).delay(0.05)`.
2. `zMD/WelcomeView.swift:185`: `0.35).delay(0.16)` → `0.25).delay(0.10)`.
3. `zMD/WelcomeView.swift:188`: `0.35).delay(0.22)` → `0.25).delay(0.15)`.
4. `zMD/WelcomeView.swift:191`: `0.35).delay(0.28)` → `0.25).delay(0.20)`.

## Boundaries

- Do NOT touch the reduce-motion branch (lines 167-177), the icon spring
  (line 178, plan 009's), or the entrance's visual design (opacity + 8pt
  offset).
- Do NOT remove the stagger entirely — this screen is allowed a delight
  budget; the finding is duration, not existence.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**: launch the app with no documents open:
  - The sequence — icon, subtitle, button, hint, recents — still cascades
    visibly, but the last element lands ~180ms sooner. The Open File button
    feels reachable almost immediately.
  - Close your last tab to re-trigger the screen: the repeat viewing doesn't
    feel like waiting through a ceremony.
  - Reduce Motion ON: single grouped fade, unchanged.
- **Done when**: no welcome entrance exceeds 250ms and the stagger reads as
  one fluid cascade.
