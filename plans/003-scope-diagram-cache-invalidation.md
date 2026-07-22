# Plan 003: Scope diagram-render cache invalidation to the originating document

> **Executor instructions**: Follow this plan step by step, verifying each
> step before moving on. If a "STOP conditions" trigger occurs, stop and
> report rather than improvising. Update `plans/README.md`'s status row for
> this plan when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/MarkdownTextView.swift zMD/DocumentManager.swift`
> On a mismatch between the excerpts below and live code, treat it as a STOP
> condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

Every `MarkdownTextView.Coordinator` (one per open preview pane — one per
tab, plus split-view secondary panes) registers for the `.diagramRendered`
notification with `object: nil`, meaning it receives *every* diagram/math
render completion from *anywhere in the app*, not just its own document.
When one fires, the handler drops the coordinator's entire element cache
and bumps a single shared `DocumentManager.diagramRenderTick` — which is
`@Published`, so SwiftUI re-evaluates every open `MarkdownTextView`'s body.

Net effect: rendering one Mermaid diagram or one KaTeX formula in one tab
forces a full re-parse and re-render of every other open tab's preview,
even documents with zero diagrams. On a session with several tabs open,
one diagram-heavy document makes typing/scrolling in unrelated tabs
noticeably worse. A prior audit (`docs/fable_report.md`, this repo) flagged
this exact issue; a 100ms coalescing timer was added since (reduces burst
frequency) but the observer is still global and the invalidation is still
app-wide — the coalescing masked the symptom without fixing the scope.

## Current state

- `zMD/MarkdownTextView.swift` — preview renderer; `Coordinator` class holds
  per-pane render state and the notification observer.
- `zMD/DocumentManager.swift` — holds the shared `diagramRenderTick`.

Observer registration, unscoped:

```swift
// zMD/MarkdownTextView.swift:81-86
NotificationCenter.default.addObserver(
    context.coordinator,
    selector: #selector(Coordinator.diagramDidRender),
    name: .diagramRendered,
    object: nil
)
```

The handler, which invalidates unconditionally and bumps the shared tick:

```swift
// zMD/MarkdownTextView.swift:469-487
private var diagramCoalesceTimer: Timer?

