# 024 — Add press feedback to primary buttons

- **Status**: TODO
- **Commit**: `6b2ae29`
- **Severity**: Missed opportunity (additive)
- **Category**: Physicality & origin (press feedback)
- **Estimated scope**: 2 files (~1 new ButtonStyle + a handful of adoption sites)

## Problem

No pressable element in the app gives press-state feedback. The welcome
screen's "Open File" button has a hover scale (`ContentView.swift:454`
`.scaleEffect(buttonHovered ? 1.03 : 1.0)`) but nothing on actual press;
"New File", tab close, and toolbar buttons are all `PlainButtonStyle()`
with zero press response. The standard: `scale(0.97)` while pressed,
~150ms ease-out — subtle confirmation that the click landed, felt more
than seen.

Scope discipline: apply this to the **welcome screen's two primary buttons
only** in this plan. Tab-close/toolbar/icon buttons are tiny targets where
a scale can read as jitter; extending to them is a follow-up judgment call
after feeling this on the big buttons, not a bulk find-and-replace.

## Target

One reusable `ButtonStyle` and adoption on the two welcome buttons:

```swift
// target — new ButtonStyle, placed in zMD/ContentView.swift near
// RecentFileButtonStyle (ContentView.swift:578), matching its conventions
/// Standard press feedback: subtle scale-down while pressed. Feel target:
/// felt more than seen — confirmation, not animation.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
```

Adoption: on the welcome screen's "New File" and "Open File" buttons
(currently `.buttonStyle(PlainButtonStyle())` at `ContentView.swift:~437`
and `~445` area), replace with `.buttonStyle(PressableButtonStyle())`.
Note `ButtonStyle.makeBody` replaces the default styling the same way
`PlainButtonStyle` does (no bezel), so no visual regression is expected —
verify in the feel check. The "Open File" button's existing hover
scale-up (1.03) stays; hover-up + press-down compose correctly since the
press scale multiplies inside the style.

If Plan 020 has landed, use `Motion.fast` in place of the literal
`.easeOut(duration: 0.15)`.

## Repo conventions to follow

- Exemplar for a custom ButtonStyle in this codebase:
  `RecentFileButtonStyle` at `zMD/ContentView.swift:578-594` — same file
  placement, same doc-comment style.

## Steps

1. Add `PressableButtonStyle` to `zMD/ContentView.swift` adjacent to
   `RecentFileButtonStyle`.
2. Swap `.buttonStyle(PlainButtonStyle())` → `.buttonStyle(PressableButtonStyle())`
   on the two welcome primary buttons (locate them by their labels "New
   File" / "Open File", not by line number).
3. Build.

## Boundaries

- Do NOT apply the style to tab close buttons, toolbar icons, sidebar rows,
  or the recent-files list — welcome primaries only, per the scope note.
- Do NOT exceed 0.95–0.98 scale or 200ms — press feedback must stay subtle.
- If the buttons aren't where described (drift), STOP and report.

## Verification

- **Mechanical**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`.
- **Feel check**: welcome screen, click-and-hold each primary button:
  - Button visibly (but subtly) compresses while held; releases crisply.
  - Click normally at speed: the feedback registers without drawing the eye.
  - "Open File": hover in, press, release, hover out — no scale snapping
    or fighting between the hover 1.03 and press 0.97.
  - Confirm no visual regression vs. PlainButtonStyle (no unexpected bezel
    or tint on the labels).
- **Done when**: all feel checks pass on both buttons.
