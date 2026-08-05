# 012 — Animate split view open/close

- **Status**: DONE
- **Commit**: 023ae28
- **Severity**: MEDIUM
- **Category**: Missed opportunity
- **Estimated scope**: 2 files, ~6 lines changed

## Problem

Opening a split view teleports: the second pane appears instantly and shoves
the primary pane sideways. Every sibling panel in the same layout — folder
sidebar, outline — enters with `Motion.slideOrFade`, so the seam is both
jarring and inconsistent with the app's own motion grammar. Split toggling is
an occasional action (a few times per session), squarely in the "standard
animation" frequency class.

`zMD/NormalContentView.swift:32-35` — current:

```swift
                    if documentManager.isSplitViewActive,
                       let secondaryId = documentManager.secondaryDocumentId,
                       let secondaryDocument = documentManager.openDocuments.first(where: { $0.id == secondaryId }) {
                        HSplitView {
```

The `HSplitView` has no `.transition`, and the state mutations are unwrapped:

`zMD/DocumentManager.swift:474-487` — current:

```swift
    func openInSplitView(documentId: UUID) {
        guard documentId != selectedDocumentId else { return }
        secondaryDocumentId = documentId
        isSplitViewActive = true
        ...
    }

    func closeSplitView() {
        secondaryDocumentId = nil
        isSplitViewActive = false
        ...
    }
```

## Target

Give the split container the same slide-in-from-trailing grammar as the
outline, and wrap both mutations:

```swift
// zMD/NormalContentView.swift — target (add one modifier to the HSplitView)
                        HSplitView {
                            // ... contents unchanged ...
                        }
                        .transition(Motion.slideOrFade(edge: .trailing))
```

```swift
// zMD/DocumentManager.swift:474-487 — target
    func openInSplitView(documentId: UUID) {
        guard documentId != selectedDocumentId else { return }
        withAnimation(Motion.standard) {
            secondaryDocumentId = documentId
            isSplitViewActive = true
            splitPrimaryMode = .rendered
            splitSecondaryMode = .rendered
        }
    }

    func closeSplitView() {
        withAnimation(Motion.standard) {
            secondaryDocumentId = nil
            isSplitViewActive = false
            splitPrimaryMode = .rendered
            splitSecondaryMode = .rendered
        }
    }
```

## Repo conventions to follow

- Exemplar — the outline in the same file already pairs
  `.transition(Motion.slideOrFade(edge: .trailing))` with a wrapped toggle
  (`zMD/NormalContentView.swift:28` + `zMD/TabBar.swift:62-66`). This plan
  mirrors that pairing exactly.
- `Motion.standard` returns `nil` under Reduce Motion and `slideOrFade`
  drops the slide — the fade-in-place degradation comes free.
- `withAnimation` in `DocumentManager` is safe: both functions run on the
  main thread and mutate `@Published` UI state directly.

## Steps

1. `zMD/NormalContentView.swift`: add
   `.transition(Motion.slideOrFade(edge: .trailing))` to the `HSplitView`
   (immediately after its closing brace, before the `else` branch of the
   surrounding conditional).
2. `zMD/DocumentManager.swift:474-480`: wrap the four mutations in
   `openInSplitView` in `withAnimation(Motion.standard)` as shown. The
   `guard` stays outside the animation block.
3. `zMD/DocumentManager.swift:482-487`: wrap the four mutations in
   `closeSplitView` the same way.

## Boundaries

- Do NOT add an `.animation(value:)` modifier to any container — the wrapped
  mutations carry the animation; a blanket modifier would re-create the
  broad-scope problem plan 005 removes.
- Do NOT change split pane proportions, the `HSplitView` structure, or the
  pane headers.
- If a step doesn't match the code you find (drift since the commit stamp), STOP and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` succeeds.
- **Feel check**: with two documents open, open one in split view:
  - The split slides in from the trailing edge over ~200ms, matching how the
    outline enters — the motion explains where the pane came from.
  - Close the split (pane header ×): mirrored.
  - Open/close several times in a row: each toggle completes cleanly, no
    half-open flicker.
  - Reduce Motion ON: the split fades in place with no slide.
- **Done when**: split open/close animates with the same grammar as the
  outline toggle.
