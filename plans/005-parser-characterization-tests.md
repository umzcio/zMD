# Plan 005: Add block-parser characterization tests, and fix escaped-delimiter tokenization

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/MarkdownParser.swift zMD/InlineMarkdown.swift zMDTests/InlineMarkdownTests.swift`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests (bundles one small bug fix)
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`MarkdownParser.parse(_:)` and `.toHTML(_:)` are the single source of truth
for both the in-app preview *and* every export format (PDF/HTML/RTF/DOCX).
They are pure `String -> [Element]` / `String -> String` functions with no
UI or I/O dependency — genuinely easy to test — but `zMDTests/` currently
only covers the *inline* tokenizer (`InlineMarkdown.swift`) and a handful of
HTML-escaping cases. Zero direct coverage exists for block-level constructs:
headings, nested ordered/unordered lists, tables, fenced code, blockquotes,
frontmatter, horizontal rules, standalone-image detection. A regression
here silently corrupts every rendering surface at once — this is exactly
the "verification baseline" a codebase should establish before further
parser changes land (several of this codebase's past bugs, per its own
audit history, lived in exactly this layer: nested-list numbering, table
header detection, standalone-image-line detection).

This plan also fixes one small, already-identified bug in
`InlineMarkdown.delimitedToken`: it finds the closing delimiter with a raw
substring search that doesn't account for backslash-escaped delimiter
characters, so `*a\*b*` (which should tokenize as italic text `a*b`, per
the escape being consumed) instead closes emphasis early at the escaped
`\*`. This affects all four rendering backends identically since they all
route through the same tokenizer — bundled here because the *test* for it
belongs in the same characterization pass, and the fix is a two-line change
next to code you'll already be reading closely.

## Current state

- `zMD/MarkdownParser.swift` — block parser. Key entry points:

```swift
// zMD/MarkdownParser.swift:98
func parse(_ markdown: String) -> [Element]
```

```swift
// zMD/MarkdownParser.swift:443
func toHTML(_ markdown: String, includeStyles: Bool = true) -> String
```

- `zMD/InlineMarkdown.swift` — shared inline tokenizer, already has 8 unit
  tests in `zMDTests/InlineMarkdownTests.swift` (read that file in full
  before starting — it shows the established test style: direct
  `XCTAssertEqual` against `InlineMarkdown.tokenize(...)` output, and
  `MarkdownParser.shared.toHTML(...)`/`.formatInlineHTML(...)` substring
  assertions for HTML-level behavior).

The bug to fix:

```swift
// zMD/InlineMarkdown.swift:154-165
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

`text[contentStart...].range(of: delimiter)` finds the *first* occurrence of
the delimiter substring, with no awareness that a `\` immediately before it
means "this delimiter character is escaped, keep scanning." For input
`*a\*b*`, delimiter `*`: `contentStart` points at `a\*b*`; `range(of: "*")`
finds the `*` right after `\` (position 2, the escaped one) — wrong. The
loop should skip past a delimiter occurrence immediately preceded by an odd
number of backslashes (i.e., actually escaped) and keep searching for the
next one.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |

## Scope

**In scope**:
- `zMD/InlineMarkdown.swift` — only `delimitedToken` (the escape-skip fix)
- `zMDTests/InlineMarkdownTests.swift` — new tests (block-level + the escape
  regression), added to this existing file to match its established
  convention, unless you judge a new file (`zMDTests/MarkdownParserTests.swift`)
  is cleaner given the volume of new tests — either is acceptable, prefer
  the existing file if it stays under ~300 lines total.

**Out of scope**:
- Any change to `MarkdownParser.parse`/`.toHTML` behavior itself — this plan
  is tests-first; if a test reveals an actual parser bug beyond the one
  named above, do NOT fix it inline — record it precisely (input, expected,
  actual) in your final report as a new finding for a future plan, and mark
  that specific test `XCTExpectedFailure` (or skip it with a `// TODO:` and
  a clear comment) rather than silently asserting the buggy behavior as
  correct.
