# 007 — Add press feedback with asymmetric timing

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: MEDIUM
- **Category**: Physicality & origin / Interruptibility
- **Estimated scope**: 6 files, ~15 lines changed

## Problem

Two halves of the same issue:

1. **Most-tapped controls have zero press feedback.** They use
   `PlainButtonStyle()` and ignore `configuration.isPressed`, so clicks
   register with no tactile response — in a mouse-heavy tool this reads as
   lag, not crispness. Sites: `zMD/TabBar.swift:39` (add-tab), `:73`
   (outline toggle), `:141` (tab close), `zMD/FolderSidebarView.swift:36`
   (close folder) and `:135` (file rows), `zMD/OutlineView.swift:96`
   (outline rows), `zMD/CommandPaletteView.swift:271` (command rows).
   `zMD/RecentFileButtonStyle.swift` reads only hover state (lines 6-17).
2. **The one press style that exists uses symmetric timing.**
   `zMD/PressableButtonStyle.swift:7-8` — current:

   ```swift
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Motion.fast, value: configuration.isPressed)
   ```

   Press and release both run the same 120ms ease-out. Deliberate phases
   (the user's press) should animate slower; the system's response (release)
   should snap. Symmetric timing makes buttons feel like they linger under
   the cursor.

## Target

Rewrite `PressableButtonStyle` with asymmetric timing — 160ms press,
100ms release, both ease-out, scale 0.97 (inside the 0.95–0.98 band):

```swift
// zMD/PressableButtonStyle.swift — target (full file)
import SwiftUI

/// Subtle scale feedback while a button is pressed. The press (deliberate
/// user phase) runs slower than the release (system response), which snaps.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(
                Motion.reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.16 : 0.1),
                value: configuration.isPressed
            )
    }
}
```

Add the same pressed-state handling to `RecentFileButtonStyle` (keep its
existing hover code untouched):

```swift
// zMD/RecentFileButtonStyle.swift — target (full file)
import SwiftUI

struct RecentFileButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(
                Motion.reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.16 : 0.1),
                value: configuration.isPressed
            )
            .onHover { hovering in
                withAnimation(Motion.fast) {
                    isHovered = hovering
                }
            }
    }
}
```

Then swap `PlainButtonStyle()` → `PressableButtonStyle()` at the seven sites
listed above.

## Repo conventions to follow

- `PressableButtonStyle` is the app's existing press pattern (already used by
  the WelcomeView buttons) — this plan extends it rather than inventing a
  parallel one.
- Scale-only feedback, no color changes: `scaleEffect` doesn't affect layout,
  so rows won't jitter. 0.97 matches the existing token-less convention.

## Steps

1. Rewrite `zMD/PressableButtonStyle.swift` as the target full file.
2. Rewrite `zMD/RecentFileButtonStyle.swift` as the target full file.
3. In `zMD/TabBar.swift`, change `.buttonStyle(PlainButtonStyle())` at lines
   39, 73, and 141 to `.buttonStyle(PressableButtonStyle())`.
4. In `zMD/FolderSidebarView.swift`, change `.buttonStyle(PlainButtonStyle())`
   at lines 36 and 135 the same way.
5. In `zMD/OutlineView.swift`, change line 96 the same way.
6. In `zMD/CommandPaletteView.swift`, change line 271 the same way.

## Boundaries

- Motion properties and button-style swaps only — no markup, layout, or
  behavior changes.
- Do NOT apply press styles to the focus-exit pill
  (`ContentView.swift:122`) or the WelcomeView "Clear" button
  (`WelcomeView.swift:112`) — out of scope for this pass.
- Do NOT change the hover animations at any of these sites.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds. `grep -rn "PlainButtonStyle" zMD/` shows no remaining hits at the seven sites.
- **Feel check**:
  - Click and hold the tab-bar "+", an outline row, a file row, and a tab's
    × button: each visibly settles to 97% over ~160ms.
  - Release: the button snaps back in ~100ms — noticeably quicker than the
    press. It should feel like the UI exhales, not like it wakes up.
  - Rapid click-repeat on the outline toggle: every press registers visually,
    no animation queueing or stuck half-scale states.
  - Reduce Motion ON: no scale change on press; click behavior otherwise
    unchanged.
- **Done when**: all seven controls show press feedback and press/release
  timing is asymmetric.
