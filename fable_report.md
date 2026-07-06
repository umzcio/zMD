# zMD Independent Code Review — 2026-07-04

**Scope:** all 30 Swift sources in `zMD/` plus the inline JavaScript in `WebRenderer.swift` and the exported-HTML `<script>` blocks in `MarkdownParser.toHTML`. Static review only (no build/run). Prior audit documents (`CODE_REVIEW.md`, `CODE_REVIEW_2026-05-06.md`, `FOLLOWUP.md`, `docs/`) were not opened.

## Executive summary

The codebase is in noticeably better shape than a typical hobby app — CRLF normalization, fence-length tracking, slug-stable outlines, SRI-pinned CDNs, code-signing checks on auto-update, and per-document autosave timers all show careful prior work. The block-level parser genuinely is a single source of truth. But the **inline** formatting layer is not (four divergent implementations), the find/replace pipeline has a state-model hole that disables it in Source mode and a stale-range window that can corrupt text, and two lifecycle bugs (quit-without-prompt, file-watcher fd teardown) cause silent data loss / silent feature death.

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 4 |
| Medium | 13 |
| Low | 17 |

---

## 1. Bugs & correctness

### Critical

**C1. ⌘Q silently discards unsaved changes** — `zMDApp.swift:89-94`, `DocumentManager.swift:604`
The Quit menu item calls `NSApplication.shared.terminate(nil)` directly, and `AppDelegate` implements no `applicationShouldTerminate(_:)`. The app doesn't use `NSDocument`, so nothing prompts for dirty documents; `DocumentManager.hasUnsavedChanges()` exists but is **never called anywhere**. With auto-save off (the default — `UserDefaults.bool` defaults to `false`), typing for an hour and hitting ⌘Q loses everything with zero warning. Tab-close and window-close paths both prompt; quit is the one hole, and it's the most common exit path.
*Fix:* implement `applicationShouldTerminate` in `AppDelegate`, walk dirty documents (reuse `resolveDirtyClose`), return `.terminateCancel`/`.terminateLater` as appropriate.

### High

**H1. FileWatcher's stale cancel handler closes the *re-armed* watcher's file descriptor — watching dies after the first save** — `FileWatcher.swift:47-53, 58-66, 118-125`
`stopWatching()` cancels the dispatch source and closes `fileDescriptor` synchronously; the source's *cancel handler* (which runs asynchronously on main, later) then checks `if self.fileDescriptor != -1 { close(...) }`. In `restartIfFileExists()` the sequence is: cancel source A → close fd1, set −1 → `startWatching()` opens fd2 → *then* source A's deferred cancel handler runs, sees `fileDescriptor == fd2 != -1`, and **closes the brand-new fd2**, leaving source B monitoring a dead descriptor. Because `String.write(to:atomically:true)` saves via temp-file + rename, zMD's **own Cmd+S** triggers the `.rename` event → `ignoreNextChange` branch → `restartIfFileExists()` → watcher killed. After the first save of any document, external-change detection for it is silently dead (the "File Changed Externally" dialog never appears again; only the autosave mod-date guard still works).
*Fix:* close the fd only in the cancel handler (capture the fd value in the closure, not `self.fileDescriptor`), or don't close in `stopWatching()` at all.

