# zMD Code Review Report

**Date:** 2026-05-06
**Scope:** 33 Swift files, 12,308 lines (full app target)
**Method:** Read-only audit. 6 specialized parallel subagents, each finding evidence-cited; orchestrator deduplicated, cross-referenced, and prioritized.

---

## Executive Summary

- **Total findings:** 51 verified (Critical: 5, High: 13, Medium: 17, Low: 16)
- **Codebase health:** Solid for a single-developer macOS app. The "single source of truth parser" claim in the README is accurate post-v2.5 — every export, the print pipeline, the preview, the outline, and Quick Open all consume `MarkdownParser.shared.parse()`. Zero `TODO`/`FIXME`/`HACK` comments, no `public` API leakage, only three confirmed dead symbols. Most remaining issues are concentrated in three areas: (a) `UpdateManager` (auto-update has both a security and a main-thread issue), (b) HTML/PDF export (XSS surface and pagination/escape gaps), and (c) the find-and-replace plumbing (typing in the find bar doesn't actually drive the matcher used by Replace).

### Top 3 things to fix this week

1. **UpdateManager auto-replaces `/Applications/zMD.app` with no signature/checksum check.** A compromised release asset, a release-name collision, or future TLS issue silently swaps the user's app for an arbitrary binary that auto-launches. (Critical #1)
2. **HTML export emits user-controlled `htmlBlock` content unescaped + accepts `javascript:` URLs in markdown links.** Opening an exported HTML in a browser executes arbitrary script. PDF and RTF exports inherit because they route through the same `toHTML`. (Critical #2, #3)
3. **External-change dialog has no dirty-state check.** "Reload" wins over local edits silently. Real data-loss path triggered by `git pull` while a doc is open and unsaved. (Critical #4)

---

## Critical Findings

### C1. Auto-update installs unverified app bundle from network

- **Location:** `zMD/UpdateManager.swift:107-218`
- **Code:**
  ```swift
  let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
      ...
      self.installFromDMG(at: tempURL)
  }
  ...
  if fileManager.fileExists(atPath: destURL.path) {
      try fileManager.removeItem(at: destURL)
  }
  try fileManager.copyItem(at: appURL, to: destURL)
  ```
- **Why it's a bug:** The DMG is fetched from `browser_download_url` parsed out of the GitHub releases JSON, mounted via `hdiutil`, and the `.app` is copied unconditionally over `/Applications/zMD.app`. There is no `codesign --verify`, no notarization check, no SHA/checksum compare against release notes, and no Team-ID match. A compromised GitHub release token, a release-name spoof, or any future TLS MitM lets an attacker silently replace the user's app with an arbitrary binary that auto-launches via `open -n`.
- **Fix:** Before copying, run `SecCodeCheckValidity` (or shell `codesign --verify --deep --strict`) on the unpacked `.app` and require the same Team ID as the running bundle. Optional: pin asset SHA in release notes and verify before copy.
- **Effort:** M

### C2. HTML / PDF / RTF export passes user-controlled `htmlBlock` content unescaped

- **Location:** `zMD/MarkdownParser.swift:674-675`, `zMD/ExportManager.swift:25, 38, 163-180`
- **Code:**
  ```swift
  case .htmlBlock(let html):
      return html + "\n"
  ```
- **Why it's a bug:** Any HTML block in the user's markdown — including a `<details ontoggle="…">` or `<a href="javascript:…">` or attribute-injected `<img onerror="…">` — flows verbatim into the exported HTML. PDF/RTF exports route through the same `parser.toHTML()` and then through `NSAttributedString(html:)`, which executes `<script>` tags and follows `javascript:` URLs during layout. A user-shared markdown file becomes a code-execution vector when re-exported by the recipient.
- **Fix:** Sanitize `htmlBlock` content against a strict allowlist (no event-handler attributes, no `javascript:`/`data:` URLs except `data:image/*`). Reject disallowed tags or escape the entire block as a fallback.
- **Effort:** M

### C3. Markdown link URL scheme is not validated → `javascript:` execution in exported HTML

- **Location:** `zMD/MarkdownParser.swift:707-711`
- **Code:**
  ```swift
  result = result.replacingOccurrences(
      of: #"\[([^\]]+)\]\(([^\)]+)\)"#,
      with: "<a href=\"$2\">$1</a>",
      options: .regularExpression
  )
  ```
- **Why it's a bug:** The URL captured by `$2` is inserted into the `href` after `escapeHTML`, which only escapes the five HTML metacharacters — it does not validate scheme. A markdown link `[click](javascript:alert(1))` produces `<a href="javascript:alert(1)">click</a>`. Click in the exported HTML executes JS. Same applies to `data:text/html;base64,…` URLs.
- **Fix:** Allowlist URL schemes (`http`, `https`, `mailto`, `#`, relative paths). Reject `javascript:` and `data:*` (except `data:image/*` for images).
- **Effort:** S

### C4. External-change dialog has no dirty-state warning → silent loss of unsaved edits

- **Location:** `zMD/DocumentManager.swift:942-966`, `zMD/AlertManager.swift:55-80`
- **Code:**
  ```swift
  func fileWatcher(_ watcher: FileWatcher, fileDidChange url: URL) {
      ...
      let action = alertManager.showFileChangedDialog(fileName: url.lastPathComponent)
      switch action {
      case .reload:
          reloadDocument(document)
  ```
  Dialog text: `"\"\(fileName)\" has been modified by another application. Do you want to reload it?"`
- **Why it's a bug:** If `document.isDirty == true` and the user clicks "Reload", `reloadDocument` replaces `openDocuments[index]` with the on-disk content; the user's unsaved local edits are gone with no recovery path. **Repro:** open a file in zMD, edit without saving, run `git pull` in another terminal, dialog appears, click "Reload" expecting your work to merge — it's gone.
- **Fix:** Pass `isDirty` to `showFileChangedDialog`. When dirty, change the message to "Your unsaved changes will be lost. Reload anyway?" and add a "Save As…" button.
- **Effort:** S

### C5. Auto-update DMG install blocks the main thread for several seconds

- **Location:** `zMD/UpdateManager.swift:117-162`
- **Code:**
  ```swift
  let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
  let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
      DispatchQueue.main.async {
          ...
          self.installFromDMG(at: tempURL)
      }
  }
  // installFromDMG on main:
  try mountProcess.run()
  mountProcess.waitUntilExit()
  ...
  try fileManager.copyItem(at: appURL, to: destURL)
  ```
- **Why it's a bug:** `installFromDMG` runs `hdiutil attach`, `waitUntilExit()`, plist parsing via `readDataToEndOfFile()`, the `/Applications` copy, and `hdiutil detach` — all on the main queue. UI freezes for the entire install, the watchdog can kill the process, and `AlertManager.shared.showError` calls inside the function `runModal` mid-blocked-thread.
- **Fix:** Move the entire install body to `DispatchQueue.global(qos: .userInitiated).async`; only hop back to main for the user-prompt at the end.
- **Effort:** S

---

## High-Severity Findings

### H1. `autoSaveTimer` is a single shared instance — closing one tab kills another's pending save

- **Location:** `zMD/DocumentManager.swift:39, 411-420, 558-559, 613-614`; `saveCurrentDocument` at `:501-504` does not cancel either
- **Code:**
  ```swift
  private var autoSaveTimer: Timer?       // single timer for ALL docs
  ...
  // updateContent (per doc):
  autoSaveTimer?.invalidate()
  autoSaveTimer = Timer.scheduledTimer(withTimeInterval: Timing.autoSaveDebounce, repeats: false) { [weak self] _ in
      self.saveDocument(id: documentId)
  }
  ...
  // closeDocument:
  autoSaveTimer?.invalidate()
  ```
- **Why it's a bug:** Three connected problems with a shared timer:
  1. Type in tab A → 2s debounce. Close tab B before that elapses → A's pending save is wiped.
  2. Type in tab A then immediately tab B → A's pending save is wiped.
  3. Cmd+S during the 2s window → `saveDocument` writes; the still-armed timer fires 2s later and writes again (clobbering any intermediate undo).
- **Fix:** Convert to `[UUID: Timer]` keyed by document id, mirroring `fileWatchers`. `saveDocument(id:)` should also invalidate that doc's timer at entry.
- **Effort:** S

### H2. `WebRenderer` pending-render queue stalls forever on CDN failure

- **Location:** `zMD/WebRenderer.swift:53-59, 194-201, 386-389`
- **Code:**
  ```swift
  if !mermaidReady {
      pendingMermaid.append((code, completion))
      setupMermaidWebView()
      return
  }
  ...
  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      // Silently handle navigation failures
  }
  ```
- **Why it's a bug:** Mermaid/KaTeX scripts load from a CDN. Offline or with a 4xx, the WebView never posts `mermaidReady`/`katexReady`. Every render call piles into `pendingMermaid` forever — placeholder text "Rendering diagram..." is permanent, and the pending array grows per re-parse / keystroke.
- **Fix:** In `didFail`/`didFailProvisionalNavigation`, drain pending arrays with `nil` and reset `*Ready` flags. Add a load timeout (e.g. 10 s) that fails pending work the same way.
- **Effort:** M

### H3. Search clears every `.backgroundColor` — wipes inline-code, code-block, and table cell shading

- **Location:** `zMD/MarkdownTextView.swift:147-150` (also `:396-397`)
- **Code:**
  ```swift
  if let storage = textView.textStorage {
      storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
  }
  ```
- **Why it's a bug:** The lightweight search-update path strips `.backgroundColor` from the entire text storage. But `.backgroundColor` is also legitimately used by `appendCodeBlock` (line 777), inline code (`formatInlineMarkdown:1137`), and tables. After typing into the find bar and clearing it, all those backgrounds are gone until the next full rebuild. Repro: open a doc with inline code, press ⌘F, type a letter, press Esc — backgrounds are gone.
- **Fix:** Track ranges actually highlighted by search and remove only those, or use `addTemporaryAttribute` (layout manager) for search highlights so persistent attributes are untouched.
- **Effort:** M

### H4. Element cache key omits dark-mode appearance — stale code-block visuals on theme toggle

- **Location:** `zMD/MarkdownTextView.swift:489-493, 748-751, 1063-1065`
- **Code:**
  ```swift
  let zoomKey = "\(zoomLevel)-\(fontStyle.rawValue)"
  let cacheValid = coordinator.lastZoomKey == zoomKey
  ...
  let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  let codeBackground = isDarkMode
      ? NSColor(calibratedWhite: 0.12, alpha: 1.0)
      : NSColor(calibratedWhite: 0.95, alpha: 1.0)
  ```
- **Why it's a bug:** Code-block and HTML-block renderers bake resolved RGB into the cached attributed-string fragment. Toggling system theme while a doc is open serves stale colors from the cache; only a content edit busts cache. Headings using semantic NSColors auto-adapt, masking the issue.
- **Fix:** Include `isDark` in `lastZoomKey` and observe appearance change. Or use `NSColor(name:dynamicProvider:)` so colors resolve at draw time.
- **Effort:** S

### H5. Inline code regex preserves `**`/`*`/`~~` markers as literal content; later passes match inside what was a code span

- **Location:** Preview: `zMD/MarkdownTextView.swift:1132-1144`. HTML export: `zMD/MarkdownParser.swift:682-720`. DOCX export shares same surface at `zMD/ExportManager.swift:875`.
- **Code (preview):**
  ```swift
  applyPattern(#"`(.+?)`"#, to: result, attributes: [...])
  applyPattern(#"\*\*(.+?)\*\*"#, to: result, attributes: [.font: baseFont.withWeight(.bold)])
  ```
- **Why it's a bug:** Although inline code runs first, `applyPattern` only swaps run-attributes — the asterisks inside the original span survive as plain text. The next bold pass happily matches them. Render `` `**foo**` `` and `foo` becomes bold-monospace; the comment promising "atomic in CommonMark — `*x*` inside a code span is literal asterisks" is violated.
- **Fix:** Tag code-span ranges with a sentinel attribute on the first pass; subsequent patterns skip ranges carrying it. Or temporarily substitute markers with private-use codepoints, restore at end.
- **Effort:** M

### H6. Multi-paragraph blockquote breaks on internal blank/bare-`>` lines

- **Location:** `zMD/MarkdownParser.swift:260-267`
- **Code:**
  ```swift
  else if line.hasPrefix("> ") {
      var quoteLines: [String] = []
      while i < lines.count && lines[i].hasPrefix("> ") {
          quoteLines.append(String(lines[i].dropFirst(2)))
          i += 1
      }
      ...
  }
  ```
- **Why it's a bug:** Continuation predicate is `hasPrefix("> ")`, so a CommonMark "lazy" line of `>` alone (used to separate paragraphs inside the same blockquote) ends the block. Indented `  > x` is not matched at all.
- **Fix:** Use `trimmedLine.hasPrefix(">")`, treat bare `>` as soft break inside the quote.
- **Effort:** S

### H7. Per-keystroke file-watcher pause without auto-save = no external-change detection

- **Location:** `zMD/DocumentManager.swift:407, 411-420, 423-499`
- **Code:**
  ```swift
  // Pause file watcher during editing
  fileWatchers[documentId]?.pause()
  // Schedule auto-save if enabled (skip for untitled files)
  if autoSaveEnabled && !(openDocuments[index].isUntitled) {
      ...
  }
  ```
- **Why it's a bug:** `updateContent` always pauses the watcher. Watcher is only resumed inside `saveDocument` (line 474/493). With auto-save disabled and the user not pressing Cmd+S, the watcher stays paused after the first keystroke — external file changes never prompt.
- **Fix:** Drop the per-keystroke pause; the existing `ignoreNextChange` flag already debounces self-writes. If pause is truly needed, time-bound it (e.g., resume after 5 s of no edits).
- **Effort:** S

### H8. `saveDocument` save-panel cancel path provides no feedback on save failure

- **Location:** `zMD/DocumentManager.swift:485-497`
- **Code:**
  ```swift
  savePanel.begin { [weak self] response in
      guard response == .OK, let newURL = savePanel.url else { return }
      ...
  ```
- **Why it's a bug:** When the inner write throws, the code falls back to NSSavePanel. If the user cancels — they often will, not understanding why they're being prompted — the function returns silently with `isDirty = true`, no toast, no alert. The user thinks Cmd+S succeeded.
- **Fix:** In the cancellation branch, surface a toast or alert: "Save did not complete — your changes are still unsaved."
- **Effort:** S

### H9. Replace operations use stale/empty `searchMatches` because typing doesn't trigger `performSearch`

- **Location:** `zMD/DocumentManager.swift:840-918`, `zMD/SearchBar.swift:88-94`, `zMD/ContentView.swift:32-61`
- **Code:**
  ```swift
  // SearchBar — only `onSubmit` (Enter) calls onNext; no onChange triggers performSearch
  TextField("Find", text: $searchText)
      .onSubmit { onNext() }

  // DocumentManager.replaceCurrentMatch
  guard ...!searchMatches.isEmpty,
        currentMatchIndex < searchMatches.count else { return }
  ```
- **Why it's a bug:** `performSearch()` is only called on regex/case toggles and from inside `replaceCurrentMatch`/`replaceAllMatches`. There is **no** `.onChange(of: searchText)` anywhere. So when the user types `foo` and clicks **Replace**, `searchMatches` is empty (or stale from a prior session) and the guard returns silently. If stale, the replacement applies at out-of-date character offsets, corrupting the document. Preview highlights work because they have a separate `MarkdownTextView.findMatchRanges` matcher — those highlights are not what Replace uses.
- **Fix:** Add `.onChange(of: documentManager.searchText) { _ in documentManager.performSearch() }` (also on `isRegexSearch`, `isCaseSensitive`, document content) in ContentView.
- **Effort:** S

### H10. Find bar in source mode does not highlight or update `searchMatches`

- **Location:** `zMD/SourceEditorView.swift` (no `searchText` parameter); `zMD/ContentView.swift:540-665`
- **Why it's a bug:** When `viewMode == .source`, the find bar is shown but `SourceEditorView` never receives `searchText`. There is no source-side analog of `MarkdownTextView.findMatchRanges`, so users typing in the find bar see nothing in the editor and (combined with H9) Replace also does nothing. In split view the preview pane works, the editor pane does not.
- **Fix:** Pass `searchText`/`isRegexSearch`/`isCaseSensitive`/`currentMatchIndex` into `SourceEditorView`. Run a matcher on each `updateNSView` and apply `.backgroundColor` highlighting on the `NSTextStorage`. Update `documentManager.searchMatches` from there.
- **Effort:** M

### H11. Empty-list-item Enter-to-stop never fires

- **Location:** `zMD/EditorTextView.swift:299-361`
- **Code:**
  ```swift
  let trimmedLine = currentLine.trimmingCharacters(in: .whitespaces)
  ...
  let listPatterns: [(pattern: String, continuation: (String) -> String?)] = [
      ...
      (#"^[-*+] $"#, { _ in nil }),     // empty unordered (would-be stop)
      (#"^- \[[ xX]\] $"#, { _ in nil }),
      (#"^\d+\. $"#, { _ in nil }),
  ]
  ```
- **Why it's a bug:** `currentLine` for an empty item is `"- "`; `trimmingCharacters(in: .whitespaces)` strips the trailing space → `"-"`. The "stop" patterns require a literal trailing space, so they never match. The "continue" patterns require `(.+)` content, also absent. Pressing Enter falls through to default auto-indent, leaving an orphaned bullet. Repro: type `- `, press Enter — bullet preserved. Press Enter again. Forever.
- **Fix:** Match against `currentLine` without trimming the trailing whitespace, using `^[-*+]\s*$` patterns.
- **Effort:** S

### H12. Autocomplete popup does not dismiss when cursor moves out of trigger range — silent wrong-text insertion

- **Location:** `zMD/EditorTextView.swift:130-235`, `zMD/SourceEditorView.swift:303-332`
- **Why it's a bug:** Left/Right arrow, Cmd+arrow, click in another line — none of these dismiss the popup; only Up/Down/Enter/Escape are intercepted. Pressing Enter then runs `confirmSelection()` which calls `replaceCharacters(in: triggerRange, ...)` at the *old* location — silently rewriting unrelated text. Repro: type `code`, popup appears, press Left arrow once, press Enter. Replacement inserted at original word location, mutilating text under the cursor.
- **Fix:** In `textViewDidChangeSelection`, dismiss the popup if the new caret falls outside `triggerRange.location ... triggerRange.location + extraTypedChars`. Or set an `isInsertingFromAutocomplete` sentinel and dismiss on any selection change not driven by the typing path.
- **Effort:** S

### H13. PDF pagination splits content mid-line

- **Location:** `zMD/ExportManager.swift:88-117`
- **Code:**
  ```swift
  var currentY: CGFloat = 0
  let pageHeight = textRect.height
  while currentY < usedRect.height {
      ...
      let drawRect = NSRect(
          x: textRect.minX,
          y: textRect.minY - currentY,
          ...)
      attributedString.draw(in: drawRect)
      ...
      currentY += pageHeight
  }
  ```
- **Why it's a bug:** Pages advance by a fixed `pageHeight` increment, ignoring glyph geometry. Lines straddling page boundaries get clipped — top half on page N, bottom half on N+1. The CSS `page-break-inside: avoid` on `<pre>`/`<tr>` is ignored because `NSAttributedString(html:)` doesn't honor `@page`/`page-break-*` rules.
- **Fix:** Use `NSLayoutManager.lineFragmentRect(forGlyphAt:)` to find the largest line break ≤ `currentY + pageHeight` and advance `currentY` to that boundary.
- **Effort:** M

### H14. PDF / RTF export routes through `NSAttributedString(html:)` which fetches network resources synchronously on main thread

- **Location:** `zMD/ExportManager.swift:38, 170-180`
- **Code:**
  ```swift
  guard let attributedString = NSAttributedString(html: htmlData, options: options, documentAttributes: nil) else { ... }
  ```
- **Why it's a bug:** `NSAttributedString(html:)` is a WebKit-driven legacy initializer that synchronously executes the HTML, including downloading remote `<img src>` and `<script src>` (the CDN scripts injected when a doc has Mermaid/math). On the main thread, this can hang for seconds; offline it can hang for the timeout of every external resource.
- **Fix:** Strip `<script>`/`<link>` (and remote `<img>`) from the HTML before calling `NSAttributedString(html:)` for PDF/RTF — KaTeX/Mermaid won't run anyway. Or pre-rasterize.
- **Effort:** S

### H15. Native print always renders black-on-white regardless of system dark mode

- **Location:** `zMD/PrintManager.swift:54-57, 109, 126, 171, 192, 231`
- **Code:**
  ```swift
  let defaultAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.black
  ]
  ```
- **Why it's a bug:** `.foregroundColor: NSColor.black` everywhere with no background fill. On paper that's right, but in the macOS print-preview dialog (dark UI) `lightGray.withAlphaComponent(0.2)` table/code backgrounds become nearly invisible. Accessibility settings (Increase Contrast) are ignored because no semantic colors are used.
- **Fix:** Either use `.labelColor` (preview-friendly) or explicitly set white `.backgroundColor` on the paragraph style so paper rendering is consistent.
- **Effort:** S

### H16. `displayMath` HTML emits `$$ + escapeHTML(latex) + $$` — KaTeX renders entities literally

- **Location:** `zMD/MarkdownParser.swift:654-655`
- **Code:**
  ```swift
  case .displayMath(let latex):
      return "<div class=\"math-display\">$$\(escapeHTML(latex))$$</div>\n"
  ```
- **Why it's a bug:** Math containing `<`, `>`, or `&` (very common: `a < b`, `\&`) gets escaped to entities, which KaTeX parses as literal entity strings, not `<` etc. The rendered formula is broken.
- **Fix:** Wrap math in `<script type="math/tex; mode=display">…</script>` (browsers don't parse content as HTML inside that), or render KaTeX server-side at export time.
- **Effort:** M

### H17. DOCX image lookup uses absolute path before relative — wrong fallback for `images/foo.png`

- **Location:** `zMD/ExportManager.swift:800-811`
- **Code:**
  ```swift
  let absoluteURL = URL(fileURLWithPath: path)
  if FileManager.default.fileExists(atPath: absoluteURL.path) {
      resolvedURL = absoluteURL
  } else if let base = baseURL?.deletingLastPathComponent() {
      let relativeURL = base.appendingPathComponent(path)
  ```
- **Why it's a bug:** `URL(fileURLWithPath: "images/foo.png")` produces a file URL relative to the *process working directory* (typically `/`), so `fileExists("/images/foo.png")` can spuriously hit. Also: percent-encoded paths aren't decoded; an unsaved-doc `baseURL == nil` makes relative images fail silently.
- **Fix:** Treat `path` as relative unless it has a leading `/` or a scheme. Percent-decode. Fall back to `baseURL?.deletingLastPathComponent()` for relative paths.
- **Effort:** S

---

## Medium-Severity Findings

### M1. Outline / parser heading desync with nested fences of different lengths
- `zMD/MarkdownParser.swift:788-792` (extractHeadings) vs `:237-251` (parse). `parse()` honors fence width; `extractHeadings` toggles on any line starting with three backticks. With `` ```` ``-fenced blocks containing `` ``` ``, the outline emits a phantom heading and `MarkdownTextView.buildAttributedString` pairs `parsedHeadingIndex` with the wrong slug. Fix: mirror open-length tracking. **Effort: S.**

### M2. Mermaid/KaTeX async-render race forces N full rebuilds for N diagrams
- `zMD/WebRenderer.swift:166-181`, `zMD/MarkdownTextView.swift:412-416`. Every per-diagram completion posts `diagramRendered`, and `Coordinator.diagramDidRender()` clears all of `lastContent` + `elementCache`. N diagrams → N full re-parses + N text-storage replacements during initial open; observable as a flickery progressive render. Fix: coalesce notifications via debounce, or splice the rendered image into the cached element's range. **Effort: M.**

### M3. Inline math runs LAST in `formatInlineMarkdown` — bold/italic mangle math content
- `zMD/MarkdownTextView.swift:1218-1255`. `applyInlineMathPattern` runs after bold/italic/strike/link, so `$a^{**}$` already has `**` consumed by bold. Fix: move math right after inline code, before bold. Same sentinel mechanism as H5. **Effort: S.**

### M4. `extractHeadings` doesn't track HTML-block context — produces phantom outline entries
- `zMD/MarkdownParser.swift:784-816`. An HTML block containing `# X` on its own line is emitted as a heading by `extractHeadings` while `parse()` swallows it. Pairing in `buildAttributedString` drifts. Fix: track HTML balance same way as fences, or rebase `extractHeadings` over `parse()` output. **Effort: S.**

### M5. Regex search runs synchronously on main thread with no timeout
- `zMD/DocumentManager.swift:856-867`, `zMD/MarkdownTextView.swift:320-327`. Pattern like `(a+)+b` against 1MB doc wedges `NSRegularExpression` for tens of seconds. Combined with the H9 fix (live search), each keystroke could freeze. Fix: run regex on background queue, debounce 200ms, cap result count. **Effort: M.**

### M6. Regex find-and-replace ignores capture-group backreferences
- `zMD/DocumentManager.swift:891-918`. `replaceText` is inserted verbatim regardless of regex mode; `\1`/`$1` end up as literal characters. Fix: when `isRegexSearch`, use `regex.stringByReplacingMatches(in:options:range:withTemplate:)`. **Effort: S.**

### M7. Drag-and-drop has no upper bound and silently drops non-markdown files / folders
- `zMD/ContentView.swift:194-206`. Dropping a folder is rejected by extension check (no recursion); dropping 5,000 `.md` files opens 5,000 tabs; non-md drops give zero feedback. Fix: cap to N files (warn over cap), recurse into folders, toast skipped count. **Effort: S.**

### M8. Save fires per-file watcher AND directory watcher → tree rebuild on every save
- `zMD/DocumentManager.swift:472-474` (per-file `ignoreNextChange = true`) vs `zMD/FolderManager.swift:64-67`. Auto-save in folder mode triggers a full O(N) `buildTree` background scan every 2 s. Fix: mark recently-self-written paths so DirectoryWatcher debouncer skips them, or diff-patch tree instead of rebuilding. **Effort: M.**

### M9. `scrollPositions` pruning evicts random entries when no stale paths exist
- `zMD/DocumentManager.swift:342-356`. `Dictionary.keys.prefix(excess)` has unspecified order; eviction is essentially random and could drop the user's open doc. Fix: track per-entry timestamp; LRU evict. **Effort: S.**

### M10. Save-time bookmark not refreshed on `isStale = true`
- `zMD/DocumentManager.swift:457-462`. `isStale` is read into a local but never acted on. Over time bookmark grows stale; eventually fails to resolve, falling through to NSSavePanel silently. Fix: when stale, regenerate `bookmarkData` and write back to `openDocuments[index].bookmarkData`. **Effort: S.**

### M11. NSSavePanel completion captures stale `index` after array mutation
- `zMD/DocumentManager.swift:485-497`. Captured `let index` is used in the async completion. If the user closes another tab while the panel is open, `index` may be wrong or out-of-bounds. The untitled-save path correctly uses `firstIndex(where: { $0.id == id })`; the fallback path does not. Fix: re-resolve by id inside the closure. **Effort: S.**

### M12. DOCX `xmlEscape` doesn't sanitize C0 control characters
- `zMD/ExportManager.swift:996-1003`. XML 1.0 forbids most C0 controls (U+0000–U+001F except `\t \n \r`). A markdown file containing `\u{0008}` produces malformed `document.xml`; Word/LibreOffice refuse to open. Fix: strip/replace U+0000–U+001F (minus tab/LF/CR) and U+FFFE/U+FFFF before emitting. **Effort: S.**

### M13. DOCX inline regex doesn't support `~~strikethrough~~`
- `zMD/ExportManager.swift:875`. Combined pattern omits `~~`, so DOCX renders raw `~~text~~`. Violates "single source of truth" promise. Fix: add `(~~([^~]+)~~)` to the combined pattern with a strike run helper. **Effort: S.**

### M14. Numbered-list `start=` ignored — every export restarts at 1
- `zMD/MarkdownParser.swift:340, 366`, `zMD/ExportManager.swift:419-446`. A list `5. ... 6. ...` always renumbers to 1, 2 in HTML/DOCX. Fix: capture leading integer in `extractListItemText`, set `start=` in HTML and `<w:startOverride>` in DOCX. **Effort: M.**

### M15. PDF export ignores `baseURL` for image resolution → relative images don't render in PDF
- `zMD/ExportManager.swift:25-41`. `exportToPDF` doesn't accept a `baseURL`; `<img src>` paths resolve against the process working directory in `NSAttributedString(html:)`. Same image renders fine in preview. Fix: take `baseURL: URL?`, rewrite `<img src>` to absolute `file://` URLs before HTML→AttributedString. **Effort: S.**

### M16. `AlertManager.showFileSaveError` is dead but save errors are silently swallowed
- `zMD/AlertManager.swift:116`, `zMD/DocumentManager.swift:437/465-488/668`. Helper exists but is never called; save paths use `try?` semantics that swallow errors. Net effect: a save failure looks like a successful save to the user. Fix: call `showFileSaveError(url:error:)` from save-failure paths in DocumentManager. **Effort: S.**

### M17. `FolderManager.refreshFileTreeAsync` allows out-of-order completion to publish stale tree
- `zMD/FolderManager.swift:74-82`. Multiple bg-queue scans can overlap; an earlier-finishing one's `fileTree =` overwrites the latest. Fix: serialize on a private queue, or stamp each request with a generation counter and discard non-latest publishes. **Effort: S.**

---

## Low-Severity Findings

| # | Title | Location |
|---|---|---|
| L1 | EditorTextView registers 12 NotificationCenter observers per instance — formatting commands fire in unfocused tabs too | `EditorTextView.swift:104-118` |
| L2 | `FileWatcher.startWatching` silent failure when `open(O_EVTONLY)` returns -1 — user has no external-change detection for the rest of the session | `FileWatcher.swift:32-35` |
| L3 | `MarkdownTextView.imageCache` keyed on relative path string — different docs in different folders both with `image.png` collide | `MarkdownTextView.swift:929` |
| L4 | `addToRecentFiles` regenerates security-scoped bookmarks for every recent on every add — synchronous filesystem churn | `DocumentManager.swift:284-289` |
| L5 | `decodeFileData` comment says CP1252 "decodes any byte sequence" but Foundation rejects 5 undefined positions — fallthrough to ISO-8859-1 saves it but misclaim is confusing | `DocumentManager.swift:84-122` |
| L6 | Frontmatter detected only when first line is exactly `---` — trailing whitespace defeats it | `MarkdownParser.swift:121, 776` |
| L7 | Inline-code regex `` `(.+?)` `` doesn't support double-backtick spans | `MarkdownTextView.swift:1135`, `MarkdownParser.swift:700-704` |
| L8 | `applyPattern` reverse-iteration model doesn't re-tokenize after mutation — concatenations creating new pairs aren't seen (acceptable; needs comment) | `MarkdownTextView.swift:1167-1191` |
| L9 | `UpdateManager.isNewerVersion` ignores semver pre-release/build metadata — `2.5.3-rc1` becomes `[2,5]` | `UpdateManager.swift:261-273` |
| L10 | `FileWatcher.restartIfFileExists` TOCTOU race — file removed between exists-check and `open()` leaves watcher silently dead | `FileWatcher.swift:118-122` |
| L11 | Format helpers' `setSelectedRange` runs before `didChangeText` — out-of-order per Apple's contract; no observable bug yet | `EditorTextView.swift:561-606` |
| L12 | `outdentSelection` cursor-column math edge case — only matters when cursor sits inside leading whitespace | `EditorTextView.swift:806-854` |
| L13 | `⌘⇧S` bound to "Duplicate..." — macOS users reflexively expect "Save As" | `zMDApp.swift:151-158` |
| L14 | DOCX hyperlink ID counter starts at 6 with no comment-tested invariant if static rels grow | `ExportManager.swift:220, 304-312` |
| L15 | DOCX `formatInlineMarkdownForDOCX` regex mishandles `**foo*bar*baz**` (mixed bold+italic) — italic strip eats inner `*bar*` | `ExportManager.swift:988-994` |
| L16 | Process-based zip subprocess can hang forever if `/usr/bin/zip` stalls — `waitUntilExit` blocks main | `ExportManager.swift:1009-1019` |

---

## Dead Code Inventory

| Symbol | File:Line | Verification | Recommendation |
|---|---|---|---|
| `AlertManager.showFileSaveError(url:error:)` | `AlertManager.swift:116` | `grep -rn "showFileSaveError"` → only declaration. All save paths use `try?` and swallow errors. | **Wire it up** (this is M16). Don't delete — call it from save-failure paths. |
| `MarkdownParser.escapeXML(_:)` | `MarkdownParser.swift:734` | Zero call sites. ExportManager has its own private `xmlEscape:996` (functionally identical body). | Delete from MarkdownParser, or have ExportManager use it. Currently neither happens. |
| `Notification.Name.editorFindAndReplace` | `EditorTextView.swift:18` | Only declaration; no publishers, no observers. | Delete. Find/Replace UI uses other mechanisms. |

Three confirmed dead symbols total across 12,308 lines. No dead types, no dead views, no commented-out code blocks of meaningful size.

---

## Architectural Observations

**1. The "single source of truth parser" claim is now true.** Every export, the print pipeline, the preview, the outline, and Quick Open route through `MarkdownParser.shared`. Recent unification work landed and stuck. This is a strength worth preserving — the prose comment at `ExportManager.swift:593-594` documents the contract; tests at this seam would lock it in.

**2. CLAUDE.md is out of date.** It lists ~14 files in File Organization (lines 100–112); the actual tree has 33. It doesn't mention `EditorTextView.swift` (1,105 lines, the larger of the two NSTextView subclasses) at all. Anyone reading just CLAUDE.md will miss the source-editor stack.

**3. Find-and-replace plumbing has two parallel matchers.** `DocumentManager.performSearch()` populates `searchMatches` for Replace operations; `MarkdownTextView.findMatchRanges` populates the visible highlights. They are wired by different events and to different states (H9 + H10). The split is an architectural smell — Replace and Highlight should agree on a single match list. Consider lifting matching into a `SearchEngine` that publishes `[NSRange]` and is observed by both panes.

**4. UpdateManager is doing four things.** Network fetch, JSON parse, DMG mount, app-bundle copy, and relaunch — all on main, all in one class with no test seam. Splitting fetch (URLSession + delegate) from install (background queue, signature-verified copy) would address C1 and C5 simultaneously.

**5. Notification names live in three files.** `EditorTextView.swift:5-19`, `ContentView.swift`, `WebRenderer.swift`. Centralizing in a single `Notifications.swift` would make dead names (like `editorFindAndReplace`) trivially auditable.

**6. The `DocumentManager` singleton publishes everything.** `currentCursorLine` mutations (per-keystroke) trigger `objectWillChange` on the same `ObservableObject` that holds `openDocuments`, `searchMatches`, `viewMode`, etc. Every typing keystroke re-evaluates `body` of every view observing `DocumentManager`. SwiftUI's diffing is good but not free. A separate `CursorState` ObservableObject would isolate the hot path.

---

## Things I Checked That Are Fine

- **MarkdownParser unification.** Every consumer (preview, HTML, PDF, DOCX, RTF, print, outline, Quick Open) goes through `MarkdownParser.shared.parse()`. Verified.
- **Element.id collision risk.** Replaced with raw content + `\u{1F}` separator — safe; no remaining `hashValue` use in identity.
- **Encoding round-trip.** All four save paths use `DocumentManager.encoding(for: document.detectedEncoding)`; BOM-first detection is correctly ordered.
- **FileWatcher inode-rename handling.** Captures `events` before any mutation; restarts watch on rename/delete-and-recreate (vim/VSCode atomic-save). Solid.
- **DirectoryWatcher retain pattern.** `passRetained` balanced in `stopWatching`; correct and well-documented.
- **MarkdownTextView Coordinator deinit.** Both timers invalidated, observer removed.
- **SourceEditorView Coordinator teardown.** Invoked from both `deinit` and `dismantleNSView`.
- **Magnify monitor lifecycle.** Added in `onAppear`, removed in `onDisappear`.
- **Closure weak-self in DocumentManager save panels.** Both completion blocks use `[weak self]`.
- **Security-scoped resource start/stop balance.** Every start has a matched stop in scope (un-sandboxed at runtime, but correct).
- **`@ObservedObject` for singletons in zMDApp.** Correct — singletons live forever; `@StateObject` would be wrong.
- **Coordinator `elementCache` thread safety.** Only mutated from `updateNSView` (main) and `diagramDidRender` (posted from main). Per-instance, not shared. Clean.
- **ToastManager dismiss timers.** Invalidated when toast trims and when fired.
- **`scrollPositions` skip-untitled guard.** Correctly avoids `/tmp` pollution.
- **Pinch-to-zoom bounds.** Clamped to `[0.5, 2.0]`. Cannot reach 0/negative/infinity.
- **Invalid regex in search.** `try?` returns nil, no crash.
- **List-continuation undo grouping.** Wraps two-step insert in named undo group; Cmd+Z reverts both.
- **Autocomplete confirm undo grouping.** Wraps replacement in named group.
- **Multi-cursor edit ordering.** Sorts ranges descending; `MultiCursorController.updatePositions` uses explicit mapping.
- **Auto-close brackets goes through `shouldChangeText`/`didChangeText`.**
- **Column-select event tracking.** Uses `window?.trackEvents` with proper stop sentinel — cannot hang on mouse-up outside window.
- **Autocomplete debounce cancellation.** Invalidates prior timer before scheduling.
- **Bookmark recovery in `loadRecentFiles`.** Resolves staleness, drops failed bookmarks, dedups by canonical path, rewrites array.
- **Recent files limit.** Capped at `Cache.recentFilesLimit` (10).
- **Update check timestamp** stamped only on successful parse — network failures retry next launch.
- **CDN URLs pinned** to `mermaid@10`, `katex@0.16.9`. Good supply-chain hygiene.
- **`xmlEscape` ordering.** `&` is escaped first so subsequent escapes don't double-escape.
- **`isHTMLBalanced` self-closing handling.** Covers `<br>`, `<hr>`, `<img>` and `/>` form.
- **Code-fence longest-fence rule.** `openLen`/`closeLen` correctly handles nested triple-backticks.
- **No `public` API leakage.** Zero `public` declarations in app target.
- **No commented-out code blocks** of meaningful size.
- **No real TODO/FIXME/HACK/XXX** outside one false positive in `SyntaxHighlighter.swift:83` (highlighting the literal string `"TODO"` in user code comments).
