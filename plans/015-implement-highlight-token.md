# Plan 015: Finish `==highlight==` — implement the token the autocomplete already promises

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/InlineMarkdown.swift zMD/AutocompleteView.swift`
> On a mismatch, re-read live code before proceeding.

## Status

- **Priority**: P3 (direction — a "finish what's promised" fix, not a bug in existing behavior)
- **Effort**: S–M
- **Risk**: LOW — additive token; `==` currently falls through to plain text, so there's no existing behavior to regress.
- **Depends on**: none (benefits from Plan 005's parser-test baseline existing first, but not required)
- **Category**: direction
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`AutocompleteView`'s markdown-snippet completion list offers a "highlight"
entry that inserts `==text==` — but `InlineMarkdown.tokenize` has no `==`
case at all, so accepting that completion produces literal `==text==` in
every rendering surface (preview, HTML, PDF, RTF, DOCX, print). This is an
app actively suggesting syntax it doesn't support — the worst version of
"missing feature" because a user has to discover the breakage after
already typing it. Since the fable-report remediation unified all four
inline-rendering backends behind one tokenizer, this is now genuinely cheap
to fix: one new `Token` case plus one delimiter branch in the tokenizer, and
each backend's existing per-token `switch` just needs one more case — not
four separate regex implementations, the way it would have been before that
unification.

This is filed as a **direction** finding, not a bug fix, because it's a
product decision (should zMD support `==highlight==` markdown at all — it's
not part of CommonMark, though it is common in Obsidian/many editors) as
much as a technical one. This plan assumes the answer is "yes, since the
app already advertises it" — if the plan owner would rather remove the
autocomplete entry instead of implementing the feature, that's a much
smaller alternative (delete one line from `AutocompleteView.swift`); this
plan implements the feature, but flag the alternative in your final report
in case the plan owner reads it before this lands.

## Current state

The unfulfilled promise:

```swift
// zMD/AutocompleteView.swift:24
CompletionItem(label: "highlight", insertText: "====", icon: "highlighter", description: "Highlight — ==text==", cursorOffset: -2),
```

The tokenizer's current token set and delimiter dispatch order (no `==`
case exists):

```swift
// zMD/InlineMarkdown.swift:4-14 (Token enum)
enum Token: Equatable {
    case text(String)
    case lineBreak
    case code(String)
    case math(String)
    case strong(String)
    case emphasis(String)
    case strikethrough(String)
    case image(alt: String, source: String)
    case link(label: String, destination: String)
}
```

```swift
// zMD/InlineMarkdown.swift:72-91 (dispatch order inside tokenize's while loop)
if let token = delimitedToken(in: text, at: index, delimiter: "**") {
    flushText()
    tokens.append(.strong(token.content))
    index = token.end
    continue
}

if let token = delimitedToken(in: text, at: index, delimiter: "~~") {
    flushText()
    tokens.append(.strikethrough(token.content))
    index = token.end
    continue
}

