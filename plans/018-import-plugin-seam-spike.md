# Plan 018 (spike): Investigate an import/plugin seam off the shared parser

> **Executor instructions**: This is a **design/spike plan**, not a build
> plan. The deliverable is a written investigation — a short design doc
> plus a list of open questions — NOT working import/plugin code. Do not
> implement a full importer or plugin system under this plan; if the spike
> makes you want to start building, stop, write up what you found, and let
> the plan owner decide whether to commission a real build plan from it.
> Update `plans/README.md`'s status row when the spike doc is written.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/MarkdownParser.swift zMD/InlineMarkdown.swift README.md`

## Status

- **Priority**: P3 (direction — exploratory)
- **Effort**: M (for the spike itself; a real build would be L and is
  explicitly not this plan)
- **Risk**: MED if scope creeps into implementation (see executor
  instructions above) — LOW if kept to investigation-only as intended.
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

zMD's own `README.md` (prior to a recent simplification pass that removed
the section — check git history if you want the exact original wording:
`git log -p -- README.md | grep -A5 "Obsidian / Logseq"`) previously named
"Obsidian / Logseq import, Notion export, Zotero citation pull" and "a Lua
or JavaScript plugin system for custom renderers / export filters" as
stated roadmap items. Neither has any corresponding code — no importer, no
plugin interface. That roadmap section was removed from the README as part
of a recent cleanup (since it read as promises the code hadn't caught up
to), but the *underlying product interest* the maintainer expressed by
writing it in the first place is still worth taking seriously as a
direction signal — it just needs to be validated with a concrete plan
before it becomes a public commitment again.

This matters now specifically because the architecture changed in a way
that makes it cheaper than it would have been a few releases ago: the
fable-report remediation unified inline formatting behind
`InlineMarkdown.swift`, and `MarkdownParser.parse(_:) -> [Element]` is
already the single block-level representation every export backend
consumes. Both are natural seams for an import path (parse *into* the same
`[Element]`/token model from a different source format) or a plugin
interface (register additional token/element handlers). Before recommending
any specific implementation, this spike should determine: is that
architectural intuition actually correct once you look closely, and if so,
what's the smallest concrete first slice worth building.

## Current state

- `zMD/MarkdownParser.swift` — `parse(_:) -> [Element]`, the block-level
  representation. Read `Element`'s full case list (`enum Element` — find
  and read every case, not just the ones mentioned elsewhere in this
  repo's docs) to understand exactly what shape any importer would need to
  produce.
- `zMD/InlineMarkdown.swift` — `Token` enum and `tokenize(_:) -> [Token]`,
  the inline representation.
- `zMD/ExportManager.swift` — the closest existing precedent for "consume
  the shared representation, produce a different format" (HTML/PDF/RTF/DOCX
  all do exactly this) — study its structure as the template for what an
  *importer* (same idea, reversed direction) or a plugin registration point
  would need to look like.
- No existing import path beyond `.md`/`.markdown` file opening
  (`DocumentManager.loadDocument`, which just reads raw text — there is no
  format-detection or transformation step at all today).
- No existing plugin/extension-point infrastructure anywhere in the
  codebase (confirmed via recon: no `protocol.*Plugin`, no dynamic loading,
  no registered-handler pattern of any kind).

## What this spike should produce

A single markdown document (suggested location:
`docs/superpowers/specs/2026-07-XX-import-plugin-seam-spike.md`, matching
this repo's existing convention for spec documents — check
`docs/superpowers/specs/` for the exact naming pattern already in use, e.g.
`2026-06-16-editable-two-file-split-design.md`, and match it) containing:

1. **A concrete first-target recommendation.** Not "a plugin system" in the
   abstract — pick the single smallest, most valuable concrete slice. The
   README's own former roadmap named several options (Obsidian import,
   Logseq import, Notion export, Zotero citation pull, Lua/JS plugin
   system) — evaluate each against: how much of it can reuse the existing
   `[Element]`/`Token` model unchanged, how large the format's own parsing
   surface is, and whether it serves this app's actual current users
   (personal note-taking / document authoring, per its README framing) or
   is scope creep toward being a different kind of app. Recommend ONE, with
   your reasoning shown, not a menu of equally-weighted options.
2. **The concrete seam.** Where exactly would this plug in? E.g., "a new
   `MarkdownImporter` protocol with one method,
   `func importDocument(_ data: Data) throws -> String` (producing zMD's
   own markdown text, NOT `[Element]` directly — reusing the *existing*
   `MarkdownParser.parse` for block structure is simpler than trying to
   import directly into `[Element]`, unless investigation shows real
   information loss going through a markdown-text intermediate)." Actually
   investigate whether round-tripping through markdown text vs. importing
   directly to `[Element]` is the right seam — don't assume, check what
   information each source format actually carries that `[Element]` can or
   can't represent.
