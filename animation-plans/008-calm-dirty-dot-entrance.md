# 008 — Calm the dirty-dot entrance and pulse

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: MEDIUM
- **Category**: Physicality & origin / Cohesion & tokens
- **Estimated scope**: 1 file (`zMD/TabBar.swift`), 4 lines changed
- **Depends on**: plan 003 (provides `Motion.fastMovement`)

## Problem

The unsaved-changes dot is the loudest mover in a quiet app:

`zMD/TabBar.swift:111-123,146` — current:

```swift
            if document.isDirty {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .scaleEffect(dirtyPulse ? 1.0 : 1.4)
                    .opacity(dirtyPulse ? 1.0 : 0.6)
                    .onAppear {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                            dirtyPulse = true
                        }
                    }
                    .onDisappear { dirtyPulse = false }
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
```

```swift
        .animation(Motion.fast, value: document.isDirty)
```

Three violations in one 6pt element:

1. It enters from `scale(0.5)` — far below the 0.9–0.97 physicality floor.
   The token `Motion.scaleOrFade()` (scale 0.95, degrades to `.opacity`
   under Reduce Motion) exists and is already used elsewhere in this same
   file (line 17).
2. The pulse uses `dampingFraction: 0.65` — visible overshoot bounce. This is
   the only bouncy element in an otherwise crisp tool, and it fires on a
   high-frequency state (first keystroke dirtying any document).
3. Both the 140%→100% pulse and the `.animation(Motion.fast, ...)` driver
   ignore Reduce Motion.

## Target

```swift
// zMD/TabBar.swift:111-123 — target
            if document.isDirty {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .scaleEffect(dirtyPulse ? 1.0 : 1.4)
                    .opacity(dirtyPulse ? 1.0 : 0.6)
                    .onAppear {
                        withAnimation(Motion.fastMovement) {
                            dirtyPulse = true
                        }
                    }
                    .onDisappear { dirtyPulse = false }
                    .transition(Motion.scaleOrFade())
            }
```

```swift
// zMD/TabBar.swift:146 — target
        .animation(Motion.fastMovement, value: document.isDirty)
```

The spring becomes a plain 120ms ease-out settle (`Motion.fastMovement` is
`Motion.fast` with Reduce-Motion gating — added by plan 003). The entrance
uses the existing 0.95-scale token.

## Repo conventions to follow

- `Motion.scaleOrFade()` — used one screen away at `zMD/TabBar.swift:17` for
  tab insertion; same token, same default scale.
- `Motion.fastMovement` is added by plan 003 in
  `zMD/SettingsManager.swift`. If plan 003 has not been executed yet, STOP —
  execute it first.

## Steps

1. Execute plan 003 first (dependency: `Motion.fastMovement` must exist).
2. `zMD/TabBar.swift:118`: replace
   `withAnimation(.spring(response: 0.4, dampingFraction: 0.65))` with
   `withAnimation(Motion.fastMovement)`.
3. `zMD/TabBar.swift:123`: replace
   `.transition(.scale(scale: 0.5).combined(with: .opacity))` with
   `.transition(Motion.scaleOrFade())`.
4. `zMD/TabBar.swift:146`: replace `.animation(Motion.fast, ...)` with
   `.animation(Motion.fastMovement, ...)`.

## Boundaries

- Do NOT change the pulse's scale range (1.4 → 1.0) or opacity range — only
  the curve. The pulse itself is deliberate feedback.
- Do NOT touch the tab insertion transition at line 17.
- Do NOT remove the dot or change its color/size.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds. `grep -n "scale(scale: 0.5)" zMD/*.swift` returns nothing.
- **Feel check**: open a document and type one character:
  - The dot fades/scales in from 95% — a subtle materialization, not a pop
    from half size.
  - The settle from 140% to 100% is a quick, single 120ms ease-out — no
    bounce, no overshoot.
  - Save (⌘S): the dot fades out.
  - Reduce Motion ON: the dot simply appears/disappears and changes opacity
    — no scale motion at all.
- **Done when**: the dot's entrance uses `Motion.scaleOrFade()` and no spring
  remains in `TabBar.swift`.
