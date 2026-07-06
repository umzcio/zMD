# Fable Report Remediation — Implementation Plan

> **For agentic workers:** This plan follows the local superpowers task format. Steps use checkbox (`- [ ]`) syntax for tracking. Work task-by-task; keep the build green after each task.

**Goal:** Address the findings in `fable_report.md` without destabilizing zMD. Fix data-loss and text-corruption risks first, then search behavior, parser/export correctness, security/robustness, editor edge cases, and finally cleanup.

**Audit Source:** `fable_report.md`, dated 2026-07-04.

**Tech Stack:** Swift, SwiftUI + AppKit, macOS app target only. No test target currently exists.

## Global Constraints

- Build command after every implementation task:
  `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build`
- Prefer scoped edits in existing files. Adding new Swift source files requires `.pbxproj` updates; do that only when the abstraction is worth it.
- The app does not use `NSDocument`; document lifecycle safety must remain owned by `DocumentManager`.
- Do not treat all audit line numbers as authoritative. First verify current code because this repo has active prior fixes and uncommitted `fable_report.md`.
- For tasks touching parser/export behavior, create small markdown fixtures and compare preview/export behavior manually unless an XCTest target is intentionally added for that phase.
- For runtime-only findings, document the smoke test result in the task before marking it complete.

## Triage Order

1. **Data loss / silent feature death:** C1, H1, M8, L4, L5, L13.
2. **Text corruption / broken primary workflows:** H2, H3, M13, M7.
3. **Parser and renderer correctness:** H4, M1, M2, M3, M9, M12, L6-L9, L15, L17, code-quality parser divergences.
4. **Export/web rendering robustness and security:** M4-M6, M10-M11, L10-L12, additional security notes.
5. **Low-risk cleanup:** L1-L4, L14, L16, dead-code inventory.

---

## Task 0: Establish Baseline And Finding Map

**Findings:** all.

**Files:**
- Read/inspect: `fable_report.md`, affected Swift files.
- Modify: none expected.

**Purpose:** Confirm which findings still reproduce in the current working tree and avoid fixing stale or already-resolved issues.

- [ ] Run `git status --short` and note unrelated/untracked files. Do not revert user changes.
- [ ] Run a clean debug build.
- [ ] Create a local finding map with statuses: `confirmed`, `already fixed`, `needs runtime verification`, `defer`.
- [ ] For each runtime-only item, define a smoke test before implementation starts.

**Verification:** clean build succeeds, and every audit item has an initial status.

---

## Task 1: Centralize Dirty-Close Decisions And Fix Quit Data Loss

**Findings:** C1, M8.

**Files:**
- Modify: `zMD/DocumentManager.swift`
- Modify: `zMD/zMDApp.swift`
- Modify: `zMD/TabBar.swift`

**Interfaces:**
- Promote dirty-close handling from private single-document close logic into a document-manager-owned API reusable by tab close, window close, and app quit.
- Add an `AppDelegate.applicationShouldTerminate(_:)` path that checks all dirty documents.

- [ ] Replace the Quit menu action with a path that still reaches `NSApplication.terminate`, but make termination safe through `applicationShouldTerminate`.
- [ ] Add a `DocumentManager` method for quitting with dirty documents. It must handle multiple dirty tabs without silently discarding edits.
- [ ] Support `.terminateCancel` for user cancel and `.terminateLater` only if a save panel must complete asynchronously.
- [ ] Remove the pre-prompt from `TabBar` close button; call `documentManager.closeDocument(document)` and let the manager own the prompt.
- [ ] Remove the pre-prompt from `WindowCloseDelegate.windowShouldClose`; let `closeDocument` own the prompt.
- [ ] Keep untitled/save-panel behavior explicit: if saving requires `NSSavePanel`, do not close or terminate until the panel outcome is known.

**Verification:**
- [ ] Build succeeds.
- [ ] Dirty saved file + `Cmd+Q`: Save, Don't Save, and Cancel each behave correctly.
- [ ] Dirty untitled file + `Cmd+Q`: Save panel path does not quit before the user picks a destination.
- [ ] Dirty tab close shows one prompt, not two.
- [ ] Dirty window close shows one prompt, not two.

---

## Task 2: Fix FileWatcher Descriptor Ownership

**Findings:** H1.

**Files:**
- Modify: `zMD/FileWatcher.swift`

**Implementation Notes:**
- The cancel handler must close the descriptor captured for that source, not whatever descriptor is currently stored on `self`.
- Avoid double-close. Either close only from the cancel handler or make `stopWatching()` transfer ownership to the cancel handler before clearing state.