@objc func diagramDidRender() {
    diagramCoalesceTimer?.invalidate()
    diagramCoalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
        guard let self = self else { return }
        if let sv = self.scrollView {
            self.pendingDiagramScrollY = sv.contentView.bounds.origin.y
        }
        self.lastContent = nil
        self.elementCache.removeAll()
        // Force SwiftUI to re-evaluate the view body so updateNSView fires and
        // rebuilds with the now-cached image. Without this, the math/Mermaid
        // placeholder text stays on screen until the user scrolls/types/resizes
        // (regression I introduced when adding the 100ms coalesce in Phase 5).
        DocumentManager.shared.diagramRenderTick &+= 1
    }
}
```

```swift
// zMD/DocumentManager.swift:42
@Published var diagramRenderTick: Int = 0
```

Both consumers of `diagramRenderTick`:

```
zMD/DocumentManager.swift:42:    @Published var diagramRenderTick: Int = 0
zMD/MarkdownTextView.swift:485:                DocumentManager.shared.diagramRenderTick &+= 1
```

You'll need to find where `diagramRenderTick` is *read* (likely inside
`ContentView.swift` or `MarkdownTextView`'s `updateNSView`, driving
`contentChanged` detection) — grep for it before making changes so you
understand the full read/write graph; the two occurrences above are only
the write sites the recon found.

You also need the notification's **posting** side — find every
`NotificationCenter.default.post(name: .diagramRendered, ...)` call (search
`WebRenderer.swift` and `MarkdownTextView.swift`'s remote-image-load path;
the recon noted image loads post this too, not just diagrams — see
`MarkdownTextView.swift:1097`). Each poster needs to attach an `object:`
identifying which document/coordinator the render belongs to.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |
| Find posters | `grep -rn "\.diagramRendered" zMD/` | lists every post + observer site |

## Scope

**In scope**:
- `zMD/MarkdownTextView.swift`
- `zMD/WebRenderer.swift` (only the notification-posting call(s), if the
  render-completion notification is posted from there rather than from
  `MarkdownTextView` itself — confirm with the grep in Step 1)
- `zMD/DocumentManager.swift` (only if `diagramRenderTick` needs to become
  per-document; see Step 3)

**Out of scope**:
- The 100ms coalescing timer itself — keep it; it's solving a different,
  legitimate problem (multiple diagrams rendering in a burst on initial
  document open). This plan scopes *which* coordinators react, not *how
  often*.
- `PERF-01`'s underlying full-reparse-per-keystroke cost (Plan 009) — this
  plan only stops *unrelated* tabs from paying that cost; the originating
  tab's own rebuild-on-diagram-render is correct and expected behavior,
  untouched here.

## Git workflow

- Branch: `advisor/003-scope-diagram-cache-invalidation`
- Single commit is fine given the size; match repo commit-message style
  (`git log --oneline -10`).

## Steps

### Step 1: Find every poster of `.diagramRendered` and what identifies the document

```bash
grep -rn "\.diagramRendered" zMD/
```

For each `NotificationCenter.default.post(name: .diagramRendered, ...)` call
site, identify what value is available at that point that uniquely
identifies the document/pane the render belongs to — likely a document
`UUID` (from `DocumentManager`) or the `Coordinator` instance itself. Report
what you find before proceeding if it's ambiguous (e.g., if the poster is
deep inside `WebRenderer` with no document context at all — that would mean
this needs a design change beyond this plan's scope; see STOP conditions).

### Step 2: Post with an identifying `object:`, register with the matching filter

Change each post call to pass an `object:` argument — the document's `UUID`
(or the `MarkdownDocument.id`) is the natural choice since it's stable and
`Equatable`, unlike the `Coordinator` instance which SwiftUI can recreate.

```swift
NotificationCenter.default.post(name: .diagramRendered, object: documentId)
```

Change the observer registration in `MarkdownTextView.swift` to filter by
the coordinator's own document id instead of `object: nil`:

```swift
NotificationCenter.default.addObserver(
    context.coordinator,
    selector: #selector(Coordinator.diagramDidRender(_:)),
    name: .diagramRendered,
    object: nil  // NotificationCenter can't filter by `object` unless the poster
                 // and observer use the exact same identity; since document IDs
                 // are value types (UUID), prefer filtering inside the handler
                 // instead — see below.
)
```

`NotificationCenter`'s `object:` filtering does identity/equality matching
against whatever was posted; if the poster's `object:` is a `UUID` (a
`Hashable` value type, not a reference), matching *should* work via `==`,
but confirm this behaves as expected for your Swift/Foundation version
before relying on it — if it does not reliably filter, register with
`object: nil` as shown and instead filter inside the handler:

```swift
@objc func diagramDidRender(_ notification: Notification) {
    guard let renderedDocumentId = notification.object as? UUID,
          renderedDocumentId == self.documentId else { return }
    // ... existing coalesce-timer body, unchanged
}
```

(`self.documentId` — find the actual property name the `Coordinator` uses
to track which document it's rendering; it's not necessarily called exactly
that. Grep `Coordinator` in `MarkdownTextView.swift` for how it currently
knows its own document, since it must already have this to build the
correct content in the first place.)

Pick whichever approach (NotificationCenter's native `object:` matching, or
manual filtering inside the handler) is simpler given what you find — the
manual-filter approach is the safer default if you're unsure, since it
doesn't depend on `NotificationCenter`'s equality semantics for a custom
value type.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 3: Make `diagramRenderTick` per-document (or remove it)

With the observer now scoped, the *reason* `diagramRenderTick` exists — to
force SwiftUI to re-evaluate every `MarkdownTextView` body — is no longer
correct: only the *originating* coordinator's view needs to be told to
rebuild. Two options, pick whichever fits how `diagramRenderTick` is
currently consumed (you found this in Step 0/recon — re-check it now):

- **Preferred**: if `diagramRenderTick`'s read site is inside the same
  `MarkdownTextView`/`updateNSView` path that already has access to the
  coordinator, you likely don't need the shared tick at all anymore — the
  coalesce timer directly calling `self.lastContent = nil` /
  `self.elementCache.removeAll()` plus a direct call into whatever mechanism
  forces `updateNSView` to re-run (check how `contentChanged` is currently
  computed in `updateNSView`) may be sufficient without a shared published
  property. If so, remove `diagramRenderTick` entirely and let the
  coordinator drive its own rebuild.
- **Fallback**: if removing it entirely breaks something non-obvious (SwiftUI
  view-identity quirks can make "just mutate coordinator state" not
  reliably trigger a rebuild — this is plausible given the existing code
  comment explicitly says removing the tick caused a regression once
  before), keep a tick but make it per-document: e.g. a
  `@Published var diagramRenderTicks: [UUID: Int] = [:]` on
  `DocumentManager`, bumped only for the rendering document's id, read only
  by that document's `MarkdownTextView` instance.

Whichever you choose, the acceptance bar is the same: rendering a diagram in
tab A must not cause tab B's `elementCache` to be cleared or its body to
re-evaluate.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

## Test plan

Automated testing of SwiftUI view-rebuild behavior is impractical for this
codebase (no UI test target, and `Coordinator`/`NSViewRepresentable`
plumbing isn't easily unit-testable without a real window). Verify manually
instead, and record the result in your final report:

1. Open two tabs: tab A with a Mermaid diagram (e.g. a fenced ` ```mermaid `
   block with a trivial `graph TD; A-->B`), tab B with plain markdown text
   and no diagrams/math/images.