- `MarkdownTextView.swift`, `ExportManager.swift`, `PrintManager.swift` —
  the other three consumers of the parser/tokenizer. Not modified here.

## Git workflow

- Branch: `advisor/005-parser-characterization-tests`
- Two commits recommended: one for the escape-delimiter fix (small, isolated,
  easy to review/revert independently), one for the new characterization
  tests. Match repo commit style.

## Steps

### Step 1: Fix `delimitedToken`'s escaped-delimiter handling

Replace the single `range(of:)` call with a loop that finds a delimiter
occurrence, checks whether it's escaped (preceded by a backslash not itself
escaped), and if so continues searching from just past it:

```swift
private static func delimitedToken(in text: String, at index: String.Index, delimiter: String) -> (content: String, end: String.Index)? {
    guard text[index...].hasPrefix(delimiter),
          let contentStart = text.index(index, offsetBy: delimiter.count, limitedBy: text.endIndex),
          contentStart < text.endIndex else {
        return nil
    }

    var searchStart = contentStart
    while searchStart < text.endIndex,
          let closeRange = text[searchStart...].range(of: delimiter) {
        guard contentStart < closeRange.lowerBound else { return nil }

        // A closing delimiter preceded by an unescaped backslash is itself
        // escaped text, not a real close — keep scanning past it.
        let precedingBackslashes = text[contentStart..<closeRange.lowerBound]
            .reversed()
            .prefix(while: { $0 == "\\" })
            .count
        if precedingBackslashes % 2 == 1 {
            searchStart = closeRange.upperBound
            continue
        }

        let content = String(text[contentStart..<closeRange.lowerBound])
        return (content, closeRange.upperBound)
    }

    return nil
}
```

This preserves the function's existing contract (returns `nil` if no valid
close is found) while skipping escaped delimiter occurrences. Note this
changes matching for *any* caller of `delimitedToken` (code spans, math,
strong, strikethrough, emphasis all route through it or `codeToken`) — that
is intended; the escape rule should apply uniformly.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 2: Add a regression test for the escape fix

```swift
func testEmphasisSkipsEscapedDelimiter() {
    XCTAssertEqual(
        InlineMarkdown.tokenize("*a\\*b*"),
        [.emphasis("a\\*b")]
    )
}
```

(Note: the escaped `\*` stays in the token's `content` as `\*` here because
`InlineMarkdown.tokenize`'s outer loop — not `delimitedToken` — is what
un-escapes backslash sequences via `isEscapable`, and `delimitedToken`
operates on raw substrings before that unescaping happens for nested
content. Verify this by actually running the test rather than assuming;
if the raw content differs from `"a\\*b"`, adjust the assertion to match
what the code genuinely produces — the goal is "closes at the real trailing
`*`, not the escaped one," not an exact string match if the escaping
semantics turn out subtly different than expected here.)

**Verify**: `xcodebuild ... test -destination 'platform=macOS'` → passes.

### Step 3: Add block-level parser characterization tests

Add a fixture-style test suite covering block constructs. Model each test
after the existing style in `zMDTests/InlineMarkdownTests.swift` (direct
assertions on `MarkdownParser.shared.toHTML(...)` substrings, or on
`MarkdownParser.shared.parse(...)` if `Element` cases are directly
inspectable — check `Element`'s definition/access level in
`MarkdownParser.swift` first to know which is more ergonomic).

