# Plan 009: Debounce preview re-parse in split/source mode

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/DocumentManager.swift zMD/MarkdownTextView.swift`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — debouncing the preview means preview and source can
  briefly disagree; get the invalidation logic right or the preview will
  visibly lag/stick.
- **Depends on**: Plan 003 (touches the same file, `MarkdownTextView.swift`
  — land 003 first to reduce merge conflict risk, though the two changes
  are in different methods).
- **Category**: perf
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

In split mode (source editor + live preview side by side), every keystroke
propagates through `DocumentManager.updateContent` synchronously, and
`MarkdownTextView.updateNSView` reacts to the content change by fully
re-parsing the document (`MarkdownParser.shared.parse(content)`) and
re-extracting headings, on the main thread, per keystroke. The existing
element-level cache (`elementCache`) only memoizes the *rendered
`NSAttributedString`* of unchanged elements — it does not avoid the parse
itself, which walks the whole document every time. Autosave (2s) and search
(200ms) are already debounced elsewhere in this codebase; the preview parse
path is not, making it the dominant editor-latency cost on larger documents
in split mode.

## Current state

- `zMD/DocumentManager.swift` — `updateContent` pushes every keystroke's
  content synchronously (no debounce) into `openDocuments[index].content`,
  which is `@Published`.
- `zMD/MarkdownTextView.swift` — `updateNSView` reacts to that published
  change and, when content differs from `coordinator.lastContent`, calls
  `buildAttributedString`, which unconditionally re-parses.

```swift
// zMD/DocumentManager.swift:448-455
func updateContent(for documentId: UUID, newContent: String) {
    guard let index = openDocuments.firstIndex(where: { $0.id == documentId }) else { return }
    openDocuments[index].content = newContent
    openDocuments[index].isDirty = true

    if documentId == selectedDocumentId && isSearching && !searchText.isEmpty {
        performSearch(immediate: true)
    }
    // ... autosave timer scheduling follows, unchanged, not shown
}
```

```swift
// zMD/MarkdownTextView.swift:100-113 (updateNSView, relevant excerpt)
let zoomChanged = context.coordinator.lastZoomLevel != zoomLevel
context.coordinator.lastIsRegex = isRegexSearch
context.coordinator.lastIsCaseSensitive = isCaseSensitive