- [ ] Change `startWatching()` to capture `let fd = fileDescriptor` before creating/configuring the dispatch source.
- [ ] Set the cancel handler to close only that captured `fd`.
- [ ] Update `stopWatching()` so it cancels and nils the source, clears `fileDescriptor`, and does not synchronously close the same fd.
- [ ] Verify `restartIfFileExists()` can cancel source A, start source B, and source A's deferred cancel handler cannot close source B's fd.

**Verification:**
- [ ] Build succeeds.
- [ ] Runtime smoke: open a file, save it from zMD, then edit the same file externally twice. External-change detection still fires after both edits.

---

## Task 3: Repair Search State For Source Mode And Content Edits

**Findings:** H2, H3, M13.

**Files:**
- Modify: `zMD/DocumentManager.swift`
- Modify: `zMD/ContentView.swift`
- Modify: `zMD/SearchBar.swift`
- Modify: `zMD/SourceEditorView.swift`
- Possibly modify: `zMD/MarkdownTextView.swift`

**Design Direction:**
- Stop storing live `String.Index` values across content mutations. Store search matches as stable UTF-16 `NSRange` plus line number.
- Treat source-match count as the authoritative count when the active surface is Source mode. In Split mode, decide whether search navigation is source-based, rendered-based, or explicitly preview-only; do not mix rendered indices with source replacement indices.

- [ ] Change `SearchMatch` to store `NSRange` offsets instead of `Range<String.Index>`.
- [ ] Update plain and regex search builders to emit UTF-16 ranges.
- [ ] Update `replaceCurrentMatch()` and `replaceAllMatches()` to validate each stored `NSRange` against the current content immediately before replacing.
- [ ] Re-run or invalidate search from `updateContent(for:newContent:)` when the edited document is the selected searched document.
- [ ] Ensure pending async regex results cannot overwrite newer content's match list. Existing `searchToken` should be bumped on content edits too.
- [ ] Update `SourceEditorView.applyHighlighting` to use stored `NSRange` directly after bounds validation.
- [ ] Add a `DocumentManager.visibleSearchMatchCount` or equivalent so `SearchBar` is enabled in pure Source mode.
- [ ] Make Next/Previous operate on the same count/index space used for Replace.
- [ ] Decide and document Split-mode behavior before changing it. Preferred short-term fix: use source matches for SearchBar controls and keep preview highlighting best-effort.

**Verification:**
- [ ] Build succeeds.
- [ ] Source mode: find shows nonzero count, Next/Previous move active highlight, Replace and Replace All work.
- [ ] With find bar open, type before a match, then Replace. It replaces the currently valid match or safely no-ops; it must not corrupt text or crash.
- [ ] Regex replace with capture groups still works.
- [ ] Split mode does not replace a different occurrence than the active search index indicates.

---

## Task 4: Fix File Identity, Split State, And Path Prefix Lifecycle Edge Cases

**Findings:** L4, L5, L13.

**Files:**
- Modify: `zMD/DocumentManager.swift`
- Modify: `zMD/FolderManager.swift`

- [ ] Use the existing canonical file key path in `loadDocument(from:)` so symlinks/case variants do not open duplicate tabs for the same file.
- [ ] In `closeOtherDocuments(except:)`, clear `secondaryDocumentId` and `isSplitViewActive` when the secondary document is closed.
- [ ] Ensure split pane modes are reset consistently through `closeSplitView()`.
- [ ] Replace `FolderManager.noteSelfWrite` path-prefix check with a component-safe/trailing-slash check, matching the safer pattern already used elsewhere.

**Verification:**
- [ ] Build succeeds.
- [ ] Opening the same file through a symlink or canonical path focuses the existing tab rather than duplicating it.
- [ ] Open two-file split, close other documents from the primary tab. No stale right pane/split state remains.
- [ ] Folder self-write detection does not match sibling folders with shared prefixes.

---

## Task 5: Fix Inline Images Mixed With Text

**Findings:** H4.

**Files:**
- Modify: `zMD/MarkdownParser.swift`
- Modify as needed: `zMD/MarkdownTextView.swift`, `zMD/ExportManager.swift`, `zMD/PrintManager.swift`

**Design Direction:**
- Only emit a block `.image` element when the line is just an image.
- Lines such as `See ![diagram](d.png) for the flow.` must remain a paragraph and render the inline image or, if inline image support is not feasible in every backend immediately, preserve all text and image alt/path visibly.