Cover at minimum, one test per case (adjust exact assertions to match
actual current output — read the parser's handling of each construct before
writing the assertion, don't guess at output format):

1. **Headings** — `# H1` through whatever heading levels are supported;
   assert the correct `Element` case / HTML tag.
2. **Nested ordered + unordered lists** — a list with mixed nesting levels;
   assert numbering/bullet structure survives (this is the exact area a
   prior audit found bugs in — a regression test here has real value).
3. **Tables** — GFM-style table with a separator row; assert header vs.
   body row distinction.
4. **Fenced code blocks** — including a fence containing characters that
   could be misparsed as other syntax (e.g. a line starting with `#` inside
   the fence should stay literal, not become a heading).
5. **Blockquotes** — including one with inline formatting inside (e.g.
   `> **bold**`) — assert the inline formatting is applied (this was a
   previously-fixed bug; a regression test here has direct value).
6. **YAML frontmatter** — a `---` delimited block at document start; assert
   it's captured as frontmatter and not rendered as a horizontal rule or
   paragraph.
7. **Horizontal rules** — `---` / `***` mid-document (distinct from
   frontmatter, which only applies at document start).
8. **Standalone image line vs. text+image line** — `![alt](src.png)` alone
   on a line vs. `Some text ![alt](src.png) more text` — assert the
   standalone case produces an image element/block and the mixed case
   preserves all surrounding text (there's already a test for the HTML
   surface of this — `testMixedInlineImagePreservesSurroundingTextInHTML` in
   the existing file — add the complementary standalone-image-only case
   here since it isn't covered yet).
9. **Empty document** — `parse("")` / `toHTML("")` — boundary condition,
   should not crash and should produce sensible (likely empty) output.
10. **CRLF line endings** — a fixture using `\r\n` line breaks; assert
    parsing behaves identically to the `\n` equivalent (the parser has a
    `splitLines` helper that normalizes this — confirm the test actually
    exercises it rather than assuming).

Write each test independently and run the full suite after each addition
rather than writing all ten and debugging in bulk — if one fixture reveals
unexpected current behavior, you want to isolate which one before
continuing (see the Scope section's guidance on discovered-bug handling).

**Verify after each**: `xcodebuild ... test -destination 'platform=macOS'` → passes (or, per Scope, is explicitly marked as a known/tracked failure with a clear comment, not silently asserted).

## Test plan

- Step 2's escape-delimiter regression test.
- Step 3's ~10 block-level characterization tests, one per construct listed.
- All model after the existing `InlineMarkdownTests`/`RuntimeSmokeTests`
  style already in the repo — direct `XCTAssertEqual`/`XCTAssertTrue`
  against parser/tokenizer output, no mocking, no UI harness.
- Verification: `xcodebuild ... test -destination 'platform=macOS'` → all
  pass (existing + new).

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass, including all new tests from Steps 2 and 3
- [ ] At least one test exists per block construct listed in Step 3 (headings, nested lists, tables, fenced code, blockquotes, frontmatter, HR, standalone-vs-mixed image, empty doc, CRLF)
- [ ] The escape-delimiter fix (Step 1) is present and its regression test (Step 2) passes
- [ ] Any parser behavior a new test reveals as unexpected is documented in the final report, not silently fixed or silently asserted as correct
- [ ] No files outside scope modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `parse`/`toHTML`'s signatures or the `Element` type's shape don't match
  what's assumed above — re-read the live file, adapt tests to actual API.
- A new characterization test reveals a real parser bug (not the one this
  plan already knows about) that looks non-trivial to fix safely — per
  Scope, do not fix it inline; document it precisely and move on.
- More than 3 of the 10 block-construct tests fail against current
  behavior — this suggests either a deeper misunderstanding of the parser's
  actual contract on your part, or a bigger problem than this plan
  anticipated. Stop and report the specific failures rather than adjusting
  every assertion to match whatever the code happens to currently do
  (that would defeat the point of a characterization suite).

## Maintenance notes

- This is explicitly a *characterization* suite — it pins current behavior,
  it does not assert current behavior is definitionally "correct" per any
  markdown spec. Future contributors changing parser behavior should expect
  to update these tests deliberately, not treat a failing characterization
  test as automatically wrong.
- Plan 013 (testability seams for `DocumentManager`/`ExportManager`) is a
  natural follow-on once this baseline exists — it extracts more of the
  app's pure logic into testable shapes. This plan's tests are the
  reference pattern for that later work.
