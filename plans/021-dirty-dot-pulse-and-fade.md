# 021 — Fix the dirty-dot pulse easing and add a fade-out on save

- **Status**: TODO
- **Commit**: `6b2ae29`
- **Severity**: MEDIUM (pulse easing) + missed-opportunity (fade-out) — same component, merged
- **Category**: Easing & duration + Missed opportunities
- **Estimated scope**: 1 file (`zMD/TabBar.swift`), ~15 lines

## Problem

The tab's dirty-indicator dot has two motion issues:

1. **`.easeIn` on UI** — the pulse settle uses `.easeIn(duration: 0.2)`.
   Ease-in starts slow and accelerates, which delays visible change at
   exactly the moment the eye is drawn to it; the audit rule is that
   ease-in on UI is always wrong. The pulse is also hand-sequenced with a
   `DispatchQueue.asyncAfter`, which means the settle fires on a wall-clock
   timer regardless of whether the expand actually completed — a spring
   models "overshoot then settle" in one interruptible unit instead.

2. **The dot vanishes instantly on save.** `if document.isDirty` removes the
   `Circle()` from the hierarchy with no transition, so the save moment — a
   small but meaningful completion event — reads as a teleport. A brief
   fade/scale-down closes the loop. (Keep it subtle: saving already shows a
   toast; the dot's exit is a whisper, not a second announcement.)

```swift
// zMD/TabBar.swift:92-108 — current
if document.isDirty {
    Circle()
        .fill(Color.accentColor)
        .frame(width: 6, height: 6)
        .scaleEffect(dirtyPulse ? 1.5 : 1.0)
        .opacity(dirtyPulse ? 0.6 : 1.0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                dirtyPulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeIn(duration: 0.2)) {
                    dirtyPulse = false
                }
            }
        }
}
```

## Target

One spring drives the whole pulse (appear slightly large, settle to rest —
overshoot is the spring's job, not a two-phase hand sequence), and the dot
exits with a scale+fade transition:

```swift
// target
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

Semantics flip deliberately: `dirtyPulse == true` now means "settled at
rest" so the spring animates from the attention-grabbing state (1.4×, 60%
opacity) down to rest (1.0×, 100%) in a single interruptible motion — the
spring's `dampingFraction: 0.65` gives a slight, appropriate wobble on
arrival. No `asyncAfter`. The `.transition` gives the exit fade+shrink; it
inherits the tab bar's existing surrounding animation
(`TabBar.swift:23`'s `.animation(..., value: openDocuments.map(\.id))`
doesn't cover `isDirty` changes, so wrap the dirty-flag change site OR add
`.animation(Motion.fast, value: document.isDirty)` on the HStack — use
whichever the code structure makes cleaner; the requirement is only that
the exit transition actually animates, ~120-200ms).

If Plan 020 has landed, use `Motion.fast` for the exit animation token; if
not, `.easeOut(duration: 0.15)`.

## Repo conventions to follow

- State-driven `withAnimation` in `onAppear` is the established pattern for
  one-shot entrance effects (exemplar: the welcome screen's
  `ContentView.swift:558+`). Springs are already used in the codebase
  (`ToastManager.swift:46`, `ContentView.swift:558`) — this adds no new idiom.

## Steps

1. In `zMD/TabBar.swift`, replace the dirty-dot block (currently lines
   92-108) with the Target code, resolving the exit-animation wiring per the
   note above.
2. Build, then feel-check (below). If the exit transition doesn't fire
   (a common SwiftUI gotcha when the parent isn't animating the removal),
   add `.animation(.easeOut(duration: 0.15), value: document.isDirty)` on
   the dot's parent `HStack` and re-check.

## Boundaries

- Do NOT touch anything else in `TabItem` (hover, close button, drag) —
  Plans 020/022/024 own adjacent code; keep this diff to the dirty-dot
  block only.
- Do NOT make the exit springy or long — exit is a quick fade+shrink
  (≤200ms), the entrance owns the personality.
- If the current code doesn't match the excerpt (drift), STOP and report.

## Verification

- **Mechanical**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`; full
  test suite passes.
- **Feel check**: open a file, type a character (dot appears), ⌘S (dot
  disappears):
  - Appearance: dot lands with one smooth spring settle — no visible
    two-phase "grow… pause… shrink" sequencing.
  - Disappearance on ⌘S: dot shrinks+fades over a fraction of a second —
    no instant pop.
  - Type → ⌘S → type → ⌘S rapidly: no stuck oversized dot, no orphaned
    animation state (the `.onDisappear` reset guards this — confirm).
- **Done when**: all three feel checks pass and `grep -n "asyncAfter" zMD/TabBar.swift` returns no hits.