- [ ] Change paragraph classification so image-containing text is not excluded from paragraph accumulation.
- [ ] Restrict the standalone image branch to lines where the full trimmed line matches the image syntax.
- [ ] Add inline image handling to `formatInlineHTML` so HTML/PDF/RTF export preserves both surrounding text and image.
- [ ] Check preview behavior. If preview does not support inline image attachments, preserve text and show a clear inline placeholder rather than dropping text.
- [ ] Confirm multiple images on one line do not drop text or later images.

**Verification:**
- [ ] Build succeeds.
- [ ] Fixture: `See ![diagram](d.png) for the flow.` preserves `See` and `for the flow.` in preview and exports.
- [ ] Fixture with two images on one line preserves both image references.

---

## Task 6: Introduce Shared Inline Tokenization

**Findings:** M1, M12, L7, L8, code-span pieces of M3.

**Files:**
- Modify: `zMD/MarkdownParser.swift`
- Modify: `zMD/MarkdownTextView.swift`
- Modify: `zMD/ExportManager.swift`
- Modify: `zMD/PrintManager.swift`
- Optional new file: `zMD/InlineMarkdown.swift` if the shared tokenizer is large enough to justify `.pbxproj` work.

**Design Direction:**
- Create one inline tokenizer that emits spans: text, strong, emphasis, code, link, image, strikethrough, escaped text, math placeholder if needed.
- Backend-specific emitters convert spans to HTML, attributed strings, DOCX runs, and print runs.
- Code spans must be tokenized before emphasis so `` `*foo*` `` stays literal everywhere.

- [ ] Define the supported inline syntax intentionally. Document underscore emphasis as unsupported if that remains the decision.
- [ ] Implement tokenizer with explicit code-span protection instead of regex pass ordering.
- [ ] Route `MarkdownParser.formatInlineHTML` through the tokenizer.
- [ ] Route preview paragraph and blockquote formatting through the tokenizer so blockquotes apply inline formatting.
- [ ] Route DOCX run generation through the tokenizer, including table header cells.
- [ ] Route print inline formatting through the tokenizer.
- [ ] Add support or an explicit non-support decision for `~~strikethrough~~`, task-list markers, and `==highlight==` autocomplete snippet.

**Verification:**
- [ ] Build succeeds.
- [ ] Fixture renders consistently across preview, HTML, PDF/RTF path, DOCX path, and print where applicable:
  - `` `*foo*` ``
  - `> **important**`
  - `**bold** and *italic* and ~~strike~~`
  - `[label](https://example.com)`
  - table header with `**bold**`

---

## Task 7: Fix Math Extraction And Export Paths

**Findings:** M2, M3.

**Files:**
- Modify: `zMD/ExportManager.swift`
- Modify: `zMD/MarkdownParser.swift`
- Modify as needed: `zMD/MarkdownTextView.swift`

- [ ] Apply math pre-extraction to HTML export, not just PDF/RTF.
- [ ] Make math extraction markdown-aware enough to skip fenced code blocks and inline code spans.
- [ ] Ensure preview inline math detection also ignores inline code spans.
- [ ] Preserve math placeholders through inline formatting without exposing placeholders in output.

**Verification:**
- [ ] Build succeeds.
- [ ] HTML export of `$a * b * c$` leaves the LaTeX intact for KaTeX.
- [ ] Fenced code containing `$$` remains code in PDF/RTF/HTML export.
- [ ] Inline code containing `$FOO;$BAR` remains literal in preview.

---

## Task 8: Fix WebRenderer KaTeX Queue And Export Race Conditions

**Findings:** M4, M5, M6, L12.

**Files:**
- Modify: `zMD/WebRenderer.swift`
- Modify: `zMD/ExportManager.swift`

- [ ] Include `forceLightTheme` in queued KaTeX work items.
- [ ] Clear `activeKatexCompletion` on JavaScript error the same way Mermaid does.
- [ ] Replace `substituteMathPlaceholdersInHTML`'s shared dictionary/semaphore pattern with an ordered result collection that is only mutated/read on one queue or is otherwise synchronized.
- [ ] Prevent late render completions from racing against timeout fallback output.
- [ ] Avoid `5 seconds * N math spans` stalls when KaTeX never becomes ready. Use a whole-export timeout or fail-fast readiness state.
- [ ] Replace or guard the private `drawsBackground` KVC usage so a future WebKit change cannot raise at runtime.

