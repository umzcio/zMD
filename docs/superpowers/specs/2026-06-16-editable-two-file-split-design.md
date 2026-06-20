# Editable Two-File Split — Design

**Date:** 2026-06-16
**Status:** Approved (design); pending implementation plan
**Branch:** `editable-two-file-split`

## Problem

zMD can show two different files side by side (the "two-file split", driven by
`DocumentManager.secondaryDocumentId` + `isSplitViewActive`). Users report that
*viewing* two files works, but *editing* them — and copy/pasting between them —
"keeps messing up."

### Root cause

The two-file split layout (`ContentView.swift:239‑283`) renders **both panes as
the read-only preview renderer** (`MarkdownTextView`):

- Left pane: `markdownPreview(for: document)` — preview only.
- Right pane: `MarkdownTextView(secondaryDoc…)` — preview only.

There is no `SourceEditorView` anywhere in this code path, and the global
preview/source/split toggle is bypassed while the two-file split is active (it
only applies in the `else` branch, `viewModeContent(for:)`). So neither file is
editable in this mode, and there is no editable target to paste into. The
copy/paste "messing up" is a downstream symptom: the only way to copy is from a
rendered pane, whose text selection is a separately known-incomplete feature.

This is a **missing capability**, not a one-line bug.

## Goal

Let each pane of the two-file split independently switch between **Rendered**
(preview) and **Edit** (source editor), so a user can edit either or both files
and reliably copy/paste between them.

## Decisions (from brainstorming)

- Per-pane independent mode toggle (not a single shared mode).
- Two modes per pane: **Rendered** and **Edit** (no per-pane source+preview
  split-within-the-split).
- Default per-pane mode is **Rendered**, preserving today's read-two-files
  behavior.

## Design

### Behavior

- Each pane header carries a compact `Rendered | Edit` toggle.
  - The right (secondary) pane already has a header (file name + close ✕); the
    toggle is added there.
  - The left (primary) pane gains a small header bar (it has none today) with
    the file name and the same toggle.
- **Rendered** → the pane shows `markdownPreview(for: doc)` (unchanged).
- **Edit** → the pane shows the existing `sourceEditor(for: doc)` — a real,
  editable `SourceEditorView` bound to that document. Typing, selection,
  copy/paste, and ⌘S all behave as in normal source mode, and edits save to the
  correct file via `updateContent(for: doc.id, …)`.
- The two toggles are independent (left Edit + right Rendered, both Edit, etc.).

### Components / changes

1. **`DocumentManager`** — add two `@Published` per-pane mode fields scoped to
   the split, e.g.:
   ```swift
   enum SplitPaneMode { case rendered, edit }
   @Published var splitPrimaryMode: SplitPaneMode = .rendered
   @Published var splitSecondaryMode: SplitPaneMode = .rendered
   ```
   Reset both to `.rendered` when the split is opened/closed (so a fresh split
   starts in the read-two-files default). Co-locate the reset with the existing
   `closeSplitView()` / split-activation logic.

2. **`ContentView` two-file split block (`:242‑283`)** — for each pane, choose
   between `markdownPreview(for: doc)` and `sourceEditor(for: doc)` based on the
   pane's mode. Add a header bar to the left pane mirroring the right pane's.
   Use the **non-synced** `sourceEditor(for:)` (NOT `syncedSourceEditor`) so the
   two panes do not contend over the global scroll-sync state
   (`scrollSyncOrigin`, etc.), which is a single-file source+preview feature.

3. **Pane header / toggle control** — a small shared subview rendering the file
   name plus a 2-state `Rendered | Edit` control bound to the relevant mode
   field. Reused by both panes to avoid divergence.

### Data flow

- Editing a pane in **Edit** mode flows through the existing, already
  document-parameterized path: `sourceEditor(for: doc)` →
  `SourceEditorWithMinimap` → `SourceEditorView` → `onContentChange` →
  `DocumentManager.updateContent(for: doc.id, …)`. No new persistence or save
  path is introduced; ⌘S / auto-save apply per document as today.

### Error handling / edge cases

- Closing the split (`closeSplitView()`) resets both pane modes to `.rendered`.
- If the secondary document is closed while in Edit mode, the existing
  split-teardown path applies (no new behavior).
- The global toolbar view-mode buttons remain bypassed while the two-file split
  is active (unchanged); the per-pane toggles are the only mode control in this
  layout.

## Scope boundaries

**In scope**
- Per-pane `Rendered | Edit` toggle in the two-file split.
- Editing either/both files in place and reliable copy/paste between two
  editable panes.

**Out of scope (deliberate)**
- Fixing text selection / copy in **Rendered** (preview) mode — the separate,
  known-incomplete feature. Users who want to copy from a file flip that pane to
  **Edit**. Tracked as a follow-up, not expanded here.
- Per-pane source+preview split (the 3-mode option), rejected during
  brainstorming.
- Changing the single-file view-mode (`.preview/.source/.split`) semantics or
  the scroll-sync feature.

## Risks / verification

- **Two live source editors coexisting.** `EditorTextView`'s autocomplete window
  controller and timers are per-instance and the static regex cache is keyed by
  pattern (effectively read-only), so two editors should coexist. **Must verify**
  during implementation: focus/first-responder behavior, autocomplete not
  cross-talking between panes, and undo isolation.
- **Acceptance test (the original complaint):** open two files; set both panes to
  **Edit**; select a block in one pane, ⌘C, click into the other pane, ⌘V — the
  pasted text must match exactly. Also verify a paste does not trigger
  auto-close-bracket mangling (already guarded: `EditorTextView.insertText`
  only applies auto-close to single-character inserts).

## Affected files (anticipated)

- `zMD/DocumentManager.swift` — pane-mode state + reset.
- `zMD/ContentView.swift` — pane mode switching + left-pane header + shared
  pane-header/toggle subview.

No changes to the parser, exporters, or the single-file view path.