3. **Open questions**, explicitly listed, not resolved — this is a spike,
   not a final spec. At minimum address: How does a user invoke import (a
   new File menu item? drag-and-drop of a `.docx`/Obsidian vault)? Does
   import happen once (convert-then-edit-as-markdown) or does the app need
   to maintain round-trip fidelity back to the original format? What's the
   actual complexity of parsing the target format (e.g. Obsidian's
   `[[wikilink]]` syntax and its vault-relative link resolution — is this
   a few hours or a multi-week undertaking)? Does this need any new
   dependency (a `.docx`/OPML/other-format parsing library), and if so,
   does that conflict with this codebase's stated "no dependency churn, no
   vendored binaries" design principle (documented in this repo's
   `docs/CODE_REVIEW*.md` history and formerly in the README's now-removed
   Design Decisions section — the principle itself wasn't necessarily
   wrong to remove from public docs, but it's still real prior technical
   direction worth respecting or explicitly deciding to break)?
4. **An explicit non-recommendation list** — which of the README's former
   roadmap items you'd advise *against* building soon, and why (e.g. "a
   full Lua/JS plugin system is a much bigger undertaking than any single
   import format and should not be the first slice — revisit only after a
   concrete import/export extension proves the seam is worth generalizing").

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Read Element's full case list | `grep -n "case " zMD/MarkdownParser.swift \| head -40` (adjust range once you find the enum's actual extent) | shows every `Element` case |
| Check for existing import/plugin scaffolding (confirm still absent) | `grep -rln "protocol.*Import\|protocol.*Plugin\|PluginRegistry" zMD/` | no matches |
| Former README roadmap wording (for context, if useful) | `git log -p -- README.md \| grep -B2 -A8 "Obsidian"` | shows the removed roadmap section's original text |

No build/test verification applies — this plan's only deliverable is a
markdown document; no source code changes.

## Scope

**In scope**:
- Reading and understanding `MarkdownParser.swift`, `InlineMarkdown.swift`,
  `ExportManager.swift`'s structure.
- Writing the spike document described above.

**Out of scope — do not do these under this plan**:
- Writing any actual importer, plugin protocol, or plugin loader code.
- Adding any new dependency (SwiftPM package) to the project.
- Modifying `MarkdownParser.Element`, `InlineMarkdown.Token`, or any
  existing production file.
- Committing to a specific target format publicly (e.g. re-adding a
  roadmap section to `README.md`) — that's a product communication
  decision for the plan owner to make after reading your spike, not
  something to do as part of producing it.

## Git workflow

- Branch: `advisor/018-import-plugin-seam-spike`
- One commit adding the spike document.
- Do NOT open a PR presenting this as ready-to-merge feature work — it's
  investigation output for the plan owner to read and decide on next steps.

## Steps

### Step 1: Map the existing shared-representation architecture

Read `MarkdownParser.swift`'s `Element` enum in full, `InlineMarkdown.swift`'s
`Token` enum in full, and `ExportManager.swift`'s overall structure (how it
walks `[Element]`/tokens to produce each export format) closely enough to
answer: what information does `[Element]`/`Token` capture, and what would
be lost if a rich-formatted source format (e.g. a `.docx` with real style
runs, or an Obsidian vault with wikilinks and backlinks) were forced through
this representation?

### Step 2: Evaluate each former-roadmap candidate against that model

For each of the README's former candidates (Obsidian import, Logseq import,
Notion export, Zotero citation pull, Lua/JS plugin system), write a few
sentences on: rough parsing complexity, how well it fits the existing
`[Element]`/`Token` seam, whether it needs a new dependency, and whether it
serves zMD's actual stated audience (a lightweight personal markdown
reader/editor, per its current README framing — not a knowledge-management
platform, not a full CMS).

### Step 3: Write the recommendation and open-questions document

Following the "What this spike should produce" outline above. Be willing
to recommend "none of these are worth building right now" if that's what
the investigation actually supports — per this skill's tone guidance, "not
worth doing" is a valid verdict, not a failure to produce a plan.

### Step 4: Cross-link from `plans/README.md`

Add a pointer from this plan set's index to the spike document's final
location, so a future reader of `plans/` finds it.

## Test plan

Not applicable — no code produced.

## Done criteria

- [ ] Spike document exists at `docs/superpowers/specs/<date>-import-plugin-seam-spike.md` (or wherever this repo's actual current convention places spec docs — confirmed via Step 0's directory check)
- [ ] Document contains: one concrete first-target recommendation with stated reasoning, the specific technical seam it would use, an explicit list of open questions, and an explicit non-recommendation list
- [ ] No production Swift files were modified (`git status` — only the new doc file and `plans/README.md`'s index update should appear)
- [ ] `plans/README.md` status row updated, with a link to the spike doc's final path

## STOP conditions

- You find yourself writing actual Swift implementation code — stop, that's
  out of scope for a spike; capture the design intent in prose instead and
  let a future build plan handle implementation.
- `docs/superpowers/specs/` doesn't exist or doesn't follow the naming
  pattern this plan assumes — check the actual current convention and use
  it; don't invent a new documentation location.

## Maintenance notes

- If the plan owner reads this spike and wants to proceed, the next step is
  a proper build plan (following this skill's standard template) for the
  ONE recommended slice — not a plan that tries to build every format at
  once.
- This spike's investigation into `[Element]`/`Token`'s information
  capacity is also directly useful context for Plan 015's `.highlight`
  token work and any future inline-syntax additions, even if the
  import/plugin idea itself doesn't proceed — the two investigations
  overlap in what they need to understand about the shared representation.
