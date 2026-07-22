# Plan 016: Document that underscore emphasis is unsupported by design

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/InlineMarkdown.swift zMD/HelpView.swift`

## Status

- **Priority**: P3 (direction — documentation of an existing, deliberate gap)
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction (docs-shaped)
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`InlineMarkdown.tokenize` recognizes `*`/`**` for emphasis/strong but has no
`_`/`__` handling at all — `_word_` and `__word__` render as literal
underscored text everywhere (preview and all exports), not as italic/bold.
This is standard CommonMark/GFM syntax that users pasting content from
GitHub, Obsidian, or most other markdown tools will expect to work. It's a
consistent, defensible product decision (asterisk-only emphasis avoids the
`snake_case_identifiers_in_prose` false-positive problem underscore
emphasis is notorious for) — but it is currently undocumented anywhere a
user would find it before hitting the surprise firsthand. This plan makes
the limitation discoverable, without changing behavior.

This is deliberately the smaller alternative to *implementing* underscore
emphasis (which, per this plan's sibling Plan 015's finding about the
tokenizer's now-cheap extensibility, is also a small change if the product
decision ever changes) — this plan assumes the current "asterisk-only" rule
stays, and just documents it. If the plan owner decides during review that
they'd actually rather support `_em_`/`__strong__`, that's a different,
small implementation plan following the same four-step pattern Plan 015
lays out for `.highlight` — flag this alternative in your final report.

## Current state

Confirm the gap is real before writing docs about it (don't document a
"fact" you haven't verified against current code):

```bash
grep -n '"_"' zMD/InlineMarkdown.swift
```

Expected: no delimiter-dispatch match for `_` as a standalone or doubled
emphasis delimiter (only appears, if at all, inside `isEscapable`'s
character set at `InlineMarkdown.swift:102`, which is about escaping a
literal underscore with `\_`, not about `_` as emphasis syntax).

The existing "Supported Markdown" section in the in-app help content is the
natural home for this note:

```swift
// zMD/HelpView.swift:142-152
<h2>Supported Markdown</h2>
<ul>
    <li>Headings (H1-H4)</li>
    <li>Bold, italic, inline code</li>
    <li>Bullet and numbered lists</li>
    <li>Task lists with checkboxes</li>
    <li>Code blocks</li>
    <li>Tables</li>
    <li>Images (local and remote)</li>
    <li>Horizontal rules</li>
</ul>
```

Note this list is already somewhat stale independent of this plan's scope
(it doesn't mention Mermaid diagrams or LaTeX math, both of which the app
supports per `README.md`'s Features section) — this plan's scope is
specifically adding the underscore-emphasis note; if you notice other gaps
in this list while editing, mention them in your final report rather than
expanding scope to fix all of them here.

## Commands you will need

No build/test commands apply for the primary deliverable (HTML content
string inside a Swift file, no logic change) — a build check is still worth
running since this is technically a `.swift` file edit.

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm the gap | `grep -n '"_"' zMD/InlineMarkdown.swift` | no delimiter-dispatch match |
| Build (sanity check the string literal edit didn't break Swift syntax) | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**:
- `zMD/HelpView.swift` — the "Supported Markdown" list in `helpHTML`.
- `README.md` — optional, only if you judge the top-level Features list
  should also carry a one-line note; the in-app help is the primary target
  since it's what a confused user reaches for in the moment (⌘?), but a
  README mention costs almost nothing to add if you're already touching
  related content.

**Out of scope**:
- `zMD/InlineMarkdown.swift` — no behavior change; this plan documents the
  existing gap, it does not implement underscore emphasis. If you're
  tempted to "just add it since it's small," don't — that's a product
  decision for the plan owner, not something to slip into a docs plan.
- The native `.help` bundle (`zMD/zMD.help/`) — that's a separate,
  currently-unreachable help surface; Plan 017 addresses whether it should
  be consolidated with `HelpView.swift` or removed. Don't edit it here to
  avoid maintaining two copies of this note in a surface that's about to
  potentially be deleted.

## Git workflow

- Branch: `advisor/016-document-underscore-emphasis`
- One commit.

## Steps

### Step 1: Confirm the gap

```bash
grep -n '"_"' zMD/InlineMarkdown.swift
```

Confirm no match corresponds to `_`/`__` as an emphasis delimiter (the only
expected hits, if any, are inside the escape-character set). If you find
underscore emphasis IS actually implemented somewhere this plan's recon
missed, stop — see STOP conditions.

### Step 2: Add the note to the in-app help content

Add a line to the "Supported Markdown" list in `zMD/HelpView.swift`:

```html
<li>Bold, italic, inline code</li>
```

→ becomes two lines, or one line with a note — pick whichever reads more
naturally in context (read the full surrounding list first):

```html
<li>Bold (<code>**text**</code>) and italic (<code>*text*</code>) — underscore emphasis (<code>_text_</code>) is not supported</li>
<li>Inline code</li>
```

Match the existing list's terseness — don't write a paragraph, one clear
list item is enough. Use the same `<code>` tag styling already established
elsewhere in this same HTML block (e.g. how `<kbd>` is used for shortcuts)
for consistency.

**Verify**: `xcodebuild ... build` → `** BUILD SUCCEEDED **` (confirms the Swift string literal is still syntactically valid — the HTML content lives inside a Swift multi-line string, so a stray unescaped character could break compilation).

### Step 3 (optional): Add a corresponding README note

If you judge it worth the extra line, add a brief mention in `README.md`'s
Preview Rendering feature list (find the current section — it lists things
like "Typora-style typography," "Syntax highlighting," etc.) — e.g.:

```
- **Emphasis via asterisks** — `*italic*` / `**bold**`; underscore emphasis (`_text_`) is not supported by design
```

Match the existing bullet style exactly (bold lead phrase, em-dash,
description — check 2-3 neighboring bullets to confirm this is still the
current format after the recent README simplification pass).

**Verify**: visually re-read the edited section for tone/format consistency with its neighbors.

## Test plan

Not applicable — documentation-only change with no test target coverage
for HTML help content or README prose.

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `zMD/HelpView.swift`'s "Supported Markdown" list explicitly notes underscore emphasis is unsupported
- [ ] (Optional) `README.md` carries a matching one-line note if Step 3 was done
- [ ] No behavior change — `zMD/InlineMarkdown.swift` is untouched (`git diff --stat` confirms)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Step 1's grep (or closer inspection) reveals underscore emphasis IS
  actually implemented somewhere (contradicting this plan's premise) — stop
  and report; don't document a limitation that doesn't actually exist.

## Maintenance notes

- If the product decision ever changes (underscore emphasis gets
  implemented, following Plan 015's pattern), this documentation note
  becomes stale and must be removed/updated in the same change that adds
  the feature — flag this in that future PR's review.