if let token = delimitedToken(in: text, at: index, delimiter: "*") {
    flushText()
    tokens.append(.emphasis(token.content))
    index = token.end
    continue
}
```

`delimitedToken` itself (reused for every delimiter type, including the new
one) — full function already read in Plan 005's context; if Plan 005 has
landed, it will have the escape-aware version:

```swift
// zMD/InlineMarkdown.swift:154-165 (pre-Plan-005; see Plan 005 for the escape-aware replacement)
private static func delimitedToken(in text: String, at index: String.Index, delimiter: String) -> (content: String, end: String.Index)? {
    guard text[index...].hasPrefix(delimiter),
          let contentStart = text.index(index, offsetBy: delimiter.count, limitedBy: text.endIndex),
          contentStart < text.endIndex,
          let closeRange = text[contentStart...].range(of: delimiter),
          contentStart < closeRange.lowerBound else {
        return nil
    }

    let content = String(text[contentStart..<closeRange.lowerBound])
    return (content, closeRange.upperBound)
}
```

You will need to find every `switch` over `InlineMarkdown.Token` in each of
the four consuming files and add a `.highlight` case to each:

```bash
grep -rn "case .strikethrough" zMD/MarkdownParser.swift zMD/MarkdownTextView.swift zMD/ExportManager.swift zMD/PrintManager.swift
```

Use each of those four matches as your insertion point/reference for how
that backend renders `.strikethrough` — `.highlight` should follow the
exact same structural pattern in each file (recursive tokenize-and-render
of the content, wrapped in whatever that backend's equivalent of `<mark>`
is), since `~~text~~` and `==text==` are structurally identical delimiter
tokens.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |
| Find switch sites | `grep -rn "case .strikethrough" zMD/*.swift` | 4 files, one per backend |

## Scope

**In scope**:
- `zMD/InlineMarkdown.swift` — new `.highlight` token case + `==` delimiter
  dispatch (added BEFORE the `*` emphasis check, since `=` is not a prefix
  conflict with `*`/`**`/`~~`, but confirm ordering doesn't matter here by
  checking `==` can never be a valid prefix of another currently-recognized
  delimiter — it isn't, so ordering relative to the other delimiter checks
  is not load-bearing, but ordering relative to `codeToken`/`mathToken`/
  `imageToken`/`linkToken` IS load-bearing per the existing pattern — keep
  it after those, consistent with how `**`/`~~`/`*` are already ordered).
- `zMD/MarkdownParser.swift` — HTML rendering of `.highlight` (`<mark>...</mark>`)
- `zMD/MarkdownTextView.swift` — preview rendering of `.highlight`
  (background-color attributed-string span)
- `zMD/ExportManager.swift` — DOCX rendering of `.highlight` (a highlight
  run property — check what OOXML markup DOCX uses for highlighting,
  likely `<w:highlight w:val="yellow"/>` inside `<w:rPr>`, following the
  same run-property pattern already used for `<w:b/>`/`<w:i/>`/`<w:strike/>`)
- `zMD/PrintManager.swift` — print rendering of `.highlight` (background
  color attributed-string span, same approach as `MarkdownTextView`)
- `zMD/HelpView.swift` — optional: add `==highlight==` to the "Supported
  Markdown" list in the help content if you implement this (see Plan 016,
  which is about documenting unsupported syntax — this is the inverse case,
  documenting newly-supported syntax; a one-line addition, do it here if
  convenient since you're already touching related territory, otherwise
  leave it for whoever does Plan 016 to notice and add).

**Out of scope**:
- Changing `AutocompleteView.swift`'s existing entry — it's already correct
  (`insertText: "===="`, description already says `==text==`); no change
  needed there once the feature actually works.
- Any other unimplemented autocomplete snippet — this plan is scoped to
  `highlight` specifically, the one confirmed-broken promise.

## Git workflow

- Branch: `advisor/015-implement-highlight-token`
- One commit is reasonable given the mechanical, repeated-pattern nature
  of the four backend additions; split into more if you prefer per-backend
  review granularity.

## Steps

### Step 1: Add the `.highlight` token case and tokenizer dispatch

```swift
// Token enum
case highlight(String)
```

```swift
// inside tokenize(), after the existing "*" emphasis check (or wherever you
// confirm is structurally consistent with the other delimiter checks):
if let token = delimitedToken(in: text, at: index, delimiter: "==") {
    flushText()
    tokens.append(.highlight(token.content))
    index = token.end
    continue
}
```

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 2: Add a tokenizer unit test

```swift
func testHighlightTokenizesAsDistinctFromEquals() {
    XCTAssertEqual(
        InlineMarkdown.tokenize("==important== and =not= this"),
        [.highlight("important"), .text(" and =not= this")]
    )
}
```

(Confirm the exact expected output by running it — a single `=` should NOT
tokenize as highlight, only `==`; adjust the assertion if actual behavior
around the `=not=` portion differs from this guess, since `=` isn't
otherwise a recognized delimiter character and should just fall through to
plain text.)

**Verify**: `xcodebuild ... test -destination 'platform=macOS'` → passes.

### Step 3: Add rendering for each of the four backends

For each file, add a `.highlight(let content)` case to its existing
`switch` over `InlineMarkdown.Token`, immediately adjacent to the existing
`.strikethrough` case (structurally near-identical — recurse/tokenize the
inner content the same way `.strikethrough` does, then wrap in the
highlight-specific markup/attribute instead of strikethrough's):

- **`MarkdownParser.swift`** (HTML/PDF/RTF export): wrap in `<mark>...</mark>`,
  matching how `.strikethrough` wraps in `<del>` or `<s>` (confirm the exact
  tag `.strikethrough` uses and mirror the same escaping/recursion approach).
- **`MarkdownTextView.swift`** (preview): add a `.backgroundColor` attribute
  span (a soft yellow, e.g. `NSColor.systemYellow.withAlphaComponent(0.35)`,
  or whatever color convention the file already uses elsewhere — check if
  `NSColor` constants are centralized anywhere in this codebase before
  picking a raw value) over the recursively-rendered inner content.
- **`ExportManager.swift`** (DOCX): add `<w:highlight w:val="yellow"/>` to
  the run properties, following the exact pattern `.strikethrough` uses for
  `<w:strike/>`.
- **`PrintManager.swift`** (print): same background-color attribute approach
  as `MarkdownTextView`.

**Verify after each file**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 4: Add cross-backend consistency tests

Following the pattern already established by
`testMixedInlineImagePreservesSurroundingTextInHTML` (HTML-surface
assertion) in `zMDTests/InlineMarkdownTests.swift`, add at minimum an
HTML-surface test:

```swift
func testHighlightRendersAsMarkTagInHTML() {
    let html = MarkdownParser.shared.formatInlineHTML("==important==")
    XCTAssertEqual(html, "<mark>important</mark>")
}
```

If `ExportManager`'s DOCX run-generation is reachable from a test (check
whether `createRunsForFormattedText` or similar is `internal`/testable, per
the pattern `safeDOCXHyperlinkURL` already establishes), add an equivalent
assertion that the generated XML contains `<w:highlight`.

**Verify**: `xcodebuild ... test -destination 'platform=macOS'` → all pass.

## Test plan

- Step 2's tokenizer test.
- Step 4's HTML-surface test (and DOCX-surface test if reachable).
- Manual verification: type `==highlight==` in a document, confirm it
  renders with a visible background highlight in preview, and that
  exporting to HTML/PDF/DOCX/print all show it consistently (the exact
  visual treatment — color choice — doesn't need to be pixel-identical
  across formats, but it must be *present* and clearly a highlight, not
  literal `==text==`, in all four).

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass, including new tokenizer and HTML-surface tests
- [ ] `==highlight==` renders as a visual highlight (not literal characters) in preview and all four export formats
- [ ] The autocomplete's existing "highlight" snippet now produces working output when accepted
- [ ] No files outside scope modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any of the four backends' `.strikethrough` case doesn't follow the
  pattern this plan assumes (e.g. it's not a simple recursive-wrap) — read
  that backend's actual code and adapt `.highlight`'s implementation to
  match its real structure, don't force-fit the assumed pattern.
- DOCX's `<w:highlight>` OOXML syntax turns out to need more than a single
  `w:val` attribute to render correctly in real Word/Pages (verify by
  actually opening an exported `.docx` in a real word processor if
  possible, not just checking the XML looks plausible) — if it doesn't
  render correctly, report the discrepancy rather than shipping XML that
  looks right but doesn't actually work.

## Maintenance notes

- This is the reference pattern for adding any *future* inline token
  (the audit's dead-code/direction notes mention underscore emphasis as a
  deliberately-unsupported case, for contrast — see Plan 016) — a new
  delimiter-based token following this exact four-step shape (tokenizer
  case → tokenizer test → four backend renderers → cross-backend test) is
  now the established, cheap way to add markdown syntax to this codebase,
  which is the entire point of the fable-report's inline-tokenizer
  unification.
