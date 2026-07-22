# Plan 010: Bound source-editor syntax highlighting to the visible range

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/SourceEditorView.swift`
> On a mismatch with the excerpt below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — bounding highlighting to a range risks unstyled text
  outside the viewport if scroll-triggered re-highlighting isn't wired
  correctly.
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`SourceEditorView.applyHighlighting` re-runs 12 separate whole-document
regex passes (one `highlightPattern` call per markdown construct — bold,
italic, code, headings, etc.) every time it's invoked, and it's invoked not
just from the debounced `textDidChange` path (0.3s debounce, reasonable)
but also **synchronously** on every document-content sync and on every
search-match-navigation step (Next/Previous). Each pass does
`regex.matches(in: text, range: 0..<text.length)` over the *entire*
document regardless of how little changed, and rewrites font/color
attributes for every matched character. Cost scales with document length ×
12 regex passes, independent of what's visible on screen or what actually
changed — pressing Next during a find-in-document re-tokenizes the whole
file even though nothing was edited.

## Current state

- `zMD/SourceEditorView.swift` — editable source view, `applyHighlighting`
  and its call sites.

```swift
// zMD/SourceEditorView.swift:450-455 (applyHighlighting entry)
func applyHighlighting(to textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    let text = storage.string
    let fullRange = NSRange(location: 0, length: (text as NSString).length)

    storage.beginEditing()
```

12 `highlightPattern` calls follow this (confirmed count via
`grep -c "highlightPattern(" zMD/SourceEditorView.swift` → 12), each
presumably passed `fullRange` or re-deriving the full range internally —
read the actual calls in the live file before starting, since the excerpt
above only shows the entry, not every pattern call, and you need to know
exactly how range is threaded through before you can bound it.

Call sites to find and read in full (search
`applyHighlighting(to:` in `SourceEditorView.swift`):
- The debounced `textDidChange` path (0.3s debounce — acceptable as-is,
  keep debounced).
- A synchronous call on document-content sync (likely when switching tabs
  or documents — this one matters less for the perf problem since it's not
  per-keystroke, but confirm).
- Synchronous calls from search-state changes / match navigation (Next/
  Previous) — this is the problematic one: navigating matches shouldn't
  re-tokenize the whole document's *markdown* highlighting at all, only
  update *search-match* highlighting, which should be a separate, cheaper
  operation.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |
| Find call sites | `grep -n "applyHighlighting(to:" zMD/SourceEditorView.swift` | lists every call site |
| Find pattern calls | `grep -n "highlightPattern(" zMD/SourceEditorView.swift` | lists all 12 |

## Scope

**In scope**:
- `zMD/SourceEditorView.swift` — `applyHighlighting`, `highlightPattern`,
  and the search-match-navigation call sites within this file.

**Out of scope**:
- Any change to *what* gets highlighted (the regex patterns / grammar
  themselves) — this plan changes *scope* (which range gets scanned) and
  *when* it runs, not the highlighting rules.
- `MarkdownTextView.swift`'s preview rendering — unrelated; the preview
  uses the parser/element-cache path (Plans 003/009), not this regex
  highlighter, which is source-editor-only.
- Search-match highlight rendering itself, if it's a genuinely separate
  code path from markdown syntax highlighting — confirm this distinction
  exists before Step 2 (see Step 2's guidance).

## Git workflow

- Branch: `advisor/010-bound-highlighting-to-viewport`
- Two commits recommended: one for viewport-bounding, one for decoupling
  search-navigation from full re-highlight.

## Steps

### Step 1: Separate "search-match navigation" from "markdown syntax re-highlight"

Before touching viewport-bounding (Step 2, the higher-risk change), do the
cheaper, lower-risk fix first: confirm whether Next/Previous match
navigation actually needs to re-run `applyHighlighting`'s 12 markdown-syntax
passes, or whether it only needs to update which range is drawn with the
"current search match" highlight color (a much cheaper, independent
operation — likely already implemented separately if `SourceEditorView`
follows the pattern described in this repo's prior audit fixes, where
search matches are stored as `NSRange` and applied via bounds-checked
`storage.addAttribute` calls, not by re-deriving matches from a full regex
scan of markdown syntax).

Read the actual call site(s) that invoke `applyHighlighting` in reaction to
search-state changes (`currentMatchIndex`, `searchMatches`, or similar
`@Published` properties on `DocumentManager` that `SourceEditorView`
observes). If they call `applyHighlighting` (the full 12-pass function)
purely to re-draw the current-match indicator, change them to call a
narrower, search-only highlight-update function instead — write one if it
doesn't already exist, following the shape of whatever mechanism already
paints search-match backgrounds (grep for how matches are currently
visually distinguished, e.g. a background-color attribute keyed by
`NSRange`, before writing new code — reuse the existing mechanism rather
than inventing a second one).

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`. Manually confirm (Test plan) that Next/Previous match navigation still visually highlights the current match, and no longer triggers a full markdown re-highlight (verify via temporary logging in `applyHighlighting`, removed before committing).

### Step 2: Bound `applyHighlighting`'s regex scans to the visible glyph range

For the remaining legitimate calls (debounced `textDidChange`, initial
document load), change the 12 `highlightPattern` calls to scan only the
`NSLayoutManager`'s currently-visible glyph range (plus a margin, so
scrolling doesn't show a flash of unstyled text before the next
highlight pass catches up), instead of `fullRange`.

```swift
private func visibleHighlightRange(for textView: NSTextView) -> NSRange {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer,
          let scrollView = textView.enclosingScrollView else {
        return NSRange(location: 0, length: (textView.string as NSString).length)
    }
    let visibleRect = scrollView.contentView.bounds
    let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
    let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

    // Margin: highlight a bit beyond the visible rect so a small scroll doesn't
    // immediately show unstyled text before the next highlight pass runs.
    let margin = 2000
    let expandedLocation = max(0, charRange.location - margin)
    let expandedEnd = min((textView.string as NSString).length, NSMaxRange(charRange) + margin)
    return NSRange(location: expandedLocation, length: expandedEnd - expandedLocation)
}
```

Update `applyHighlighting` to compute this range instead of `fullRange`, and
pass it through to each `highlightPattern` call (read how `fullRange` is
currently threaded through those 12 calls and mirror the same threading
with the new bounded range).

Add scroll-triggered re-highlighting so text that scrolls into view gets
highlighted (check whether `SourceEditorView.Coordinator` already observes
scroll events — `MarkdownTextView.Coordinator` has a
`scrollViewDidScroll` method per this codebase's other files, so
`SourceEditorView` likely has an analogous mechanism or needs one added).
Debounce the scroll-triggered highlight call (e.g. 100-150ms) so continuous
scrolling doesn't itself become a new per-frame cost.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 3: Manually verify no unstyled-text regressions

No automated test covers visual syntax highlighting correctness in this
codebase. Verify manually:

1. Open a large document (several thousand lines) in Source mode.
2. Scroll to the middle/end without ever having been highlighted there
   before — confirm text becomes highlighted (not left in plain black/
   default color) within roughly one debounce interval of scrolling to
   rest.
3. Type near the top of the document, then scroll down — confirm the
   highlighting you already saw doesn't get corrupted or reset unexpectedly
   by an edit elsewhere.
4. Confirm perceived typing latency improves on a large document (same
   qualitative check as Plan 009's Step 3).

## Test plan

- No new automated test — visual highlighting correctness over a real
  `NSLayoutManager`/scroll view isn't practically unit-testable in this
  codebase's current test infrastructure.
- Existing `zMDTests/` suite must still fully pass.
- Manual verification per Step 3, documented in your final report.

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass (no regression)
- [ ] Manual verification confirms: scrolling to unseen text eventually highlights it, typing latency improves on large documents, and search-match navigation no longer triggers full 12-pass re-highlighting (per Step 1)
- [ ] `grep -n "fullRange" zMD/SourceEditorView.swift` — confirm `fullRange` (or equivalent whole-document range) is no longer passed to `highlightPattern` from the viewport-bounded call sites (it may still legitimately exist for the *initial* full-document highlight on document load — use judgment, document your reasoning in the final report if you keep any full-range call)
- [ ] No files outside `zMD/SourceEditorView.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- You cannot find an existing separate mechanism for search-match visual
  highlighting distinct from markdown syntax highlighting (Step 1) — if
  they're genuinely the same code path with no way to separate them
  cheaply, stop and report rather than inventing a parallel highlighting
  system as a large unplanned addition; a narrower fix (e.g. just skip the
  markdown-syntax passes on pure navigation, keep whatever repaints the
  match color) may still be possible with less work — use judgment but
  report what you find.
- Manual testing reveals visible unstyled-text flashes that don't resolve
  within a reasonable time after scrolling stops — the margin/debounce
  values need tuning; don't ship a visibly broken highlighting experience
  even if it's "technically bounded correctly."
- `NSLayoutManager`/`textContainer`/`enclosingScrollView` access patterns
  differ from what's assumed (e.g. this view doesn't use a standard
  `NSScrollView` wrapper) — adapt to the actual view hierarchy, don't force
  the assumed API shape.

## Maintenance notes

- The 2000-character margin and debounce timing are starting points; if a
  future user reports visible unstyled flashing during fast scrolling, that
  margin should grow before reaching for a more complex incremental-
  highlighting scheme.
- If `MarkdownTextView`'s preview ever grows its own regex-based
  highlighting (it currently doesn't — it uses the parser/attributed-string
  path), the same viewport-bounding pattern from this plan is directly
  reusable there.
