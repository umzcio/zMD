# 020 — Add Motion tokens and system Reduce Motion support

- **Status**: TODO
- **Commit**: `6b2ae29`
- **Severity**: MEDIUM
- **Category**: Cohesion & tokens + Accessibility (merged: same refactor)
- **Estimated scope**: ~9 files (1 new enum + ~30 call-site migrations)

## Problem

Two findings, one fix:

1. **No motion tokens.** Every animation curve and duration in the app is
   hand-typed at the call site — `.easeInOut(duration: 0.1)`, `(0.15)`,
   `(0.2)`, `(0.3)`, `.easeOut(duration: 0.2)`, etc. — across
   `ContentView.swift`, `TabBar.swift`, `FolderSidebarView.swift`,
   `OutlineView.swift`, `QuickOpenView.swift`, `CommandPaletteView.swift`,
   `ToastManager.swift` (~30 sites). The repo already centralizes timing
   constants (`enum Timing` in `zMD/SettingsManager.swift:11` holds debounce
   values with documented rationale) but animation curves never got the same
   treatment, so near-identical values drift independently.

2. **System Reduce Motion is ignored everywhere.** `grep -rn
   "accessibilityReduceMotion\|accessibilityDisplayShouldReduceMotion" zMD/`
   returns zero hits. SwiftUI does NOT automatically suppress `withAnimation`
   / `.transition` movement when macOS's Reduce Motion accessibility setting
   is on. Users who set it still get: welcome-screen offset slides and spring
   bounce, sidebar `.move(edge:)` slides, toast slide-ins, find-bar slides,
   and the focus-mode layout morph. Reduced motion means fewer and gentler
   animations, **not zero** — keep opacity/color feedback, drop movement.

## Target

A `Motion` enum next to `Timing` in `SettingsManager.swift`, providing (a)
named animation tokens, (b) a reduce-motion check, and (c) reduce-motion-
aware transition helpers. Call sites migrate to tokens; movement-bearing
transitions route through the helpers.

```swift
// target — zMD/SettingsManager.swift, directly below the existing `enum Timing`
/// Animation tokens. Every animation in the app should use one of these
/// rather than a hand-typed curve/duration, so motion stays cohesive and the
/// system Reduce Motion setting is honored in one place.
enum Motion {
    /// True when macOS's "Reduce motion" accessibility setting is on.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Hover states, tiny state flips. 100–150ms class.
    static var fast: Animation { .easeOut(duration: 0.12) }
    /// Things appearing/entering (entrances want ease-out: fast start,
    /// settled end).
    static var entrance: Animation { .easeOut(duration: 0.2) }
    /// On-screen movement/morphs (sidebars toggling, view-mode switches).
    static var standard: Animation { .easeInOut(duration: 0.2) }
    /// Large layout morphs (focus mode). Upper bound of the UI budget.
    static var morph: Animation { .easeInOut(duration: 0.3) }

    /// A movement transition that degrades to a plain fade under Reduce
    /// Motion — keeps the state-change feedback, drops the position change.
    static func slideOrFade(edge: Edge) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: edge))
    }

    /// A scale entrance that degrades to a plain fade under Reduce Motion.
    static func scaleOrFade(_ scale: CGFloat = 0.95) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: scale))
    }
}
```

Call sites then read, e.g.:

```swift
// before
withAnimation(.easeInOut(duration: 0.2)) { showOutline.toggle() }
.transition(.opacity.combined(with: .move(edge: .top)))

// after
withAnimation(Motion.standard) { showOutline.toggle() }
.transition(Motion.slideOrFade(edge: .top))
```

Token mapping for the migration (do not re-time anything — map each
hand-typed value to the nearest token; the token values were chosen to make
this mapping loss-free for feel):

| Current hand-typed value | Token |
| --- | --- |
| `.easeInOut(duration: 0.1)` / `(0.15)` on hover/selection state | `Motion.fast` |
| `.easeOut(duration: 0.2)` / `.easeOut(duration: 0.25)` on entrances/dismissals | `Motion.entrance` |
| `.easeInOut(duration: 0.2)` on layout toggles (sidebars, tabs, view mode) | `Motion.standard` |
| `.easeInOut(duration: 0.3)` (focus mode only) | `Motion.morph` |
| `.spring(...)` sites (welcome icon, toast entrance) | leave as-is (Plans 022/023 own those) |
| `NSAnimationContext` scroll animations (`MarkdownTextView.swift:359,622`, `SourceEditorView.swift:362`) | leave as-is (AppKit path, correct already) |

