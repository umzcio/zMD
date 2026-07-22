# 019 — Make Quick Open appear instantly, matching the command palette

- **Status**: TODO
- **Commit**: `6b2ae29`
- **Severity**: HIGH
- **Category**: Purpose & frequency
- **Estimated scope**: 1 file, ~3 lines removed

## Problem

Quick Open (⌘⇧O) is a keyboard-summoned palette in the highest-frequency
interaction class (100+ uses/day for a power user). It currently animates in
and out with a 200ms move+fade. The audit rule for keyboard-initiated
palettes is: **no animation, ever** — the user's eyes are already at the
target location and the animation only delays the muscle-memory loop
(Raycast, the reference product for this pattern, has zero open/close
animation).

Worse, the app's *other* palette — the command palette (⌘K) — already gets
this right: `ContentView.swift:142` shows `CommandPaletteOverlay` in a plain
`if` with no `.transition` or `.animation`, so it appears instantly. The two
palettes disagree, and the wrong one is animated.

```swift
// zMD/QuickOpenView.swift:531-546 — current
VStack {
    QuickOpenView(isPresented: $isPresented, selectedHeadingId: $selectedHeadingId)
        .environmentObject(documentManager)
        .environmentObject(folderManager)
        .frame(width: 500, height: 350)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    Spacer()
}
.padding(.top, 80)
.transition(.opacity.combined(with: .move(edge: .top)))
```
```swift
// zMD/QuickOpenView.swift:545 — current (on the enclosing container)
.animation(.easeOut(duration: 0.2), value: isPresented)
```

## Target

Quick Open appears and disappears instantly — identical presentation
behavior to the command palette. Delete both motion modifiers; add nothing
in their place.

```swift
// target: same VStack, no .transition line
VStack {
    QuickOpenView(...)
        ...
    Spacer()
}
.padding(.top, 80)
// (the .animation(_:value: isPresented) modifier on the enclosing view is
// also deleted — no replacement)
```

## Repo conventions to follow

- The exemplar is the command palette itself: `zMD/ContentView.swift:142-144`
  — `if showCommandPalette { CommandPaletteOverlay(...) }` with no
  transition/animation modifiers. Quick Open should read the same way.

## Steps

1. In `zMD/QuickOpenView.swift`, delete the
   `.transition(.opacity.combined(with: .move(edge: .top)))` line (currently
   line 542) from the palette's `VStack`.
2. In the same file, delete the `.animation(.easeOut(duration: 0.2), value:
   isPresented)` modifier (currently line 545) from the enclosing view.
3. Build.

## Boundaries

- Do NOT touch the dimmed-background layer, the palette's layout, sizing,
  shadow, or corner radius — motion modifiers only.
- Do NOT touch `CommandPaletteView.swift` (already correct).
- Do NOT touch the internal result-list scroll animation
  (`QuickOpenView`'s table behavior) — this plan is only about the
  open/close presentation.
- If the two cited lines are not where the excerpt shows them (drift since
  `6b2ae29`), STOP and report.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` → `** BUILD SUCCEEDED **`.
- **Feel check**: run the app, press ⌘⇧O repeatedly and rapidly:
  - The palette appears and disappears with zero perceptible motion or fade
    — exactly like ⌘K.
  - Spamming ⌘⇧O open/close never shows a half-faded or mid-slide frame.
- **Done when**: ⌘⇧O and ⌘K are visually indistinguishable in how they
  present, and the two deleted modifiers no longer appear in
  `QuickOpenView.swift` (`grep -n "transition\|animation" zMD/QuickOpenView.swift`
  shows no presentation-level hits).
