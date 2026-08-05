# 014 — Animate the search bar's replace-row expansion

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: LOW
- **Category**: Missed opportunity
- **Estimated scope**: 1 file, 1 line changed
- **Depends on**: plan 003 (provides `Motion.fastMovement`); run after plan 004

## Problem

The find bar animates its arrival (`Motion.slideOrFade(edge: .top)` at
`zMD/ContentView.swift:60`), but toggling replace mode swaps the whole
`SearchBar` for a taller two-row variant with no animation — the bar grows by
a row instantly and the editor below jumps. A visible layout jump inside an
otherwise-animated surface.

`zMD/ContentView.swift:27-60` — current (abbreviated):

```swift
                    if documentManager.isSearching && !documentManager.isFocusModeActive {
                        Group {
                            if documentManager.showReplace && documentManager.viewMode != .preview {
                                SearchBar( ... showReplace: true, ... )
                            } else {
                                SearchBar( ... )
                            }
                        }
                        .padding(8)
                        .transition(Motion.slideOrFade(edge: .top))
```

## Target

One scoped modifier on the `Group` (between the closing brace and
`.padding(8)`):

```swift
// target
                        }
                        .animation(Motion.fastMovement, value: documentManager.showReplace)
                        .padding(8)
                        .transition(Motion.slideOrFade(edge: .top))
```

`Motion.fastMovement` (added by plan 003) is the 120ms ease-out — fast enough
for a keyboard-adjacent action, and nil under Reduce Motion so the expansion
snaps instantly for those users. Scoping it to the `Group` (not the root) is
what keeps this cheap: only the bar's height interpolates.

## Repo conventions to follow

- Scoped `.animation(value:)` on the smallest subtree that contains the
  change — the same discipline plan 004 applies to the chrome. Never on the
  root VStack.

## Steps

1. Execute plans 003 and 004 first (dependency: `Motion.fastMovement` must
   exist; plan 004 restructures the surrounding VStack).
2. Add the `.animation(Motion.fastMovement, value: documentManager.showReplace)`
   line to the search-bar `Group`, exactly as shown.

## Boundaries

- Do NOT change either `SearchBar` initializer or the `showReplace` toggle
  logic.
- Do NOT alter the bar's existing `.transition` or `.padding(8)`.
- Do NOT animate `viewMode` here — the `viewMode != .preview` guard means the
  swap also fires on mode change; plan 006 deliberately keeps mode switches
  instant, and the 120ms row expansion when it coincides is acceptable.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**: open a document, ⌘F, then toggle replace mode:
  - The bar grows by a row over ~120ms and the editor shifts down smoothly —
    no instant jump.
  - Toggle back: mirrored.
  - Reduce Motion ON: the row appears instantly.
- **Done when**: the replace-row expansion animates at 120ms and nothing else
  about the find bar changes.