Movement-bearing `.transition(...)` sites to route through the helpers:

- `ContentView.swift:62` (find bar), `:122` (focus exit pill), `:218` /
  `:233` (sidebars — use `slideOrFade(edge: .leading)` / `(.trailing)`)
- `FolderSidebarView.swift:152`
- `TabBar.swift:17-20` (tab insert/remove — `scaleOrFade()`; exact scale
  value is Plan 022's concern, use the helper's default)
- `ToastManager.swift:94-97` (insertion combines move+scale+opacity: under
  reduce-motion collapse the whole insertion to `.opacity`; keep the
  removal `.opacity` as-is)
- `QuickOpenView.swift` — skip; Plan 019 deletes its transition entirely.

## Repo conventions to follow

- Exemplar for a documented constants enum: `zMD/SettingsManager.swift:11`
  (`enum Timing`) — one-line doc comments per constant explaining the why.
  Place `Motion` immediately after it in the same file.
- `NSWorkspace` is already used elsewhere in the app (e.g.
  `NSWorkspace.shared.icon(forFile:)` in QuickOpen), so no new import
  patterns are needed; `SettingsManager.swift` already imports SwiftUI.

## Steps

1. Add the `Motion` enum to `zMD/SettingsManager.swift` directly below
   `enum Timing`, exactly as in Target.
2. Migrate `ContentView.swift`'s ~14 animation/transition sites per the
   mapping table (lines 62, 86, 87, 95, 122, 130, 177, 218, 233, 290, 297,
   298, 459, 501, 589 as of the stamped commit — re-locate by content, not
   line number, if drifted). The welcome-screen `onAppear` block
   (`:558-571`) is out of scope here — Plan 023 owns it.
3. Migrate `TabBar.swift` (lines 17-23, 44, 64, 118, 143; skip the dirty-dot
   pulse at 100-104 — Plan 021 owns it).
4. Migrate `FolderSidebarView.swift` (lines 23, 38, 92, 136, 152),
   `OutlineView.swift:98`, `CommandPaletteView.swift:263`.
5. Migrate `ToastManager.swift`: the `withAnimation(.easeOut(duration:
   0.25))` dismissal at line 68 → `Motion.entrance`; the insertion spring at
   line 46 stays (Plan 022 touches the transition's scale only); route the
   transition at 94-97 through the reduce-motion collapse described above
   (this needs a small computed property or inline `Motion.reduceMotion`
   ternary since the insertion combines three transitions).
6. Build after each file; full test suite at the end.

## Boundaries

- Do NOT re-time or re-curve anything beyond the mapping table — this is a
  consolidation, not a redesign. If a call site doesn't cleanly map, leave
  it hand-typed and note it in your report.
- Do NOT touch `zMD/MarkdownTextView.swift` / `SourceEditorView.swift`
  scroll animations (AppKit `NSAnimationContext` — correct as-is).
- Do NOT introduce an `@Environment(\.accessibilityReduceMotion)` plumbing
  refactor — the `NSWorkspace` check is the deliberate choice here because
  it works in non-View contexts (ToastManager) and avoids threading
  environment values through a dozen views. (Known tradeoff: it's read at
  animation time, not observed; a user toggling the setting mid-session
  picks it up on the next animation, which is fine.)
- If a cited site doesn't match (drift), STOP and report.

## Verification

- **Mechanical**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`;
  `xcodebuild ... test -destination 'platform=macOS'` → all pass.
  `grep -rn "easeInOut(duration\|easeOut(duration" zMD/*.swift` afterward
  should show hits only in: `SettingsManager.swift` (the token definitions),
  the welcome-screen block (Plan 023's), the dirty-dot block (Plan 021's),
  and any sites explicitly reported as unmappable.
- **Feel check**: run the app with Reduce Motion OFF — toggling sidebars,
  searching (⌘F), opening toasts (save a file) must look identical to
  before (same curves/durations, just tokenized). Then System Settings →
  Accessibility → Display → Reduce motion ON, relaunch the app:
  - Sidebar toggle, find bar, and toast arrival cross-fade in place — no
    sliding, no scaling.
  - Feedback is still visible (nothing pops in with zero indication).
- **Done when**: both feel checks pass and the grep criterion holds.
