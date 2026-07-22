# Plan 011: Normalize CR/line-separator characters in the KaTeX math bridge

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/InlineMarkdown.swift zMD/WebRenderer.swift`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security (robustness-only — no injection escape, see below)
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`InlineMarkdown.mathToken` rejects `\n` inside a `$...$` math span (correctly
terminates the token there), but does not reject `\r`, U+2028 (LINE
SEPARATOR), or U+2029 (PARAGRAPH SEPARATOR). `WebRenderer.processNextKatexRender`
escapes only `\`, `'`, and `\n` before splicing the math content into a
single-quoted JavaScript string literal (`renderMath('...')`) passed to
`evaluateJavaScript`. Modern WebKit's JavaScript parser treats a raw `\r`,
U+2028, or U+2029 inside a single-quoted string literal as a line
terminator, which breaks the string literal and produces a JavaScript syntax
error.

**This is explicitly a robustness finding, not a security escape**: the
single-quote-and-backslash escaping already in place prevents any string-
breakout code execution — a raw `\r`/U+2028/U+2029 causes `evaluateJavaScript`
to fail with a syntax error, which is already handled gracefully by the
existing error path (nils the completion, the math span fails to render,
everything else continues normally). This plan closes the *self-inflicted
render failure*, not a vulnerability.

## Current state

- `zMD/InlineMarkdown.swift` — `mathToken`, the tokenizer function that
  decides what counts as a valid inline math span.
- `zMD/WebRenderer.swift` — `processNextKatexRender`, which escapes and
  splices math content into a JS call.

```swift
// zMD/InlineMarkdown.swift:117-152
private static func mathToken(in text: String, at index: String.Index) -> (content: String, end: String.Index)? {
    guard text[index] == "$" else { return nil }
    if index > text.startIndex, text[text.index(before: index)] == "$" { return nil }

    let contentStart = text.index(after: index)
    guard contentStart < text.endIndex else { return nil }
    let firstContent = text[contentStart]
    guard firstContent != "$",
          firstContent != " ",
          !firstContent.isNumber else {
        return nil
    }

    var cursor = contentStart
    var scanned = 0
    while cursor < text.endIndex && scanned < 200 {
        let character = text[cursor]
        if character == "\n" { return nil }
        if character == "$" {
            guard cursor > contentStart,
                  text[text.index(before: cursor)] != " " else {
                return nil
            }
            let after = text.index(after: cursor)
            if after < text.endIndex {
                let next = text[after]
                if next == "$" || next.isNumber { return nil }
            }
            return (String(text[contentStart..<cursor]), after)
        }
        text.formIndex(after: &cursor)
        scanned += 1
    }

    return nil
}
```

```swift
// zMD/WebRenderer.swift:336-338 (escaping before JS splice)
let escapedLatex = item.latex.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "'", with: "\\'")
    .replacingOccurrences(of: "\n", with: "\\n")
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |

## Scope

**In scope**:
- `zMD/InlineMarkdown.swift` — `mathToken` only.
- `zMD/WebRenderer.swift` — the escaping in `processNextKatexRender` only,
  if you choose the escaping approach instead of (or in addition to) the
  tokenizer rejection approach (see Step 1 for the choice).

**Out of scope**:
- Any other token type in `InlineMarkdown.swift` (code spans, links, etc.)
  — this plan is specifically about the math-to-JavaScript bridge; other
  token types don't cross into a JS string context.
- `WebRenderer.swift`'s Mermaid escaping path — the prior audit already
  confirmed Mermaid's escaper handles backtick/backslash/`${`/`\n`; this
  plan doesn't touch it. If you want to double-check Mermaid also misses
  `\r`/U+2028/U+2029, note it in your final report as a follow-up finding
  rather than fixing it here (out of this plan's stated scope).

## Git workflow

- Branch: `advisor/011-math-token-line-terminators`
- One commit.

## Steps

### Step 1: Choose and implement one fix — reject at the tokenizer, or escape at the bridge

Either location closes the gap; pick one (or both, if you judge belt-and-
suspenders is warranted given how cheap both are — but at minimum do one):

**Option A — reject in the tokenizer** (treats these characters the same
as `\n`, which the tokenizer already rejects — most consistent with
existing logic):

```swift
if character == "\n" || character == "\r" || character == "\u{2028}" || character == "\u{2029}" { return nil }
```

(Replace the single `if character == "\n" { return nil }` line inside the
scan loop.)

**Option B — escape at the JS bridge** (defense-in-depth; handles the
character even if it somehow reaches `WebRenderer` through some other path
than `InlineMarkdown.tokenize`, e.g. display-math which per this codebase's
prior audit already has separate handling):

```swift
let escapedLatex = item.latex.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "'", with: "\\'")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
    .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
    .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