**H2. Find navigation and Replace are dead in Source mode** — `DocumentManager.swift:1129-1145`, `ContentView.swift:35-36`, `SearchBar.swift:142/152/186/194`, `SourceEditorView.swift`
`renderedMatchCount` is set only by `MarkdownTextView`'s `onMatchCountChanged` (preview panes). `SourceEditorView` never reports a count. In pure Source mode the SearchBar therefore shows "0/0", and Next/Previous/Replace/Replace-All buttons are `.disabled(totalMatches == 0)` even while `searchMatches` is populated and matches are visibly highlighted in the editor. `nextMatch()`/`previousMatch()` also guard on `renderedMatchCount > 0`, so the menu items (enabled off `searchMatches`) are no-ops. Find & Replace's primary surface *is* Source mode (it's disabled in Preview), so the feature only fully works in Split mode.
*Fix:* drive the counter from `searchMatches.count` when no preview is present (or have SourceEditorView report counts).

**H3. Stale search ranges applied after edits → text corruption / potential crash** — `ContentView.swift:161-169`, `DocumentManager.swift:1059-1090`, `SourceEditorView.swift:478-487`
Search is re-run on `searchText`/`isRegex`/`isCaseSensitive` changes — **not on content changes**. Type into the editor while the find bar is open, then hit Replace: `replaceCurrentMatch()` calls `content.replaceSubrange(match.range, with:)` using `String.Index` values captured from the *previous* content string. Foreign indices are undefined behavior — silent corruption at wrong offsets or a trap. `SourceEditorView.applyHighlighting` has the same problem on every keystroke: `NSRange(match.range, in: text)` with indices minted from a different string (the `location+length <= storage.length` guard doesn't make the conversion itself valid). The 200 ms debounce and async regex path widen the window further.
*Fix:* re-run search on content change (or invalidate `searchMatches` in `updateContent`), and store matches as UTF-16 offsets rather than `String.Index`.

**H4. Lines mixing text and an image lose all their text — in preview and every export** — `MarkdownParser.swift:177-191, 328-336`
`isPlainText` excludes any line matching the image regex from paragraph accumulation, and the image branch appends *only* the `.image` element. For `See ![diagram](d.png) for the flow.`, the words "See" and "for the flow." vanish from the preview, HTML, PDF, RTF, DOCX, and print output. Multiple images on one line: only the first survives.
*Fix:* only take the image branch when the line is *just* an image; otherwise treat images as inline content of the paragraph (or split the line into paragraph + image elements).

### Medium

**M1. "Single source of truth" holds for blocks, not inline formatting — four divergent implementations**
- `MarkdownParser.formatInlineHTML` (HTML/PDF/RTF exports) — `MarkdownParser.swift:828-908`
- `MarkdownTextView.formatInlineMarkdown` (preview) — `MarkdownTextView.swift:1269-1328`
- `ExportManager.createRunsForFormattedText` + `formatInlineMarkdownForDOCX` (DOCX) — `ExportManager.swift:1077-1207`
- `PrintManager.formatInlineMarkdown` (print) — `PrintManager.swift:276-300`

Concrete divergence: the preview applies inline-code spans **first** and marks them with a sentinel so bold/italic skip them (the H5 fix); `formatInlineHTML` still runs bold/italic **before** code, so `` `*foo*` `` exports as `<code><em>foo</em></code>` but previews with literal asterisks. DOCX and print each have their own precedence quirks (print also runs code after italic). The README's claim is true only at block level.

**M2. HTML export corrupts inline/display math** — `ExportManager.swift:17-21`, `MarkdownParser.swift:482+`
The math pre-extraction (`extractMathFromMarkdown`) is applied only for PDF and RTF. `exportToHTML` calls `parser.toHTML(content)` directly, so `$a * b * c$` gets `<em>` woven through the LaTeX before KaTeX's client-side auto-render sees it — the export's own comment block describes exactly this failure mode but the fix wasn't applied to the HTML path.

**M3. Math extraction runs on raw markdown, lifting `$`/`$$` out of code fences (PDF/RTF)** — `ExportManager.swift:27, 40`
`\$\$([\s\S]+?)\$\$` and the inline pattern match inside fenced code blocks and inline code (e.g. a shell fence containing `PS1="$$"` or `` `echo $FOO;$BAR` ``), replacing code text with `ZMDMATHPH…` placeholders that come back as rendered-math `<img>`s inside `<pre>`. Relatedly, the preview's `applyInlineMathPattern` (`MarkdownTextView.swift:1412`) does not check the code-span sentinel, so `` `$FOO;$BAR` `` inside inline code is mangled in the preview too.

**M4. Queued KaTeX renders drop `forceLightTheme`** — `WebRenderer.swift:26, 227-230, 403-410`
`pendingKatex` stores `(latex, displayMode, completion)` — the theme flag is lost. On katexReady the queue re-dispatches via `renderMath(latex, displayMode:completion:)` with the default `forceLightTheme: false`. First PDF/RTF export after launch in dark mode (before the KaTeX web view is warm) renders light-on-transparent glyphs onto a white page — near-invisible math, the exact bug `forceLightTheme` exists to prevent.

**M5. `substituteMathPlaceholdersInHTML` semaphore/dictionary race and offline stall** — `ExportManager.swift:58-71`
`renderedImages` (a Swift `Dictionary`) is written on main inside the WebRenderer completion and read on the background export thread. The per-item `semaphore.wait(timeout: .now() + 5)` provides ordering *only when the render finishes in time*; on timeout the loop proceeds, a late completion writes concurrently with the read loop (data race → possible crash), and a late `signal()` skews every subsequent wait. Offline (CDN unreachable, KaTeX never ready) an export with N math spans stalls 5 s × N before producing math-less output.

**M6. KaTeX error path leaves `activeKatexCompletion` stale — the exact bug documented as fixed for Mermaid** — `WebRenderer.swift:343-349` vs `196-205`
The Mermaid `evaluateJavaScript` error path nils `activeMermaidCompletion` (the L1 fix comment explains why); the KaTeX error path calls `item.completion(nil)` and advances the queue but leaves `activeKatexCompletion` pointing at the failed item's closure. A late `katexResult` message then invokes it — double-completing the item, setting `isKatexRendering = false` a second time, and potentially delivering one formula's snapshot to another's cache key.

**M7. Multi-cursor insert/delete drifts cursor positions** — `EditorTextView.swift:899-986`, `MultiCursorController.swift:25-32`
Edits are applied in descending position order (correct), but each cursor's `newLocation` is computed as `original.location + insertedLen` — ignoring the shift from insertions subsequently applied at *lower* positions. Two cursors at 10 and 20, type one char: the upper cursor's true post-edit position is 22, but 21 is recorded. Each keystroke compounds the drift, so multi-cursor typing scrambles text after the first character at every cursor except the lowest. Same math error in `deleteAtAllCursors`.

**M8. Double save-prompt when closing a dirty tab** — `TabBar.swift:116-131`, `zMDApp.swift:507-536`, `DocumentManager.swift:613-647`
The tab's ✕ button shows its own Save/Don't-Save `NSAlert`, then calls `closeDocument`, which runs `resolveDirtyClose` — and if the user chose "Don't Save" (doc still dirty) they are immediately asked *again*, now with three buttons. `WindowCloseDelegate.windowShouldClose` has the identical double-prompt. Only `closeDocument` should own the dialog.

**M9. Print converts ordered lists to bullets, discarding numbers** — `PrintManager.swift:71-90, 107-111, 151-198`
The element loop carefully computes per-level counters honoring `startNumber` (the comment says "Without this, every ordered list printed as `1. 1. 1.`"), builds a `"3. item"` line — and then `appendListItem(line:)` strips the `^\d+\.\s+` marker and renders a `•` bullet unconditionally. The counter work is thrown away; ordered lists print unnumbered.

**M10. Regex-based HTML sanitizer for exported `htmlBlock`s is bypassable** — `MarkdownParser.swift:774-798`
The event-handler strip `(?i)\son[a-z]+\s*=…` requires a whitespace character before `on`, but browsers accept `/` as an attribute separator: `<div/onclick=alert(1)>` passes through into exported HTML untouched. The URL neutralizer looks for the literal `javascript:` after a quote, but browsers strip tabs/newlines inside schemes, so `href="java&#9;script:…"`-style raw attributes survive (note: markdown-link `href`s go through the stricter `sanitizeURLScheme` and are fine — this affects only raw HTML blocks). Regex sanitization of HTML is fundamentally leaky; consider escaping HTML blocks in exports (as DOCX does) or gating on an allowlist parse.

**M11. DOCX export can beach-ball the main thread** — `ExportManager.swift:393-401, 1242-1256`
The whole `createCustomDOCX` (image loading, XML generation, `/usr/bin/zip` spawn) runs on main, and the zip wait is a `DispatchGroup.wait` on main of up to 30 s. PDF/RTF got the background-queue treatment; DOCX didn't.

**M12. Preview blockquotes skip inline formatting; exports apply it** — `MarkdownTextView.swift:917` vs `MarkdownParser.swift:760`
`appendBlockquote` appends raw text, so `> **important**` shows literal asterisks in the preview but real bold in HTML/PDF/RTF. Another preview/export divergence.

**M13. Rendered-match index vs. source-match index mismatch** — `DocumentManager.swift:1059-1065, 1129-1137`
`currentMatchIndex` is advanced modulo `renderedMatchCount` (matches in the *rendered* text, where markdown syntax is stripped) but `replaceCurrentMatch` indexes into `searchMatches` (matches in the *source*, where a query can also hit `**`-adjacent syntax or fence info strings). When the two counts differ, Replace acts on a different occurrence than the one highlighted orange in the preview.

### Low (bugs)

| # | Finding | Location |
|---|---|---|
| L1 | `fileName.replacingOccurrences(of: ".md", with: ".pdf")` replaces anywhere in the name, not just the suffix (`my.md.notes.md` → `my.pdf.notes.pdf`) | `ExportManager.swift:165,315,336,387` |
| L2 | `scrollToHeading`'s `asyncAfter(0.5)` re-applies a captured `NSRange` that can exceed storage length if the doc was rebuilt shorter in the interim — `setSelectedRange` raises on invalid range | `MarkdownTextView.swift:288-291` |
| L3 | Failed remote-image loads re-download on *every* rebuild (each keystroke) — no in-flight/negative-result tracking | `MarkdownTextView.swift:1071-1081` |
| L4 | `loadDocument` dedups by exact `URL` equality; the same file via symlink or different case opens twice (canonicalKey exists but isn't used here) | `DocumentManager.swift:200` |
| L5 | `closeOtherDocuments` doesn't clear `secondaryDocumentId`/`isSplitViewActive` when the secondary is among the closed tabs — stale split state | `DocumentManager.swift:689-725` |
| L6 | DOCX `ilvl` can be 2 but `numbering.xml` defines only levels 0–1 per abstractNum — undefined numbering level referenced | `ExportManager.swift:837, 588-632` |
| L7 | DOCX table header cells (`createHeaderCellRun`) skip inline formatting; `**bold**` shows literally | `ExportManager.swift:947-948, 1073-1075` |
| L8 | DOCX runs never handle `~~strikethrough~~` (renders literally); task-list `[ ]`/`[x]` also literal, diverging from preview/HTML checkboxes | `ExportManager.swift:1083, 827-838` |
| L9 | RTF export doesn't call `absolutizeImageSrcs` (PDF does) — relative images silently missing from RTF | `ExportManager.swift:344-348` vs `179` |
| L10 | PDF export sets `NSGraphicsContext.current` and never restores it | `ExportManager.swift:232` |
| L11 | `sanitizeURLScheme` allows `data:image/*` including `image/svg+xml` — an SVG `href` navigated in a browser can execute script | `MarkdownParser.swift:818-821` |
| L12 | `webView.setValue(false, forKey: "drawsBackground")` — private KVC key; raises if Apple removes it | `WebRenderer.swift:252` |
| L13 | `noteSelfWrite` uses `url.path.hasPrefix(folder.path)` — sibling-prefix false match (`/a/notes` vs `/a/notes-x`); the codebase fixed this exact pattern elsewhere (trailing-slash form in the S3 fix) | `FolderManager.swift:32` |
| L14 | Minimap builds an unbounded CGBitmap (2 px/line × 4 B × 80 px); a 1 M-line file allocates ~640 MB | `MinimapView.swift:42-68` |
| L15 | Code-block text is highlighted at fixed 13 pt while the block's borders scale with zoom — zooming scales the frame but not the code | `SyntaxHighlighter.swift:100`, `MarkdownTextView.swift:849` |
| L16 | ⌘G / ⇧⌘G bound both in the Edit menu and on SearchBar buttons — duplicate key-equivalents | `zMDApp.swift:377-387`, `SearchBar.swift:143,153` |
| L17 | Quick Open bold-highlights matched characters using `Character`-count indices as UTF-16 `NSRange` locations — wrong glyphs highlighted (or split surrogate pairs) for non-BMP names | `QuickOpenView.swift:391-399`, `FuzzyMatcher.swift` |

---

## 2. Dead code inventory

Safe-to-remove candidates, with confidence:

| Symbol | Location | Confidence | Notes |
|---|---|---|---|
| `Element.textContent` | `MarkdownParser.swift:74-99` | High | No callers (the grep hit at :510 is JS `textContent`). |
| `Element.headingLevel` | `MarkdownParser.swift:110-120` | High | No callers (`isHeading` is used once; keep that). |
| `trimmed.count == level` clause | `MarkdownParser.swift:1038` | High | Logically unreachable — when it's true, `headingBody.isEmpty` already failed the conjunction. |
| `FolderManager.refreshFileTree()` (sync variant) | `FolderManager.swift:140-143` | High | Only the async variant is called. |
| `FileWatcher.pause()` / `resume()` / `isPaused` | `FileWatcher.swift:68-76, 15-16, 81` | High | Never called (the `.resume()` grep hits are dispatch sources / URLSession). |
| `MarkdownTextView.defaultParagraphStyle()` | `MarkdownTextView.swift:1479-1484` | High | No callers. Also the empty `// MARK: - Search Highlighting` section at :1475. |
| `MarkdownTextView.searchMatches` property + init param | `MarkdownTextView.swift:12, 33` | High | Stored, never read — the view computes its own `matchRanges`. Callers pass it for nothing. |
| `EditorTextView.htmlPrefixStart` + its `deleteBackward` branch | `EditorTextView.swift:36, 484-489` | High | Only ever assigned `nil`; the `if let start =` branch is unreachable. Looks like an unfinished HTML-autocomplete feature. |
| `let nsContent` / `_ = nsContent` | `DocumentManager.swift:1076, 1080` | High | Dead local + dead statement in `replaceCurrentMatch`. Also the odd `as NSRange?` cast at :1075. |
| `QuickOpenMode` enum + `QuickOpenNSView.mode` | `QuickOpenView.swift:32-35, 60, 221, 226` | High | `mode` is written, never read. |
| `SearchBar.onSearch` | `SearchBar.swift:8` | High | Both call sites pass `{ }`; never invoked in `body`. |
| `DocumentManager.hasUnsavedChanges()` | `DocumentManager.swift:604-606` | High (uncalled) | **Don't delete — wire it into a quit handler (finding C1).** |
| `AppDelegate.handleGetURLEvent` + its registration | `zMDApp.swift:465-473, 486-499` | Medium | `application(_:open:)` handles Finder opens; a GetURL-style string handler for `kAEOpenDocuments` (whose params are file aliases, not URL strings) likely never fires usefully. Verify with a Finder-open test before removing. |
| `EditorTextView.keyDown` branches for ⌘B/⌘I/⇧⌘X/⇧⌘K/⇧⌘L | `EditorTextView.swift:185-213` | Medium | Main-menu key equivalents intercept these before `keyDown`; branches are probably unreachable. Harmless to keep. |
| `extractListItemText` final fallback return | `MarkdownParser.swift:418` | Low | Unreachable given the `isListLine` guard at all call sites, but reasonable defense. Keep. |
| `_zmdNoop` | `WebRenderer.swift:8` | N/A | Deliberately retained per its comment; fine. |

No leftover `print()` debug statements, no TODO/FIXME markers, no commented-out code blocks found.

---

## 3. Code quality / maintainability

- **Four inline-formatting engines** (M1) is the biggest maintainability liability: every new inline feature (e.g. `==highlight==`, which `AutocompleteView.swift:24` already offers as a snippet but *no renderer supports*) must be implemented four times. Extract a single inline tokenizer that emits spans, with per-backend emitters.
- **Underscore emphasis (`_em_`, `__strong__`) is unsupported everywhere** — consistent, but worth documenting; users will hit it immediately.
- **Tables treat row 0 as a header even without a separator row** and always emit `<th>` — a divergence from GFM that affects all backends (`MarkdownParser.swift:733-735`, `MarkdownTextView.swift:935`).
- **HTML export flattens nested lists into a single `<ol>`/`<ul>`** with `margin-left` styling, so nested ordered lists number sequentially through all levels — the preview renders per-level counters (`MarkdownParser.swift:691-714` vs `MarkdownTextView.swift:713-755`). One more preview/export divergence.
- `ExportManager` keeps DOCX generation state (`hyperlinkRelationships`, `numberedListCount`, …) as mutable singleton properties — safe today because everything is main-thread, but fragile; two overlapping exports would corrupt relationships. Consider a per-export context struct.
- `Coordinator.diagramDidRender` observers register with `object: nil`, so *every* open tab's preview does a full rebuild whenever *any* diagram anywhere renders (`MarkdownTextView.swift:83-88`).
- Duplicated scroll-sync coordinator code between `MarkdownTextView.Coordinator` and `SourceEditorView.Coordinator` (`scrollToPercent`, debounce timers, programmatic-scroll flags) could share a helper.
- Comment quality is genuinely good — but many comments narrate fix history ("previously…", "C7:", "H16:") rather than current invariants; over time these become archaeology. Consider trimming to the invariant.

---

## 4. Security / robustness

Covered above as findings: M10 (sanitizer bypass in exported HTML), L11 (`data:image/svg+xml` hrefs), M5 (semaphore race), L13 (prefix match). Additional notes:

- **JS injection surface into the hidden WebViews is handled well** overall: Mermaid escapes `` ` ``, `\`, `${`, `\n`; KaTeX escapes `\`, `'`, `\n`. Neither escapes a raw `\r` (possible only via display-math bodies from CR-only files that bypassed `splitLines`, since `extractMathFromMarkdown` reads *raw* markdown) — worst case is a JS syntax error → graceful nil completion. Worth normalizing anyway.
- **Path traversal:** relative-`.md`-link confinement in the preview (`MarkdownTextView.swift:322-327`) is done correctly with the trailing-slash prefix check. However, `loadImage` (`MarkdownTextView.swift:1103-1110`) and DOCX `createImageParagraph` resolve *absolute* image paths anywhere on disk — a shared markdown file can render `/Users/<you>/…` files into an export you then send onward. In an un-sandboxed viewer that's arguably by design, but it's a nice exfil primitive to be aware of.
- **Auto-updater** is notably solid: HTTPS-only guard, strict `SecStaticCodeCheckValidity`, Team-ID pinning against the running bundle, per-user temp log. The remaining gap is that `hdiutil attach` of an unverified DMG happens *before* signature verification — DMG parsing itself is attack surface — but that requires a compromised release URL to matter.
- `/usr/bin/zip` and `/usr/bin/hdiutil` are invoked by absolute path (good).

---

## 5. What I could not verify statically (and what I'd test with a running app)

1. **Build state** — I did not compile; line numbers assume current working tree.
2. **FileWatcher fd teardown (H1)** — reasoned from GCD cancel-handler semantics; I'd verify by saving a watched file, then editing it externally and confirming the dialog never appears (and `lsof` shows the closed fd).
3. **Multi-cursor drift (M7)** — the arithmetic is wrong on paper; I'd confirm with two ⌘-click cursors + typing.
4. **Find/Replace in pure Source mode (H2)** — confirm buttons are disabled with visible highlights.
5. **Menu vs. `keyDown` shortcut double-dispatch** in `EditorTextView` — depends on responder-chain timing.
6. **Whether the duplicate ⌘G bindings (L16) conflict** in practice.
7. **First-dark-mode-export math visibility (M4)** — needs a cold app start offline/slow-CDN in dark mode.
8. **NSTextTable rendering, PDF pagination fidelity, and `takeSnapshot` behavior for offscreen WKWebViews** — all runtime-only.
9. **`handleGetURLEvent` reachability** (dead-code inventory, medium confidence) — needs a Finder-open trace.

If I could run one test suite, it would target the parser and the four inline formatters with a shared fixture set (code spans containing `*`/`$`, images inline with text, `$$` inside fences, nested ordered lists, blockquote inline formatting) — that single fixture file would surface most of the divergence findings (M1–M3, M12, H4) as visible diffs across preview/HTML/PDF/DOCX/print.
