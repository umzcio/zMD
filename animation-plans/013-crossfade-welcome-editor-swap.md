# 013 — Crossfade the welcome ⇄ editor window swap

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: MEDIUM
- **Category**: Missed opportunity
- **Estimated scope**: 1 file, ~4 lines changed

## Problem

The whole window content hard-cuts between the editor stack and the welcome
screen:

`zMD/ContentView.swift:17` and `:83-85` — current:

```swift
                if !documentManager.openDocuments.isEmpty {
                    // ... entire editor stack ...
                } else {
                    WelcomeView()
                }
```

Opening the first document (every launch) or closing the last tab swaps the
entire viewport instantly — and it's a double jolt: the welcome screen's
choreographed entrance plays, then hard-cuts away on first open. This is an
occasional, full-viewport state change — exactly the case where a brief
crossfade prevents a jarring change. Both branches fill the window
(`maxWidth/maxHeight: .infinity`), so a crossfade costs no layout
interpolation.

## Target

```swift
// zMD/ContentView.swift:17 — target (first branch gains a transition)
                if !documentManager.openDocuments.isEmpty {
                    // ... entire editor stack unchanged ...
                } else {
                    WelcomeView()
                        .transition(.opacity)
                }
```

plus one scoped animation modifier on the root VStack, replacing nothing
(plan 004 removes the two that are there as of the commit stamp):

```swift
// target — on the root VStack, where plan 004 leaves only .frame(...)
            .animation(Motion.standard, value: documentManager.openDocuments.isEmpty)
            .frame(minWidth: 600, minHeight: 400)
```

The editor branch also needs the transition so its removal animates; add
`.transition(.opacity)` to the view at the top of the `if` branch as well
(the first child inside the branch — the chrome `VStack` if plan 004 has run,
otherwise the tab-bar conditional's container: apply it to the branch's root
content view so both directions of the swap fade).

Why plain `.opacity`: the two branches are different-sized trees; any
positional transition would interpolate layout across the whole window. A
200ms easeInOut fade (`Motion.standard`) is the cheap, correct tool here.
`Motion.standard` is nil under Reduce Motion — instant swap, correct.

## Repo conventions to follow

- `Motion.slideOrFade`/`scaleOrFade` degrade movement under Reduce Motion;
  here there is no movement to degrade, so plain `.opacity` + the
  reduce-motion-aware `Motion.standard` driver is sufficient.
- Keep the modifier scoped to this one value — do not re-introduce any other
  `.animation` on the root VStack (plan 004 just removed two).

## Steps

1. Execute plan 004 first if it hasn't run (it restructures this VStack and
   removes the root `.animation` lines this plan sits next to).
2. Add `.transition(.opacity)` to the `WelcomeView()` call at
   `zMD/ContentView.swift:84`.
3. Add `.transition(.opacity)` to the root content view of the `if` branch.
4. Add `.animation(Motion.standard, value: documentManager.openDocuments.isEmpty)`
   to the root VStack, directly above `.frame(minWidth: 600, minHeight: 400)`.

## Boundaries

- Only `zMD/ContentView.swift` changes. Do NOT wrap
  `DocumentManager.openFile()`/`closeDocument()` in `withAnimation` — tab
  add/remove has its own motion (`TabBar.swift:17,20`) and must not start
  crossfading the window on every tab close; the `.animation(value:)` on
  `isEmpty` fires only on the empty ⇄ non-empty boundary.
- Do NOT add movement (slide/scale) to either branch.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**:
  - Launch with no recent session, then open a file: the welcome screen
    crossfades into the editor over ~200ms instead of hard-cutting.
  - Close the last tab: the editor crossfades back to welcome.
  - Open and close *middle* tabs: no window-level fade — only the
    empty ⇄ non-empty boundary animates.
  - Reduce Motion ON: instant swap.
- **Done when**: the welcome ⇄ editor swap crossfades and ordinary tab
  operations don't trigger it.