2. Switch to tab B, note its scroll position, then switch to tab A and let
   the diagram render (first render triggers `.diagramRendered`).
3. Switch back to tab B. **Before this fix**: tab B's scroll position would
   reset / its content would visibly flash-rebuild. **After this fix**: tab
   B is unaffected — same scroll position, no visible rebuild.
4. If you have a way to add temporary logging (e.g. a `print` in tab B's
   coordinator's `diagramDidRender`/rebuild path) do so temporarily to
   confirm it is NOT invoked when tab A's diagram renders, then remove the
   temporary logging before committing.

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass (no regression in existing suite)
- [ ] Manual verification (Test plan above) confirms tab B does not rebuild when tab A's diagram renders
- [ ] `grep -n "object: nil" zMD/MarkdownTextView.swift` no longer shows the `.diagramRendered` observer registration using `object: nil` for filtering purposes (either the notification now carries a real object, or filtering happens inside the handler — either satisfies this)
- [ ] No files outside scope modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- A `.diagramRendered` poster has no document/id context available at all
  (fully decoupled from any specific document) — this would mean the
  notification's design needs a bigger change (e.g. threading document
  identity through `WebRenderer`'s render-completion callback chain) than
  this plan scoped for. Stop and report the exact poster location instead
  of improvising a wider refactor.
- Removing `diagramRenderTick` (Step 3, preferred option) causes the
  documented prior regression (placeholder text staying on screen until
  scroll/type/resize) to reappear — fall back to the per-document tick
  option instead of shipping the regression.
- Any existing test in `zMDTests/` starts failing after this change — stop,
  the diagram-render path may be more coupled to other behavior than this
  plan accounted for.

## Maintenance notes

- If a future feature needs to force *all* previews to rebuild (e.g. a
  global font/theme change), that's legitimately different from this
  per-document diagram case — don't reuse the per-document mechanism for
  it; that's what app-wide `@Published` settings already do elsewhere
  (`SettingsManager`).
- Whoever touches `WebRenderer`'s render-completion callbacks next should
  know the notification now carries document identity — don't silently
  drop it when adding new render types (e.g. if a future image-caching
  change reuses this same notification).