**Verification:**
- [ ] Build succeeds.
- [ ] Cold dark-mode export still produces readable math on white PDF/RTF pages.
- [ ] Simulated KaTeX failure produces output without data races or long per-span hangs.
- [ ] Hidden WebViews still render transparent snapshots where required after the background handling change.

---

## Task 9: Move DOCX Export Work Off The Main Thread

**Findings:** M11.

**Files:**
- Modify: `zMD/ExportManager.swift`

- [ ] Move heavy DOCX work (`createCustomDOCX`, image loading, XML generation, zip spawn/wait) off the main thread.
- [ ] Keep UI work (`NSSavePanel`, alerts, toasts) on the main thread.
- [ ] Move mutable export state into a per-export context so overlapping exports cannot corrupt relationships/list counters.
- [ ] Ensure `/usr/bin/zip` timeout/cancellation is reported cleanly.

**Verification:**
- [ ] Build succeeds.
- [ ] Export a DOCX from a large markdown file while interacting with the UI; the app must not beach-ball for the zip wait.

---

## Task 10: Fix Print, DOCX, RTF, And PDF Low-Level Output Bugs

**Findings:** M9, L1, L6, L7, L8, L9, L10.

**Files:**
- Modify: `zMD/PrintManager.swift`
- Modify: `zMD/ExportManager.swift`

- [ ] Preserve ordered-list numbering in print instead of converting ordered lists to bullets.
- [ ] Generate export filenames by replacing only the final path extension, not every `.md` substring.
- [ ] Make DOCX numbering definitions cover every `ilvl` the parser can emit, or clamp emitted levels to defined levels.
- [ ] Apply inline formatting to DOCX table header cells.
- [ ] Decide whether DOCX should render strikethrough and task-list checkboxes; implement or document.
- [ ] Absolutize relative image sources for RTF export the same way PDF does.
- [ ] Save and restore `NSGraphicsContext.current` around PDF export rendering.

**Verification:**
- [ ] Build succeeds.
- [ ] Print fixture with `3. first` and nested ordered lists keeps numbers.
- [ ] `my.md.notes.md` exports as `my.md.notes.pdf` or equivalent final-extension replacement.
- [ ] Relative images render in RTF export.

---

## Task 11: Harden Exported HTML Security

**Findings:** M10, L11.

**Files:**
- Modify: `zMD/MarkdownParser.swift`

**Design Direction:**
- Prefer escaping raw HTML blocks in exports or parsing through a small allowlist. Regex sanitization of arbitrary HTML is brittle.

- [ ] Decide policy for raw HTML blocks: escape by default, allowlist limited tags/attrs, or keep raw only behind an explicit unsafe setting.
- [ ] Fix event-handler stripping if raw HTML remains supported; separators other than whitespace must not bypass sanitization.
- [ ] Normalize/decode URL schemes before checking for `javascript:` and related dangerous schemes.
- [ ] Disallow `data:image/svg+xml` in links/images unless sanitized.

**Verification:**
- [ ] Build succeeds.
- [ ] Exported HTML neutralizes `<div/onclick=alert(1)>`.
- [ ] Exported HTML neutralizes obfuscated `javascript:` schemes.
- [ ] Markdown links with normal `http`, `https`, `mailto`, relative paths, and fragments still work.

---

## Task 12: Fix Multi-Cursor Position Drift

**Findings:** M7.

**Files:**
- Modify: `zMD/EditorTextView.swift`
- Modify as needed: `zMD/MultiCursorController.swift`

- [ ] Compute final cursor locations after all descending edits by accounting for shifts from lower-position edits.
- [ ] Apply the same corrected mapping to insert and delete paths.
- [ ] Keep primary cursor and additional cursors aligned after repeated keystrokes.

**Verification:**
- [ ] Build succeeds.
- [ ] Runtime smoke: cursors at two positions, type several characters. Every cursor advances to the correct post-edit position.
- [ ] Runtime smoke: delete/backspace at multiple cursors. Cursor positions stay correct.

---

## Task 13: Fix Editor And Preview Robustness Edge Cases

**Findings:** L2, L3, L14, L15, L17.

**Files:**
- Modify: `zMD/MarkdownTextView.swift`
- Modify: `zMD/MinimapView.swift`
- Modify: `zMD/SyntaxHighlighter.swift`
- Modify: `zMD/QuickOpenView.swift`
- Possibly modify: `zMD/FuzzyMatcher.swift`