```

Recommendation: do **Option B** as the primary fix, since it protects every
caller of `renderMath` regardless of how the LaTeX content was produced
(inline math via the tokenizer, display math via whatever separate
extraction path exists, per this codebase's audit history) — the
tokenizer-level fix (Option A) only protects the one call path through
`InlineMarkdown.tokenize`. Do Option A as well if you have time; it's a
one-line addition to a loop condition already being touched by Plan 005 in
the same general area (not the same line, no conflict expected, but be
aware if working on both plans concurrently).

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **`

### Step 2: Add a regression test

```swift
func testMathTokenRejectsCarriageReturnAndLineSeparators() {
    XCTAssertNil(InlineMarkdown.tokenize("$a\rb$").first(where: { if case .math = $0 { return true } else { return false } }))
    // A $ containing \r should NOT tokenize as a single math span — either it fails to
    // match at all (falls through to literal text) or the tokenizer stops at the \r.
    // Confirm the ACTUAL current behavior (tokenize as literal text vs. two malformed
    // math attempts) by running this and adjusting the assertion to match what the
    // tokenizer genuinely does with a rejected span, rather than assuming a specific
    // fallback shape.
}
```

If you implemented Option B (escaping) instead of/in addition to Option A,
also add or extend a `WebRenderer`-level test if one is practical — check
whether `WebRenderer`'s escaping logic is reachable from a test without a
live `WKWebView` (it likely is not, since escaping happens inline before
`evaluateJavaScript` — if untestable in isolation, skip a dedicated
`WebRenderer` test and rely on Step 1's Option A tokenizer test plus manual
verification in Step 3).

**Verify**: `xcodebuild ... test -destination 'platform=macOS'` → passes.

### Step 3: Manual verification (only if Option B is implemented and not independently testable)

If you added JS-string escaping in `WebRenderer.swift`, manually confirm a
math span containing a literal `\r` (you can construct this via a test
markdown file saved with a stray carriage return inside a `$...$` span,
though note Option A likely prevents this from ever reaching
`WebRenderer` at all if implemented — if you implemented ONLY Option B,
you'll need another path to actually exercise it, such as directly calling
`WebRenderer.shared.renderMath(...)` with a crafted string containing `\r`,
if that's reachable from a debug build) does not produce a JavaScript
console error and does not crash the render pipeline.

## Test plan

- New tokenizer test (Step 2) if Option A is implemented.
- Manual verification (Step 3) if Option B is implemented and not otherwise
  covered by an automated test.
- Existing `zMDTests/` suite must still fully pass.

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass, including any new test from Step 2
- [ ] At least one of Option A or Option B is implemented (both preferred)
- [ ] No files outside `zMD/InlineMarkdown.swift` and `zMD/WebRenderer.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `mathToken`'s or `processNextKatexRender`'s current code differs
  substantially from the excerpts (drifted) — re-read live code before
  editing.
- You find evidence that `\r`/U+2028/U+2029 CAN currently cause something
  worse than a graceful JS-syntax-error/nil-completion (e.g. an actual
  string-breakout or code execution path) — this would contradict this
  plan's stated understanding of the issue as robustness-only; stop and
  report immediately as a security escalation rather than proceeding with
  this plan's scoped fix.

## Maintenance notes

- If display-math (block `$$...$$`) extraction ever routes through a
  different escaping path than inline math's `InlineMarkdown.tokenize` →
  `WebRenderer.renderMath`, confirm it independently gets the same
  treatment — this plan only confirmed/fixed the inline-math path
  described above.