// Full rebuild when content or zoom changes
if contentChanged || zoomChanged {
    context.coordinator.lastZoomLevel = zoomLevel
    let (attributedString, headingRanges) = buildAttributedString(coordinator: context.coordinator)
    textView.textStorage?.setAttributedString(attributedString)
    context.coordinator.headingRanges = headingRanges
    context.coordinator.lastContent = content
    context.coordinator.lastSearchText = searchText
    // ...
```

```swift
// zMD/MarkdownTextView.swift:543-552 (buildAttributedString, entry)
private func buildAttributedString(coordinator: Coordinator) -> (NSAttributedString, [String: NSRange]) {
    let parser = MarkdownParser.shared
    let elements = parser.parse(content)
    let headings = parser.extractHeadings(content)
    // ...
```

`contentChanged` — find exactly how it's computed (likely
`content != coordinator.lastContent` somewhere just above the excerpt at
line 100; confirm before Step 1, since your debounce needs to interact
correctly with whatever currently triggers a rebuild).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |

## Scope

**In scope**:
- `zMD/MarkdownTextView.swift` — where the debounce is added (preview-side,
  not the document model itself).

**Out of scope**:
- `zMD/DocumentManager.swift` — do NOT debounce `updateContent` itself; the
  *source of truth* content (what gets saved, what the editor shows) must
  stay synchronous and immediate. Only the *preview's reaction* to content
  changes should be debounced. This distinction is the single most
  important constraint in this plan — get it wrong and you introduce a
  save/data-integrity bug, not just a perf regression.
- `SourceEditorView.swift`'s own per-keystroke highlighting cost — that's
  Plan 010, a separate, independent perf problem in a different view.
- Search — `performSearch(immediate: true)` inside `updateContent` already
  runs on every keystroke when actively searching; do not change that path,
  it's correct as-is (search needs to be responsive) and unrelated to the
  preview-rebuild cost this plan targets.

## Git workflow

- Branch: `advisor/009-debounce-split-mode-reparse`
- One commit.

## Steps

### Step 1: Add a short debounce to the preview rebuild trigger, not to content itself

The safest place to add debouncing is inside `MarkdownTextView`'s
`Coordinator`, gating *when* `buildAttributedString` actually runs, while
`updateNSView` keeps running on every SwiftUI update cycle (cheap) and the
document's `content` stays synchronously up to date (correct, for save/
source-editor purposes).

Add a debounce timer to the `Coordinator` and route the rebuild through it
when the *source* of the change is live typing (not, e.g., a tab switch,
which should render immediately with zero delay — see the distinction
below):

```swift
// Inside Coordinator
private var rebuildDebounceTimer: Timer?

func scheduleRebuild(for parent: MarkdownTextView, textView: NSTextView, immediate: Bool) {
    if immediate {
        rebuildDebounceTimer?.invalidate()
        rebuildDebounceTimer = nil
        performRebuild(for: parent, textView: textView)
        return
    }
    rebuildDebounceTimer?.invalidate()
    rebuildDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
        self?.performRebuild(for: parent, textView: textView)
    }
}

private func performRebuild(for parent: MarkdownTextView, textView: NSTextView) {
    let (attributedString, headingRanges) = parent.buildAttributedString(coordinator: self)
    textView.textStorage?.setAttributedString(attributedString)
    self.headingRanges = headingRanges
    self.lastContent = parent.content
    self.lastSearchText = parent.searchText
    // ... move whatever else the existing `if contentChanged || zoomChanged` block does here
}
```

Then in `updateNSView`, replace the direct `buildAttributedString` call
inside the `if contentChanged || zoomChanged` block with a call to
`context.coordinator.scheduleRebuild(...)`, passing `immediate: false` when
the change is a content edit and `immediate: true` for everything else
(zoom change, initial load, tab switch, search-text change) — you need to
determine which case you're in from what's available in `updateNSView`.
The simplest correct signal: `immediate = zoomChanged || !contentChanged`
is wrong (that's backwards) — think through it carefully: **debounce only
when `contentChanged` is true and `zoomChanged` is false** (a pure content
edit); everything else should rebuild immediately:

```swift
if contentChanged || zoomChanged {
    context.coordinator.lastZoomLevel = zoomLevel
    let isPureContentEdit = contentChanged && !zoomChanged
    context.coordinator.scheduleRebuild(for: self, textView: textView, immediate: !isPureContentEdit)
    // Remove the now-relocated body that used to sit directly in this block —
    // it moved into performRebuild above. Keep anything in this `if` block that
    // ISN'T part of the attributed-string rebuild itself (e.g. search-match
    // range recomputation that follows in the original code) — read the full
    // original block before deleting, since the excerpt in "Current state" is
    // partial and you must preserve every side effect, just move the timing.
}
```

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 2: Confirm the debounce doesn't break search-match highlighting or scroll-position restore

Read what currently happens immediately after the `buildAttributedString`
call in the original `updateNSView` (search match range population, scroll
restore, etc. — the "Current state" excerpt is truncated at line 116 and
there is more code after it in the real file). Anything that depends on
the rebuild having *just happened synchronously* needs to move inside
`performRebuild` too, or be re-triggered after the debounced rebuild
completes — do not leave code that assumes synchronous completion now
running against stale (pre-rebuild) state.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`. Manually verify (see Test plan) that search-match highlighting still updates correctly while typing in split mode.

### Step 3: Manually verify perceived latency and correctness

No automated perf test exists in this codebase and this plan doesn't
introduce one (SwiftUI/AppKit rendering latency isn't practically unit-
testable here) — verify manually and report the result:

1. Open a large-ish markdown document (a few thousand lines; you can
   generate one, e.g. by repeating a paragraph fixture) in Split mode.
2. Type continuously for several seconds. Before this fix, each keystroke
   should visibly cost noticeable main-thread work (you can observe this via Xcode's
   Debug Navigator CPU graph, or simply by feel — typing should feel
   smoother after the fix). After the fix, the preview should visibly
   "catch up" about 150ms after typing pauses, not on every keystroke.
3. Confirm the preview content is eventually fully correct after you stop
   typing (no missed final update — this is the most important correctness
   check: the debounce must not drop the LAST edit).
4. Switch tabs and switch view modes (Preview/Source/Split) — these should
   still feel instant, not debounced (confirms the `immediate: true` path
   works for non-content-edit triggers).

## Test plan

- No new automated test (perf/UI timing isn't practically testable here per
  Step 3's rationale).
- Existing test suite (`zMDTests/`) must still fully pass — this confirms
  the debounce doesn't break any test that indirectly depends on preview
  rebuild timing (check especially any `RuntimeSmokeTests` that touch
  `viewMode`/search state, since those live in `DocumentManager`, not
  `MarkdownTextView`, and shouldn't be affected — but verify by running the
  suite, don't assume).
- Manual verification per Step 3, documented in your final report (describe
  what you observed, not just "looks faster").

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass (no regression)
- [ ] Manual verification (Step 3) confirms: typing feels smoother, the final edit after typing stops is always reflected (no dropped update), and tab/mode switches remain instant
- [ ] `DocumentManager.updateContent` is unchanged — confirm with `git diff zMD/DocumentManager.swift` showing no modifications
- [ ] No files outside `zMD/MarkdownTextView.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- You find code between the excerpted `buildAttributedString` call and the
  end of the `if contentChanged || zoomChanged` block that you can't safely
  determine whether to move into `performRebuild` or leave in
  `updateNSView` — stop and report the ambiguous code rather than guessing,
  since getting this wrong means either a stale-preview bug or a
  scroll-jump bug.
- Manual testing reveals the debounced preview ever shows content that
  doesn't match what's actually in `openDocuments[index].content` for more
  than the ~150ms debounce window (i.e., the preview gets permanently
  stuck, not just briefly lagging) — this is a correctness regression, not
  an acceptable tradeoff; stop and report rather than shipping it.
- `contentChanged`'s actual computation (once you read it) doesn't match
  the assumption in Step 1 — adapt the immediate/debounced branching logic
  to the real trigger conditions, don't force-fit this plan's assumption.

## Maintenance notes

- The 150ms debounce value is a starting point, not a tuned constant —
  if manual testing in Step 3 feels laggy, a shorter value (e.g. 80-100ms)
  trades responsiveness for less main-thread work; if it still feels janky
  even fully debounced, the underlying full-reparse cost (not just its
  frequency) is the real bottleneck and would need `DEBT-01`-style shared-
  parse-model work (not planned here — noted as a larger, deferred
  architectural item in this plan set's README) to fix properly.
- Anyone adding a new `updateNSView` trigger in the future (e.g. a new
  setting that affects rendering) needs to decide whether it belongs in the
  `immediate: true` or debounced bucket — default to `immediate: true`
  unless it's specifically another form of "content just changed via
  typing."
