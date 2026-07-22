# Plan 008: Correct stale claims in CLAUDE.md

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- CLAUDE.md zMD/zMD.entitlements`
> On a mismatch, re-read the live files before editing.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`CLAUDE.md` is the file every future AI coding session (and human
contributor, via `CONTRIBUTING.md`'s pointer to it) reads first for
architectural orientation. Two claims in it are actively wrong or stale,
which is worse than missing documentation — a reader trusts it and reasons
incorrectly from it:

1. The File Organization section claims `zMD.entitlements` is "currently
   empty," directly contradicted by the file itself (three real keys) and
   by CLAUDE.md's *own* Sandboxing Considerations section three paragraphs
   later, which correctly describes those same three keys. The doc
   contradicts itself.
2. The rendering-architecture description predates the unified inline
   tokenizer (`InlineMarkdown.swift`, added in the fable-report remediation)
   and the editable split-view (`SourceEditorView.swift`). An agent
   following CLAUDE.md's current guidance to "keep rendering and export in
   sync" would miss that inline formatting is now centralized in one file
   consumed by all four backends — the exact single-source-of-truth
   `InlineMarkdown.swift` was built to provide.

## Current state

The contradiction:

```
CLAUDE.md:112-116 (File Organization tree)
├── QuickOpenView.swift      # Quick open dialog
├── Assets.xcassets/         # App icon and resources
└── zMD.entitlements         # Sandbox permissions (currently empty)
```

vs. `CLAUDE.md`'s own later, correct section (already accurate — do not
change this part, only the File Organization line above):

```
### Sandboxing Considerations
The app currently ships **un-sandboxed** ... See `zMD.entitlements` —
`com.apple.security.app-sandbox` is `false`. The
`com.apple.security.files.user-selected.read-write` and
`com.apple.security.network.client` keys are present but inert outside
the sandbox.
```

The stale architecture section — read the current
`## Architecture` → `### Markdown Rendering Architecture` subsection of
`CLAUDE.md` in full before editing (it currently describes a "Two-layer
rendering" model of `MarkdownTextView.swift` + `MarkdownParser.swift` with
no mention of `InlineMarkdown.swift`, and the `### View Hierarchy` ASCII
tree likely doesn't show `SourceEditorView.swift` — confirm both omissions
by reading the live section before writing your replacement, since this
plan was written from a description of the section, not a verbatim quote of
it, and you must match its current exact wording to edit it correctly).

Confirm `InlineMarkdown.swift`'s actual consumers before writing the new
text (don't just trust this plan's summary):

```bash
grep -rln "InlineMarkdown\." zMD/ --include="*.swift"
```

Expected (as of this plan's writing): `MarkdownParser.swift`,
`MarkdownTextView.swift`, `ExportManager.swift`, `PrintManager.swift`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm InlineMarkdown consumers | `grep -rln "InlineMarkdown\." zMD/ --include="*.swift"` | lists 4 files |
| Confirm entitlements content | `cat zMD/zMD.entitlements` | shows 3 real keys, not empty |

No build/test verification applies — this plan only changes a Markdown doc
file with no code.

## Scope

**In scope**:
- `CLAUDE.md` — File Organization section (one line) and Markdown Rendering
  Architecture subsection (the stale two-layer description).

**Out of scope**:
- `zMD/zMD.entitlements` — not touched, it's already correct; only the
  *doc's claim about it* is wrong.
- Any other section of `CLAUDE.md` not specifically named here — resist the
  urge to do a broader cleanup pass; this plan is scoped to the two
  confirmed-stale claims from the audit, not a general doc rewrite.

## Git workflow

- Branch: `advisor/008-fix-claude-md-stale-claims`
- One commit.

## Steps

### Step 1: Fix the entitlements claim

Change:

```
└── zMD.entitlements         # Sandbox permissions (currently empty)
```

to:

```
└── zMD.entitlements         # Sandbox disabled; see Sandboxing Considerations below
```

**Verify**: `grep -n "currently empty" CLAUDE.md` → no matches.

### Step 2: Update the rendering-architecture description

Read the current `### Markdown Rendering Architecture` subsection in full,
then rewrite it to include `InlineMarkdown.swift` as the shared inline
tokenizer all four backends consume. The new text should convey (in
whatever prose style matches the surrounding doc — match CLAUDE.md's
existing tone, don't introduce a different voice):

- `MarkdownParser.swift` remains the single source of truth for *block*-level
  parsing (unchanged claim, still true).
- `InlineMarkdown.swift` is a separate, shared *inline* tokenizer
  (bold/italic/code/strikethrough/links/images/math) consumed by all four
  rendering backends: `MarkdownParser` (HTML/PDF/RTF export),
  `MarkdownTextView` (preview), `ExportManager` (DOCX), and `PrintManager`
  (print) — confirmed via the Step-0 grep. This replaced four independently
  drifting inline-formatting implementations.
- If the `### View Hierarchy` ASCII tree doesn't show `SourceEditorView.swift`
  as a sibling of `MarkdownTextView.swift` under the split-view container,
  add it — check the current tree structure against `ContentView.swift`'s
  actual view composition (grep `SourceEditorView(` in `ContentView.swift`
  to confirm where it's actually instantiated) before editing the diagram,
  so the corrected tree reflects real structure, not a guess.

**Verify**: `grep -n "InlineMarkdown" CLAUDE.md` → at least one match (the new mention). Re-read the edited section once more to confirm it reads coherently in context (not just a disconnected inserted sentence).

## Test plan

Not applicable — documentation-only change, no test target covers
`CLAUDE.md` content.

## Done criteria

- [ ] `grep -n "currently empty" CLAUDE.md` returns no matches
- [ ] `grep -n "InlineMarkdown" CLAUDE.md` returns at least one match
- [ ] The Sandboxing Considerations section (already-correct) is unchanged
- [ ] No files outside `CLAUDE.md` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The `### Markdown Rendering Architecture` section's current wording is
  substantially different from what this plan assumes (e.g. it was already
  updated by someone else between this plan's writing and execution — check
  the drift-check diff at the top) — re-read and adapt rather than blindly
  inserting the suggested text.
- The grep in Step 0 shows `InlineMarkdown.swift` consumed by a different
  set of files than the four named — use the actual current list in your
  doc edit, not the list in this plan.

## Maintenance notes

- Whoever next changes the inline-tokenizer/parser split (e.g. if math or
  task-list handling moves into `InlineMarkdown.swift` from wherever it
  currently lives) should update this section again — it's now a living
  architectural claim, not a one-time fix.