- [ ] Guard delayed `scrollToHeading` selection ranges against current storage length immediately before `setSelectedRange`.
- [ ] Add in-flight and negative-result tracking for failed remote image loads so every rebuild does not re-download.
- [ ] Bound minimap bitmap size for very large files.
- [ ] Make code-block font sizing respond to zoom consistently with the block frame.
- [ ] Fix Quick Open highlighting to use UTF-16-safe `NSRange` conversion instead of Character-count indices.

**Verification:**
- [ ] Build succeeds.
- [ ] Very large file does not allocate an unbounded minimap bitmap.
- [ ] Quick Open highlights non-BMP filenames correctly.

---

## Task 14: Clean Up Shortcut And Dead-Code Inventory

**Findings:** L16, dead-code inventory.

**Files:**
- Modify as needed:
  - `zMD/MarkdownParser.swift`
  - `zMD/FolderManager.swift`
  - `zMD/FileWatcher.swift`
  - `zMD/MarkdownTextView.swift`
  - `zMD/EditorTextView.swift`
  - `zMD/DocumentManager.swift`
  - `zMD/QuickOpenView.swift`
  - `zMD/SearchBar.swift`
  - `zMD/zMDApp.swift`

- [ ] Remove duplicate `Cmd+G`/`Shift+Cmd+G` key equivalents from either menu or buttons after verifying the responder behavior.
- [ ] Remove high-confidence dead code only after related behavior fixes are complete.
- [ ] Keep `DocumentManager.hasUnsavedChanges()` if Task 1 uses it; otherwise remove only if truly unused after quit handling.
- [ ] Do not remove medium-confidence Apple Event handling until Finder-open behavior is tested.
- [ ] Remove stale fix-history comments where they no longer describe current invariants.

**Verification:**
- [ ] Build succeeds.
- [ ] Finder open of `.md` file still works if Apple Event code is changed.
- [ ] Search shortcuts still work exactly once.

---

## Task 15: Address Remaining Architecture And Policy Findings

**Findings:** code-quality notes and additional security/robustness notes from sections 3-4 of `fable_report.md`.

**Files:**
- Modify as needed:
  - `zMD/MarkdownParser.swift`
  - `zMD/MarkdownTextView.swift`
  - `zMD/ExportManager.swift`
  - `zMD/DocumentManager.swift`

- [ ] Decide whether tables require a separator row before treating row 0 as a header. If keeping the current simplified behavior, document it.
- [ ] Fix or explicitly defer HTML export's flattened nested-list behavior so nested ordered lists do not number as one flat sequence.
- [ ] Scope `Coordinator.diagramDidRender` notifications to the relevant document/view instead of having every open preview rebuild for any diagram render.
- [ ] Evaluate sharing scroll-sync coordinator logic between preview and source after behavioral fixes are complete. Do not refactor before search/split fixes are stable.
- [ ] Move remaining per-export mutable singleton state in `ExportManager` into per-export context if Task 9 did not already cover every field.
- [ ] Decide policy for absolute local image paths in preview/export. If preserving them, document the exfiltration risk; if restricting them, keep user-selected/local-folder workflows working.
- [ ] Normalize raw carriage returns before injecting Mermaid/KaTeX JavaScript strings, even if the worst known case is only a syntax error.
- [ ] Leave the updater's pre-verification DMG attach behavior documented as accepted risk unless the release/update design is revisited.

**Verification:**
- [ ] Build succeeds.
- [ ] Nested list and table fixture outputs match the chosen policy.
- [ ] Rendering one diagram in one tab does not force unrelated open tabs to rebuild.

---

## Task 16: Final Regression Pass

**Findings:** all.

**Files:**
- Modify: none unless regressions are found.

- [ ] Clean debug build.
- [ ] Smoke test dirty close/quit flows.
- [ ] Smoke test file watcher after self-save and repeated external edits.
- [ ] Smoke test find/replace in Source, Preview, and Split modes.
- [ ] Smoke test parser fixture in preview.
- [ ] Export fixture to HTML, PDF, RTF, and DOCX.
- [ ] Smoke test multi-cursor insert/delete.
- [ ] Re-run dead-code grep for removed symbols.
- [ ] Update `fable_report.md` or add a follow-up status note indicating which findings are fixed, deferred, or intentionally rejected.

**Definition Of Done:**
- Critical and High findings fixed.
- Medium findings either fixed or explicitly deferred with rationale.
- Low findings fixed where cheap and safe, otherwise tracked.
- No known text-corruption or data-loss path remains from the audit.
- Build is green.
