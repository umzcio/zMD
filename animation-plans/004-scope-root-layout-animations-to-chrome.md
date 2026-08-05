# 004 — Scope root layout animations to the chrome

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: HIGH
- **Category**: Performance
- **Estimated scope**: 1 file (`zMD/ContentView.swift`), ~20 lines changed

## Problem

Two broad implicit `.animation` modifiers sit on the **root VStack** of the
whole window — the SwiftUI analog of `transition: all`:

`zMD/ContentView.swift:87-88` — current:

```swift
            .animation(Motion.morph, value: documentManager.isFocusModeActive)
            .animation(Motion.fast, value: documentManager.isSearching)
```

This VStack contains the tab bar, the search bar, the entire editor/preview
subtree (AppKit `NSTextView`, split `HSplitView`, `WKWebView` preview), and
the status bar. When focus mode or the find bar toggles, SwiftUI interpolates
**every animatable layout difference in the entire tree** over 0.3s/0.12s —
tab bar height, status bar height, editor widths — forcing the text storage
to rewrap on every animation frame. On a long document this is the most
expensive possible way to toggle chrome.

## Target

Delete both root modifiers. The motion the app actually wants — the chrome
(tab bar, search bar, status bar) sliding in/out — is preserved with scoped
transitions plus one narrowly-scoped animation modifier on a new chrome-only
sub-stack. The editor content below reflows instantly (one rewrap, not 18
frames of interpolation). That instant reflow is the intended feel: crisp,
not mushy.

Focus-mode toggles are already wrapped in `withAnimation(Motion.morph)` at
their call sites (`ContentView.swift:96-98` and `:177-181`), and the find-bar
state flips inside `DocumentManager.startSearch()/endSearch()` — so the
scoped `.animation(value:)` on the chrome sub-stack is what drives the
search-bar transition.

End state for the body structure (lines 16-89), abbreviated to what changes:

```swift
            VStack(spacing: 0) {
                if !documentManager.openDocuments.isEmpty {
                    // Chrome: tab bar + search bar. Scoped so find-bar toggles
                    // animate only this sub-stack, never the editor below.
                    VStack(spacing: 0) {
                        if !documentManager.isFocusModeActive {
                            TabBar(showOutline: $showOutline)
                                .environmentObject(documentManager)
                                .transition(Motion.slideOrFade(edge: .top))

                            Divider()
                        }

                        // ... search bar conditional unchanged (lines 27-63) ...
                    }
                    .animation(Motion.standard, value: documentManager.isSearching)

                    // ... content area conditional unchanged (lines 66-75) ...

                    // Status bar (hidden in focus mode)
                    if !documentManager.isFocusModeActive {
                        Divider()
                        StatusBarView()
                            .environmentObject(documentManager)
                            .transition(Motion.slideOrFade(edge: .bottom))
                    }
                } else {
                    WelcomeView()
                }
            }
            .frame(minWidth: 600, minHeight: 400)
```

Note: `.animation(Motion.morph/fast, ...)` lines are gone; the only remaining
`.animation` is the scoped `Motion.standard` on the chrome sub-stack.

Also fix the one unanimated focus-mode exit (the pill button), so all three
toggle sites are wrapped:

```swift
// zMD/ContentView.swift:107-109 — target
                        Button(action: {
                            withAnimation(Motion.morph) {
                                documentManager.isFocusModeActive = false
                            }
                        }) {
```

## Repo conventions to follow

- Transitions already use the reduce-motion-aware tokens: the search bar uses
  `Motion.slideOrFade(edge: .top)` (`ContentView.swift:60`). Use the same
  token for the tab bar and status bar, with the edge matching the screen
  edge each bar lives on.
- `Motion.standard`/`morph` return `nil` under Reduce Motion, so the scoped
  animation degrades to an instant swap automatically — no extra gating.

## Steps

1. Delete `.animation(Motion.morph, value: documentManager.isFocusModeActive)`
   and `.animation(Motion.fast, value: documentManager.isSearching)` at
   `zMD/ContentView.swift:87-88`.
2. Wrap the tab-bar conditional (lines 18-24) and the search-bar conditional
   (lines 26-63) in a new `VStack(spacing: 0) { ... }` and attach
   `.animation(Motion.standard, value: documentManager.isSearching)` to that
   sub-stack, exactly as the target structure shows. Add a one-line comment
   above it (as in Target) explaining why the scope is narrow.
3. Add `.transition(Motion.slideOrFade(edge: .top))` to the `TabBar` view
   (after its `.environmentObject` line, currently line 21).
4. Add `.transition(Motion.slideOrFade(edge: .bottom))` to the `StatusBarView`
   (after its `.environmentObject` line, currently line 81).
5. Wrap the focus-exit pill's action (lines 107-109) in
   `withAnimation(Motion.morph)` as shown in Target.

## Boundaries

- Only `zMD/ContentView.swift` changes. Do NOT touch
  `DocumentManager.startSearch()/endSearch()` or the focus-mode notification
  handler beyond what step 5 shows.
- Do NOT change the search bar's existing `.transition` (line 60) or its
  internal layout.
- The content-area conditional (`FocusModeContentView` /
  `NormalContentView`, lines 66-75) gets no transition and no animation —
  its instant swap is deliberate.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**: open a long document (1000+ lines), then:
  - ⌘⇧F into focus mode: tab bar and status bar slide/fade out over ~200ms;
    the text column snaps to its centered width immediately rather than
    squeezing through 18 interpolated frames. ⌘⇧F back out: mirrored.
  - ⌘F: the find bar slides in from the top over 200ms; the editor below
    shifts down crisply. Escape: mirrored.
  - While either animation runs, typing in the editor stays at full speed —
    no per-frame rewrap hitch (compare against the build before this change
    on a very long document if the difference is subtle).
  - With Reduce Motion ON: all of the above become instant swaps with the
    bars fading in/out (slide dropped by `slideOrFade`).
- **Done when**: no `.animation` modifier remains on the root VStack, and
  chrome toggles still animate via scoped transitions.
