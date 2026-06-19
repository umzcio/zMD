# zMD Code Review — 2026-06-10

Multi-agent review of zMD (native macOS markdown editor: SwiftUI + AppKit, NSTextView rendering, custom line-based parser, WKWebView for Mermaid/KaTeX, PDF/HTML/DOCX/RTF exporters, FSEvents file watching, GitHub auto-update, distributed unsandboxed via direct `.dmg`).

Six parallel scout agents produced 34 candidate findings; a verification agent independently re-read each against the source. **All 34 confirmed, 0 rejected** (one severity downgrade). Every finding cites code that was confirmed present in place.

---

## 0. Remediation Tracking

Branch: `code-review-fixes`. Status values: PENDING / FIXED / DISPUTED / DEFERRED.

| ID | Title | Severity | Status | Commit |
|----|-------|----------|--------|--------|
| S1 | Stored XSS in HTML export via display-math `</script>` | Major | FIXED | ff276c7 |
| S2 | CDN scripts without SRI; Mermaid floating version | Minor | FIXED | 059364a |
| S3 | Relative `.md` link path traversal | Minor | FIXED | c3e41ed |
| S4 | Relaunch trampoline logs to predictable `/tmp` path | Minor | FIXED | 28268a2 |
| S5 | DMG download URL scheme not validated | Minor | FIXED | 44991da |
| C1 | CRLF documents shatter tables/lists/blockquotes | Major | FIXED | 15d08dc |
| C2 | Crash on fence info strings ≥76 chars | Major | FIXED | ea61fc7 |
| C3 | `extractHeadings` doesn't skip `$$` blocks | Minor | FIXED | cc4418c |
| C4 | Paragraph-flush predicate uses `line` vs `trimmedLine` | Minor | FIXED | 7f33051 |
| C5 | Tab-indented list items jump two nesting levels | Minor | FIXED | 7b4eba5 |
| C6 | Full-rebuild search highlighting ignores regex/case | Minor | FIXED | f8bde86 |
| C7 | Three divergent inline-math regexes | Major | FIXED | c73e4c2 |
| C8 | `reloadDocument` drops bookmark fields | Minor | FIXED | cd5e5a3 |
| L1 | Mermaid `evaluateJavaScript` async wrong-key cache | Major | FIXED | ef05852 |
| L2 | Non-UTF-8 document becomes unsaveable | Major | FIXED | f4851ec |
| L3 | "Keep My Changes" drops next external edit | Major | FIXED | dcce01d |
| L4 | Auto-save vs external-write delivery race | Minor | FIXED | 46de278 |
| L5 | Mermaid CDN failure → unbounded `pendingMermaid` | Minor | FIXED | bce1d13 |
| P1 | Split mode: full re-parse per keystroke | Major | DEFERRED | architectural |
| P2 | Per-keystroke O(n) work in Source mode | Major | DEFERRED | architectural |
| P3 | Cursor line/col walks from index 0 | Major | FIXED | 4943284 |
| P4 | Full-document syntax re-highlight per pause | Major | DEFERRED | architectural |
| P5 | Find line numbers via prefix scan | Major | FIXED | a2ee37a |
| P6 | Element cache grows unbounded | Major | FIXED | 0510eb9 |
| P7 | Synchronous file read/decode/write on main | Major | DEFERRED | architectural |
| P8 | Exports run heavy work on main thread | Minor | DEFERRED | architectural |
| P9 | Math placeholder O(n×m) + serial waits | Minor | DEFERRED | architectural |
| Q1 | Dead duplicate parser helpers in PrintManager | Minor | FIXED | d984ee3 |
| Q2 | Dead `MarkdownParser.isOrderedListLine` | Minor | FIXED | fa026c1 |
| Q3 | Dead `WebRenderer.getCachedImage` | Minor | FIXED | 71f949e |
| Q4 | Dead `SyntaxHighlighter.fileExtensions` | Minor | FIXED | ecfd7b6 |
| Q5 | Unimplemented current-line-highlight remnants | Minor | FIXED | 038f228 |
| Q6 | Half-finished `Timing` constant centralization | Minor | FIXED | b2501db |
| Q7 | PrintManager's degraded inline-formatting engine | Minor | DEFERRED | architectural |
| Q8 | Four HTML/XML escaping implementations | Minor | FIXED | 4ec0395 |
| Q9 | Dead `ToastItem.createdAt` | Minor | FIXED | b1e8cb6 |

### Remediation outcome

| Disposition | Major | Minor | Total |
|-------------|:--:|:--:|:--:|
| **Fixed**    | 10 | 19 | **29** |
| **Disputed** | 0  | 0  | **0**  |
| **Deferred** | 4  | 3  | **7**  |

- **Fixed (29):** all 5 Security, all 8 Correctness, all 5 Concurrency/Lifecycle, the 3 localized Performance items (P3/P5/P6), and 8 of 9 Quality items.
- **Disputed (0):** every finding re-verified true on re-read.
- **Deferred (7):** P1, P2, P4, P7, P8, P9 (Performance — require a threading-model or rendering-pipeline redesign) and Q7 (shared-formatter extraction). Design sketches are in `FOLLOWUP.md`. These need a human decision because a minimal in-scope patch would either change the update/threading model or add a fourth copy of duplicated logic.

Each fix is its own commit; the build (`xcodebuild -scheme zMD -configuration Debug`) was green after every commit, and a final `clean build` from scratch SUCCEEDED. The branch was reviewed by an independent verification pass (Phase 3): all FIXED items confirmed against their original failure scenario, no regressions, all 4 SRI hashes independently recomputed and matched.

There is **no test target** in this project (only the `zMD` app target), so no automated regression tests were added — fixes on testable-in-principle surfaces (parser edge cases, escaping, interval math) are instead covered by the manual checklist below.

### Manual verification checklist (run on a real machine)

These touch surfaces that can't be unit-tested here (WKWebView rendering, NSSavePanel/file I/O, FSEvents, CGEvent/selection):

- [ ] **S1** — Export a doc containing `$$\n</script><script>alert(1)</script>\n$$` to HTML; open the file in a browser: no alert fires, and the math area renders (no injected markup).
- [ ] **S2** — Math (`$x^2$`, `$$…$$`) and a Mermaid diagram still render in **preview** and in **exported HTML** (confirms the pinned versions + SRI hashes load).
- [ ] **S3** — A doc with `[x](../../../../somefile.md)` does **not** open a file outside the document's folder; a normal sibling `[y](./notes.md)` still opens.
- [ ] **S4** — After an in-app update + relaunch, the trampoline log appears under the per-user temp dir (`$TMPDIR`), not `/tmp/zmd-relaunch.log`.
- [ ] **L1** — Open a document with **two or more** Mermaid diagrams: each block shows its own correct diagram (no diagram appearing under the wrong block).
- [ ] **L2** — Open a CP1252/Latin-1 file, type an emoji or CJK character, press ⌘S: it saves (toast "Saved as UTF-8…"), the status bar then shows UTF-8, and no save panel loops.
- [ ] **L3** — Edit the open file externally → "Keep My Changes"; edit it externally **again**: the change dialog appears the second time (the edit is not silently swallowed).
- [ ] **L4** — With auto-save on, edit the file externally right around the 2s debounce: the external change surfaces a dialog rather than being overwritten (timing-sensitive; best-effort).
- [ ] **L5** — Disconnect the network, open a doc with a Mermaid diagram: the placeholder resolves to an error state instead of a permanent "Rendering diagram…" hang.
- [ ] **C1** — Open a Windows/CRLF `.md` with a table, a list, and a blockquote: all render correctly (no per-row header tables, no per-item list breaks).
- [ ] **C2** — A fenced code block whose info string exceeds 75 chars renders without crashing.
- [ ] **C3** — A `# heading` line inside a `$$…$$` block does not appear in the outline; headings after the block scroll to the right place.
- [ ] **P3** — The status bar "Ln X, Col Y" stays correct while typing, arrowing, clicking, and after an external reload.

---

## 1. Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| Major    | 13 |
| Minor    | 21 |
| **Total** | **34** |

| Category | Critical | Major | Minor | Total |
|----------|:--:|:--:|:--:|:--:|
| Security    | 0 | 1 | 4 | 5 |
| Correctness | 0 | 4 | 4 | 8 |
| Concurrency / Lifecycle | 0 | 3 | 3 | 6 |
| Performance | 0 | 5 | 2 | 7 |
| Dead Code / Quality | 0 | 0 | 8 | 8 |

The auto-update security model is genuinely strong (Team-ID-pinned `SecStaticCodeCheckValidity` before install) and the WKWebView Mermaid/KaTeX *injection* escaping is correct. The weak spots cluster in three places: **per-keystroke performance** (no debounce between editor and preview, repeated full-document scans), **the parser's line handling** (CRLF, fence info strings, indentation), and **file-watch / encoding lifecycle** (data-loss races and an unsaveable-document trap).

---

## 2. Confirmed Findings

### Security

---

#### S1 — Stored XSS in HTML export via display-math `</script>` breakout
`zMD/MarkdownParser.swift:689-695`

```swift
case .displayMath(let latex):
    // H16: place the LaTeX inside a <script type="math/tex; mode=display"> tag.
    // Script tag contents aren't parsed as HTML, so `a < b` and `\&` survive intact —
    ...
    return "<div class=\"math-display\"><script type=\"math/tex; mode=display\">\(latex)</script></div>\n"
```

**Category:** Security — CWE-79 (Stored XSS).
**Why it's real:** `latex` is raw, unescaped document content. The comment's premise ("script contents aren't parsed as HTML") is false for the closing-tag sequence — a browser terminates a `<script>` on the literal bytes `</script` regardless of context. The HTML export path (`ExportManager.swift:319-336`) calls `parser.toHTML(content)` **without** the math pre-extraction that the PDF/RTF paths use (`ExportManager.swift:352`), so this branch is reachable only on HTML export. A document containing:

```
$$
</script><script>alert(document.domain)</script>
$$
```

produces an exported `.html` that runs the injected script when opened in any browser. The exporter already injects live KaTeX/Mermaid CDN scripts, so the page is script-enabled. Anyone who exports an untrusted `.md` to HTML and opens or shares it is exposed.
**Severity:** Major (export-only; requires the user to open/share the exported file).
**Fix:** Neutralize the closing-tag sequence before interpolation — `let safe = latex.replacingOccurrences(of: "</", with: "<\\/")` (the backslash is ignored by KaTeX's TeX parser but stops the browser seeing `</script>`), then interpolate `safe`. PDF/RTF are unaffected.

---

#### S2 — CDN scripts loaded without Subresource Integrity; Mermaid pinned to a floating major version
`zMD/SettingsManager.swift:53-58`

```swift
enum CDN {
    static let mermaidJS = "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"
    static let katexCSS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css"
    static let katexJS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"
    static let katexAutoRenderJS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"
}
```

**Category:** Security — CWE-494 (Download of code without integrity check).
**Why it's real:** These URLs are executed inside the app's headless `WKWebView` (`WebRenderer.swift:83`, `248-249`) **and** embedded into every exported HTML with math/mermaid (`MarkdownParser.swift:466-473`). None carry `integrity=`/SRI; `mermaid@10` resolves to whatever the latest `10.x` is at fetch time. A CDN compromise or malicious `10.x` publish runs arbitrary JS inside the unsandboxed app and in any opened export. SRI would make the browser/WebView refuse a tampered script.
**Severity:** Minor.
**Fix:** Pin Mermaid to an exact version (e.g. `mermaid@10.9.1`) and add `integrity="sha384-…" crossorigin="anonymous"` to all four references in both `WebRenderer.swift` and `MarkdownParser.toHTML`. For the in-app preview WebView, bundling the scripts locally removes the network dependency entirely.

---

#### S3 — Relative `.md` link handler allows path traversal outside the opened folder
`zMD/MarkdownTextView.swift:313-321`

```swift
if ["md", "markdown"].contains(url.pathExtension.lowercased()),
   let base = baseURL?.deletingLastPathComponent() {
    let resolved = base.appendingPathComponent(url.relativeString)
    if FileManager.default.fileExists(atPath: resolved.path) {
        DocumentManager.shared.loadDocument(from: resolved)
        return true
    }
}
```

**Category:** Security — CWE-22 (Path Traversal).
**Why it's real:** `appendingPathComponent` does no normalization or containment check, so a crafted link `[x](../../../../Users/zach/Documents/private-notes.md)` resolves outside the document's directory and is opened as a tab if it exists.
**Severity:** Minor — bounded: only `.md`/`.markdown` extensions, opened read-only into the viewer, no execution and no arbitrary file-type read.
**Fix:** Standardize and confine before loading: `guard resolved.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path) else { return false }`.

---

#### S4 — Relaunch trampoline logs to a predictable world-writable path
`zMD/UpdateManager.swift:338-345`

```swift
let logPath = "/tmp/zmd-relaunch.log"
let script = """
( echo "[$(date)] trampoline waiting for PID \(myPid)" >> \(logPath); \
  ...
  open -n '\(appPath)' >> \(logPath) 2>&1; \
  echo "[$(date)] open exit=$?" >> \(logPath) ) &
disown
"""
```

**Category:** Security — CWE-377 (Insecure Temporary File).
**Why it's real:** `/tmp` is world-writable and shared across local users; the path is fixed and predictable. A local attacker can pre-create `/tmp/zmd-relaunch.log` as a symlink to a victim-writable file, and the `>>` redirects append to the symlink target.
**Severity:** Minor — requires local multi-user access; appended content is only timestamp/path log lines. (The DMG staging file at `UpdateManager.swift:153` correctly uses the per-user `temporaryDirectory` and is **not** affected.)
**Fix:** Write the log under `FileManager.default.temporaryDirectory` (per-user `/var/folders/...`), or drop the log redirect in release builds.

---

#### S5 — DMG download URL scheme not explicitly validated
`zMD/UpdateManager.swift:91-97`

```swift
if let name = asset["name"] as? String,
   name.hasSuffix(".dmg"),
   let urlStr = asset["browser_download_url"] as? String,
   let url = URL(string: urlStr) {
    dmgURL = url
```

**Category:** Security — CWE-494 (defense-in-depth gap).
**Why it's real:** The artifact URL from the GitHub API is handed to `downloadTask` (line 136) with no `scheme == "https"` assertion.
**Severity:** Minor (informational) — mitigated in depth: GitHub assets are HTTPS, macOS ATS blocks cleartext, and the bundle is Team-ID-pinned signature-verified before install (`UpdateManager.swift:235-248`, `283-326`), so a swapped artifact cannot install. Worth a one-line guard only.
**Fix:** `guard url.scheme == "https" else { stage = .failed(...); return }` in `downloadAndInstall`.

---

### Correctness — Parser & Rendering

---

#### C1 — CRLF documents shatter tables, lists, and blockquotes
`zMD/MarkdownParser.swift:115`

```swift
let lines = markdown.components(separatedBy: .newlines)
```

**Category:** Correctness — wrong output on common input.
**Why it's real:** `CharacterSet.newlines` splits on `\r` and `\n` individually, so every CRLF pair yields a phantom empty line. Verified: `"| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n"` → `["| a | b |", "", "|---|---|", "", "| 1 | 2 |", "", ""]`. `DocumentManager.decodeFileData` does no line-ending normalization. On any Windows-authored `.md`: tables break into per-row fragments each styled as a header row (`isHeader = rowIndex == 0`), lists flush after every item, blockquotes split per line, code blocks render double-spaced.
**Severity:** Major.
**Fix:** Normalize once at parse entry (and in `extractHeadings`): `markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")`, or normalize in `decodeFileData`.

---

#### C2 — Crash on fence info strings ≥ 76 characters (negative `String(repeating:count:)`)
`zMD/MarkdownTextView.swift:857-859`

```swift
let langLabel = language?.lowercased() ?? "text"
let labelPadding = 76 - langLabel.count - 1
let bottomBorder = "  ╰" + String(repeating: "─", count: labelPadding) + " " + langLabel + "╯\n"
```

**Category:** Correctness — crash (precondition failure).
**Why it's real:** `MarkdownParser.parse()` (line 247) takes the **entire** fence info string as the language, not just the first token. A fence line whose info string exceeds 75 chars makes `labelPadding` negative, and `String(repeating:count:)` with a negative count is a Swift precondition failure → crash on render. (The scout's "re-crash on relaunch" claim is unsupported — there is no session/tab restore in the codebase — but the crash itself stands.)
**Severity:** Major — requires an unusually long info string, so not "realistic input" in the Critical sense, but it is a hard crash from document content with no guard.
**Fix:** `let labelPadding = max(0, 76 - langLabel.count - 1)`, and in `parse()` take only the first whitespace-delimited token as `language` (also fixes `"bash extra words"` defeating the syntax highlighter's language match).

---

#### C3 — `extractHeadings` doesn't skip `$$` display-math blocks → outline desync
`zMD/MarkdownParser.swift:935-996` (vs `parse()` 227-235); pairing at `zMD/MarkdownTextView.swift:585-588`

```swift
if element.isHeading, parsedHeadingIndex < headings.count {
    headingRanges[headings[parsedHeadingIndex].id] = NSRange(...)
    parsedHeadingIndex += 1
}
```

**Category:** Correctness — outline/scroll desync.
**Why it's real:** `extractHeadings` skips fences, frontmatter, and HTML blocks but not `$$` blocks, while `parse()` consumes them. For input where a `#`-prefixed line sits inside `$$ … $$`, the two functions disagree on heading count; the positional pairing then assigns the wrong slug, producing a phantom outline entry and off-by-one heading ranges. An unterminated `$$` makes `parse()` swallow all subsequent headings while `extractHeadings` keeps them — the outline goes dead.
**Severity:** Minor.
**Fix:** Mirror `parse()`'s `$$`-block toggle in `extractHeadings` (enter on `trimmed == "$$"`, exit on the next `"$$"`).

---

#### C4 — Paragraph-flush predicate uses `line` where block branches use `trimmedLine`
`zMD/MarkdownParser.swift:149-163` (vs 174-186, 270)

```swift
let isPlainText = !line.isEmpty && !trimmedLine.isEmpty
    && !line.hasPrefix("#")          // heading branch matches trimmedLine
    ...
    && !line.hasPrefix("> ")         // blockquote branch matches trimmedLine.hasPrefix(">")
```

**Category:** Correctness — element ordering.
**Why it's real:** An indented heading (`  ## H`) does not match `line.hasPrefix("#")`, so the buffered paragraph is not flushed, but the heading branch (`trimmedLine.hasPrefix("## ")`) still fires — the heading is emitted **above** the preceding paragraph text, and surrounding paragraphs merge across it. Same for a space-less `>quote` (`line.hasPrefix("> ")` is false, but the blockquote branch matches `trimmedLine.hasPrefix(">")`).
**Severity:** Minor.
**Fix:** Make `isPlainText` use the same `trimmedLine` predicates as the block branches.

---

#### C5 — Tab-indented list items jump two nesting levels
`zMD/MarkdownParser.swift:364-374`

```swift
} else if char == "\t" {
    level += 4  // Treat tab as 4 spaces
...
let nestLevel = level / 2
```

**Category:** Correctness — inconsistent rendering.
**Why it's real:** One tab = 4 → `nestLevel 2`, while a 2-space indent = `nestLevel 1`. Tab- and space-indented versions of the same list render at different depths with different bullets.
**Severity:** Minor.
**Fix:** `level += 2` for a tab (one level per tab).

---

#### C6 — Full-rebuild search highlighting ignores regex / case-sensitive mode
`zMD/MarkdownTextView.swift:1451-1475`

```swift
private func applySearchHighlighting(to result: NSMutableAttributedString) {
    guard !searchText.isEmpty else { return }
    ...
    let range = string.range(of: searchText, options: .caseInsensitive, range: searchRange)
```

**Category:** Correctness — highlight/counter mismatch.
**Why it's real:** The struct carries `isRegexSearch`/`isCaseSensitive` and `findMatchRanges` (line 334) honors them, but the rebuild path paints highlights with literal `.caseInsensitive` search only. A regex search `fo+` over "foo" shows a match count of 1 but paints zero highlights after an edit; a case-sensitive literal search paints wrong-case occurrences.
**Severity:** Minor.
**Fix:** Call `updateMatchHighlighting` (which already paints the correct ranges) from the content-changed branch, or thread the two flags into `applySearchHighlighting`.

---

#### C7 — Three divergent inline-math regexes (preview vs export disagree)
`zMD/MarkdownTextView.swift:1393`, `zMD/ExportManager.swift:40`, `zMD/MarkdownParser.swift:456`

```swift
// MarkdownTextView (preview):   ...([^\n]{1,200}?)...
// ExportManager (PDF/RTF/DOCX): ...([^\n$]{1,200}?)...   // note [^\n$]
// MarkdownParser (HTML inject): (?<!\$)\$(?!\$)(?! )(.+?)(?<! )\$(?!\$)   // no digit guard, no cap
```

**Category:** Correctness — preview/export divergence.
**Why it's real:** For `$a $2 b$`, the preview pattern's `[^\n]` capture spans the interior `$` and renders the whole span as math, while the export pattern's `[^\n$]` cannot cross it and leaves literal text — PDF/RTF/DOCX disagree with the preview. The `MarkdownParser` variant (no digit guard) additionally classifies money spans like `($1) … ($10)` as math for KaTeX-script-injection purposes. ExportManager's comment claims the patterns match; they do not.
**Severity:** Major.
**Fix:** Define the pattern once (e.g. `static let inlineMathPattern` on `MarkdownParser`) and reference it from all three sites; choose `[^\n$]` or `[^\n]` deliberately.

---

#### C8 — `reloadDocument` rebuilds `MarkdownDocument` and drops bookmark fields
`zMD/DocumentManager.swift:246-251`

```swift
var newDocument = MarkdownDocument(id: document.id, url: document.url, content: fileContent)
newDocument.detectedEncoding = encoding
openDocuments[index] = newDocument
```

**Category:** Correctness — field loss (regression of a documented fix).
**Why it's real:** This is the exact pattern the code documents as fixed for rename/move (lines 758-766: "Previously we constructed `MarkdownDocument(id:url:content:)` and lost every other field"). After a Reload, `bookmarkData`, `directoryBookmarkData`, and `isUntitled` are nil — inert in the un-sandboxed build, but a guaranteed regression for the sandbox re-enable path CLAUDE.md keeps the bookmark code alive for, and `directoryBookmarkData` is what `MarkdownTextView` uses for relative-image access.
**Severity:** Minor (inert today).
**Fix:** Mutate in place: `openDocuments[index].content = fileContent; openDocuments[index].detectedEncoding = encoding; openDocuments[index].isDirty = false`.

---

### Concurrency & Lifecycle

---

#### L1 — Mermaid render: `evaluateJavaScript` on an `async` JS function always errors → wrong diagram cached under wrong key
`zMD/WebRenderer.swift:94, 171-186, 376-382`

```swift
// JS: async function renderMermaid(code) { ... }   (line 94)
webView.evaluateJavaScript("renderMermaid(`\(escapedCode)`)") { [weak self] _, error in
    if error != nil {
        item.completion(nil)
        self?.isMermaidRendering = false
        self?.processNextMermaidRender()
    }
}
```

**Category:** Concurrency — completion-ordering bug.
**Why it's real:** An `async` function call evaluates to a Promise, which `WKWebView` cannot serialize, so `evaluateJavaScript` returns `WKError 5` on **every** mermaid render while the JS keeps running and posts `mermaidResult` later (the scout empirically reproduced this in a headless WebView; it is established WebKit behavior for `evaluateJavaScript` vs `callAsyncJavaScript`). With ≥2 mermaid blocks queued `[A, B]`: A's error branch advances the queue, B starts and overwrites `activeMermaidCompletion`, then A's real result arrives and is delivered to **B's** closure — A's PNG is cached under B's SHA256 key and the cache stays poisoned for the session. Single-diagram docs work by accident (completion fires nil then image). The KaTeX path uses a plain function and is unaffected.
**Severity:** Major.
**Fix:** Evaluate `"void renderMermaid(\`…\`)"` so the statement result is `undefined` (no error), or use `callAsyncJavaScript`. Also set `activeMermaidCompletion = nil` in the genuine-error branch so a stale closure can't receive a later result.

---

#### L2 — Non-UTF-8 document becomes unsaveable after typing a non-encodable character
`zMD/DocumentManager.swift:513-516, 529-556`

```swift
let saveEncoding = DocumentManager.encoding(for: document.detectedEncoding)
do {
    try document.content.write(to: resolvedURL, atomically: true, encoding: saveEncoding)
} catch {
    // ... assumes permissions problem, opens NSSavePanel ...
    try contentSnapshot.write(to: newURL, atomically: true, encoding: saveEncoding)  // same encoding → throws again
```

**Category:** Concurrency/Lifecycle — data-entry dead end.
**Why it's real:** A file read via the CP1252 / Mac Roman / ISO-8859-1 fallbacks keeps that encoding for saving. If the user types a character not representable in it (emoji, CJK, math symbols), `write` throws `NSFileWriteInapplicableStringEncodingError`. The catch assumes a permission problem and opens an `NSSavePanel` whose completion retries with the **same** encoding — guaranteed to throw again. With auto-save on, a save panel appears mid-typing and no action lets the user save. (A wrong encoding *guess* does not silently corrupt — encoding round-trips and is shown in the status bar.)
**Severity:** Major.
**Fix:** Catch `NSFileWriteInapplicableStringEncodingError` specifically and offer "Save as UTF-8" (updating `detectedEncoding`) instead of the permissions/save-panel path.

---

#### L3 — "Keep My Changes" arms `ignoreNextChange` against the *next* genuine external edit
`zMD/DocumentManager.swift:1108-1110`; `zMD/FileWatcher.swift:87-92`

```swift
case .ignore:
    // Do nothing, but update the watcher's timestamp
    watcher.ignoreNextChange = true
```
```swift
if ignoreNextChange {
    ignoreNextChange = false
    lastModificationDate = getModificationDate()
    if inodeChanged { restartIfFileExists() }
    return
}
```

**Category:** Concurrency/Lifecycle — silent data loss.
**Why it's real:** The event that triggered the dialog was already consumed, so the flag arms against the **next real** external edit. Sequence: external edit #1 → dialog → user picks "Keep My Changes" → flag armed → external edit #2 later is consumed silently (`lastModificationDate` refreshed, no dialog/toast) → user saves → edit #2 is overwritten with no warning, defeating the exact guard the dialog exists for. The mod-date guard at `FileWatcher.swift:96` already suppresses same-write echoes, so the flag isn't needed here.
**Severity:** Major.
**Fix:** Remove `watcher.ignoreNextChange = true` from the `.ignore` case.

---

#### L4 — Auto-save debounce vs external-write delivery race
`zMD/DocumentManager.swift:444-452, 516-521`; `zMD/FileWatcher.swift:87-99`

**Category:** Concurrency — narrow data-loss race.
**Why it's real:** If an external write lands just before the 2s debounce fires, its vnode event sits queued behind the timer block on the main queue. `saveDocument` overwrites the file and sets `ignoreNextChange = true`; the queued external event is then consumed by that flag (refreshing `lastModificationDate`), and our own write's event is dropped by the mod-date guard. Net: the external edit is lost with no dialog. Window is event-delivery latency (milliseconds).
**Severity:** Minor.
**Fix:** In the auto-save path, compare the file's current mtime against the watcher's `lastModificationDate` before writing; route through the external-change dialog on mismatch.

---

#### L5 — Mermaid CDN load failure → `pendingMermaid` grows unbounded, placeholders persist forever
`zMD/WebRenderer.swift:58-62, 91-92`

```js
mermaid.initialize({ startOnLoad: false, theme: 'default' });
window.webkit.messageHandlers.mermaidReady.postMessage('ready');
```

**Category:** Concurrency/Lifecycle — stuck state on offline.
**Why it's real:** If the CDN `<script>` fails (offline), line 91 throws `ReferenceError: mermaid is not defined` before the `postMessage`, so `mermaidReady` stays false forever and every preview rebuild appends another closure to `pendingMermaid` (never drained), with "Rendering diagram…" stuck and no error surfaced. KaTeX is resilient by contrast — it posts `katexReady` from `window.onload` (fires even on CDN failure) and reports render errors.
**Severity:** Minor.
**Fix:** Post `mermaidReady` from `window.onload` and let `renderMermaid`'s try/catch report `mermaid is not defined`, mirroring the KaTeX design.

---

#### L6 — Diagram pipeline / queue desync (covered by L1)
See **L1** — this was reported by two agents; consolidated.

---

### Performance

---

#### P1 — Split mode: full re-parse + full `NSTextStorage` replacement on every keystroke
`zMD/SourceEditorView.swift:282-287`; `zMD/MarkdownTextView.swift:97-114, 529-553, 1213-1218`

```swift
// SourceEditorView — no debounce:
func textDidChange(_ notification: Notification) {
    ...
    onContentChange?(textView.string)
}
// MarkdownTextView.buildAttributedString — two full passes per keystroke:
let elements = parser.parse(content)
let headings = parser.extractHeadings(content)
textView.textStorage?.setAttributedString(attributedString)
```

**Category:** Performance — main-thread stall.
**Why it's real:** In `.split` mode each keystroke runs two full-document parses, re-assembles every cached fragment into a fresh `NSMutableAttributedString`, and calls `setAttributedString` (full TextKit relayout). The element cache only short-circuits `renderElement` — not the parses, the re-assembly, or the `Element.id` key construction (keys embed each element's full text, `MarkdownParser.swift:36-59`). `.htmlBlock` elements bypass the cache and run the synchronous `NSAttributedString(html:)` WebKit shim per rebuild. On a 5MB doc, each keypress costs hundreds of ms to seconds.
**Severity:** Major (downgraded from Critical: severe degradation with a workaround — use preview-only mode — not a crash or data loss).
**Fix:** Debounce preview updates from the editor (150–300ms); diff the element list and patch only changed `NSTextStorage` ranges with `replaceCharacters(in:with:)`; key the cache on a cheap content hash rather than full strings.

---

#### P2 — Per-keystroke O(n) main-thread work in Source mode (status bar, outline, minimap)
`zMD/StatusBarView.swift:12, 70-75`; `zMD/OutlineView.swift:49, 52-59`; `zMD/ContentView.swift:727`

```swift
let stats = documentStats(for: document.content)        // content.count + split, per body eval
headings = MarkdownParser.shared.extractHeadings(content) // .onChange(of: content)
contentVersion: content.count                            // O(n) grapheme count per body eval
```

**Category:** Performance — main-thread stall.
**Why it's real:** `updateContent` fires `objectWillChange` on every change, so three independent full-document scans run per keystroke with no debounce — `content.count` (O(n) grapheme walk), `split` (allocates a `Substring` per word, ~800k on a 5MB doc), and a full `extractHeadings` pass when the outline is open.
**Severity:** Major.
**Fix:** Debounce stats/outline recompute (300–500ms); compute word count off-main; use `content.utf8.count` or an edit counter for the minimap version.

---

#### P3 — Cursor line/column computed by walking from index 0 on every selection change
`zMD/SourceEditorView.swift:364-379`

```swift
var line = 1
var i = 0
while i < clampedCaret {
    if text.character(at: i) == 0x0A { line += 1; ... }
    i += 1
}
```

**Category:** Performance — main-thread stall.
**Why it's real:** `textViewDidChangeSelection` fires on every keypress, arrow key, and click. With the caret near the end of a 5MB doc that is ~5M `character(at:)` calls per event, synchronously on main, plus two `@Published` writes triggering another SwiftUI invalidation.
**Severity:** Major.
**Fix:** Use `NSString.lineRange(for:)` / `getLineStart`, or cache the last (caret, line) pair and count only the delta; skip when the status bar is hidden.

---

#### P4 — Full-document syntax re-highlight after every typing pause
`zMD/SourceEditorView.swift:387-411` (scheduled at 294-297)

```swift
let fullRange = NSRange(location: 0, length: (text as NSString).length)
storage.addAttributes([.font: ..., .foregroundColor: ...], range: fullRange)
highlightPattern(#"^#{1,6}\s+.*$"#, ...)   // 11 full-document regex scans
```

**Category:** Performance — main-thread stall.
**Why it's real:** The 0.3s debounce coalesces keystrokes, but the unit of work is always the whole document: a full-range font/color reset (invalidating all layout) plus 11 full regex scans. On a 5MB doc each typing pause stalls the main thread for seconds. The same repaint also runs synchronously from `updateNSView` on search-state change (line 176).
**Severity:** Major.
**Fix:** Restrict highlighting to the visible glyph range plus edited line(s) via `layoutManager.glyphRange(forBoundingRect:)`; re-run on scroll.

---

#### P5 — Find: per-match line numbers via prefix scan from `startIndex`
`zMD/DocumentManager.swift:985` (plain, main thread), `:972` (regex, background)

```swift
let lineNumber = content[content.startIndex..<range.lowerBound].filter { $0 == "\n" }.count + 1
```

**Category:** Performance — O(n × matches) main-thread stall.
**Why it's real:** Every match re-scans the document prefix from `startIndex` and `filter` allocates a String of all prefix newlines per match. With `maxSearchMatches = 10_000`, searching a common letter in a 5MB doc is tens of GB of traversal plus 10k allocations on the main thread. The 200ms debounce coalesces keystrokes but doesn't reduce per-execution cost.
**Severity:** Major.
**Fix:** Single forward pass tracking a running newline count between consecutive (ascending) match positions.

---

#### P6 — Element cache grows without bound during an editing session
`zMD/MarkdownTextView.swift:576-578` (insert), `550-553` / `463` (only evictions)

```swift
if !skipCache, endPos > startPos {
    let fragment = result.attributedSubstring(from: NSRange(location: startPos, length: endPos - startPos))
    coordinator.elementCache[element.id] = fragment
}
```

**Category:** Performance — unbounded memory.
**Why it's real:** Keys are content-addressed, so each keystroke inserts a new entry for the edited element's new content and never removes the old one. The only evictions are full `removeAll()` on zoom/font/appearance change or diagram render. It's a plain `[String: NSAttributedString]` (not `NSCache`), so no memory-pressure relief. Editing inside a 50KB code block retains one full styled copy plus the 50KB key per keystroke — ~100MB over a 1,000-keystroke session, released only on tab close.
**Severity:** Major.
**Fix:** After each build, sweep entries whose keys aren't in the current `elements` id set; or switch to `NSCache` with count/cost limits like the image caches already use.

---

#### P7 — Synchronous file read + 5-stage encoding decode on main at open; sync writes on save
`zMD/DocumentManager.swift:203-205, 110-146, 516, 444`

```swift
let data = try Data(contentsOf: url)
let (fileContent, encoding) = decodeFileData(data)   // up to 5 full decodes, on main
...
try document.content.write(to: resolvedURL, atomically: true, encoding: saveEncoding)  // sync on main
```

**Category:** Performance — main-thread stall.
**Why it's real:** `loadDocument` runs on main from the open panel, recent-files buttons, drop handling, and link clicks; `decodeFileData` attempts up to five full decodes. A large or network-volume file freezes the UI for the whole read+decode. Saves (incl. the 2s auto-save timer) write synchronously on main.
**Severity:** Major.
**Fix:** Read+decode on a background queue, publish on main; snapshot content and write off-main.

---

#### P8 — Exports run heavy work on main, including a blocking wait on the zip subprocess
`zMD/ExportManager.swift:400-402, 1256, 190-308, 328`

```swift
let waitResult = group.wait(timeout: .now() + timeoutSec)   // blocks calling (main) thread, up to 30s
```

**Category:** Performance — main-thread stall.
**Why it's real:** DOCX export runs the full parse, XML generation, per-image reads, and `createZipArchive` on main, where `group.wait` blocks up to 30s on `/usr/bin/zip`. PDF layout and the `NSAttributedString(html:)` shim run on main; HTML `toHTML` runs on main in the panel completion. Exporting a 5MB doc beachballs for seconds; a stalled zip freezes the UI up to 30s.
**Severity:** Minor (user-initiated, one-shot).
**Fix:** Generate on a background queue with a progress indicator; only the final `NSAttributedString(html:)` needs main.

---

#### P9 — Math placeholder substitution: O(n × m) rescans + serialized 5s-timeout waits
`zMD/ExportManager.swift:63-71, 91`

```swift
for (i, hit) in math.enumerated() {
    DispatchQueue.main.async { WebRenderer.shared.renderMath(...) { ...; semaphore.signal() } }
    _ = semaphore.wait(timeout: .now() + 5)
}
...
result = result.replacingOccurrences(of: placeholder, with: replacement)  // full-string scan+copy per item
```

**Category:** Performance — export latency.
**Why it's real:** Renders are serialized with a 5s timeout each; with the CDN unreachable, a 300-equation doc waits 300 × 5s = 25 minutes before producing output. Each `replacingOccurrences` rescans and copies the entire HTML — 300 spans = 300 full copies. Runs on a background queue, so the UI survives but the export appears hung.
**Severity:** Minor.
**Fix:** Render math concurrently with a single batch timeout; do one regex pass over the HTML to substitute all placeholders.

---

### Dead Code & Code Quality

---

#### Q1 — Dead duplicate parser helpers in PrintManager
`zMD/PrintManager.swift:343-360` — `isListLine`, `isHorizontalRule`, `isTableSeparator` are `private` with no in-file call sites (grep: only declarations) and are character-identical to `MarkdownParser`'s copies. The line-by-line parser they served was removed (comment at 47-52). **Minor.** Delete all three.

#### Q2 — Dead `MarkdownParser.isOrderedListLine`
`zMD/MarkdownParser.swift:353-356` — single grep hit (its own declaration); ordered-item detection happens inline in `extractListItemText`. **Minor.** Delete.

#### Q3 — Dead `WebRenderer.getCachedImage(for:prefix:)`
`zMD/WebRenderer.swift:45-47` — single grep hit; render paths consult `imageCache` directly. **Minor.** Delete.

#### Q4 — Dead `SyntaxHighlighter.fileExtensions`
`zMD/SyntaxHighlighter.swift:73-79` — single grep hit; language dispatch never consults it. **Minor.** Delete.

#### Q5 — Unimplemented current-line-highlight remnants
`zMD/EditorTextView.swift:28, 41-47` — `showCurrentLineHighlight` and `currentLineHighlightColor` each have a single grep hit and no consuming draw pass. The README "current-line highlight" feature is satisfied only by the gutter's line-number emphasis (`LineNumberGutter.swift:87`), so these background-highlight remnants are genuinely dead. **Minor.** Delete, or implement the draw pass if wanted.

#### Q6 — Half-finished `Timing` constant centralization
`zMD/SettingsManager.swift:15, 17, 21, 23, 31` — `highlightDebounce`, `autocompleteDebounce`, `scrollSyncDebounce`, `headingFlashDuration`, `scrollPositionPersistDebounce` are unused while the call sites keep inline literals (`SourceEditorView.swift:256, 295, 301`; `MarkdownTextView.swift:477, 491`). The file's header promises a "single edit point" that is false for half the table. **Minor.** Replace the inline literals with the constants, or delete the unused constants.

#### Q7 — PrintManager's third, degraded inline-formatting engine
`zMD/PrintManager.swift:276-341` (in active use at 129/146/195) vs `zMD/MarkdownTextView.swift:1243-1303`. PrintManager's `formatInlineMarkdown` has no escape sentinels, applies code spans last (so `*x*` inside backticks gets italicized), and doesn't handle `<br>`. Every inline-formatting fix made to MarkdownTextView was not ported. **Minor** (print fidelity), but structurally the most expensive duplication in the repo. **Fix:** extract the shared inline formatter, mirroring what was already done for block parsing.

#### Q8 — Four HTML/XML escaping implementations
`zMD/ExportManager.swift:109-114` (`escapeHTMLAttr`, 4 entities), `zMD/MarkdownParser.swift:876-883` (`escapeHTML`, 5), `zMD/ExportManager.swift:1216-1233` (`xmlEscape`, legitimately different — XML/DOCX + C0 scrub), `zMD/MarkdownParser.swift:853-855` (2-entity href escape). `escapeHTMLAttr` is a strict subset of `escapeHTML`, and ExportManager already holds `parser`. **Minor.** Delete `escapeHTMLAttr`, call `parser.escapeHTML`; keep `xmlEscape` with a comment on why it differs.

#### Q9 — Dead `ToastItem.createdAt`
`zMD/ToastManager.swift:29` — single grep hit; dismissal is timer-based. **Minor.** Delete.

---

## 3. What's Solid (verified clean)

- **Auto-update signature validation (CWE-494 core).** Before copying to `/Applications`, the downloaded `.app` is checked with `SecStaticCodeCheckValidity` (strict, resource-hash) **and** Team-ID-pinned to the running bundle (`UpdateManager.swift:235-248, 283-326`). Fails safe if the current bundle's Team ID can't be read. A MITM/swapped artifact cannot install. `hdiutil` calls pass arguments as arrays (no shell injection).
- **WKWebView injection escaping.** Mermaid code is escaped for the JS template literal (backslash-doubled first, backtick + `${` neutralized; `WebRenderer.swift:165-180`) and KaTeX latex for the single-quoted string (`307-324`). Both breakouts are closed.
- **HTML export inline content.** Headings, paragraphs, table cells, list items, blockquotes, frontmatter all route through `escapeHTML`; link hrefs through `sanitizeURLScheme` (http/https/mailto/tel/ftp/file + `data:image/*` allowlist); raw HTML blocks through `sanitizeHTMLBlock` (strips script/iframe/handlers/`javascript:`). Only the display-math `<script>` branch (S1) escapes this.
- **Preview link-click handler** only opens http/https/mailto via `NSWorkspace`; `javascript:`/`file:` are not opened (`MarkdownTextView.swift:301-329`).
- **DOCX/RTF escaping.** `xmlEscape` covers all user-content run/cell/hyperlink paths plus C0 scrub; RTF goes through Apple's `NSAttributedString` serializer.
- **Off-main `@Published` mutation: none found.** FileWatcher uses `queue: .main`; DirectoryWatcher dispatches to main; FolderManager/UpdateManager/remote-image/regex-search all hop to main before publishing. The `WKScriptMessageHandler` re-enters via `Task { @MainActor }`.
- **Retain cycles: none found.** SourceEditorView and MarkdownTextView coordinators have full `deinit`/`dismantleNSView` teardown (timers invalidated, observers removed, delegate niled); timer closures use `[weak self]`; DirectoryWatcher balances `passRetained`.
- **Async diagram completion after tab close is harmless** — completions capture only strings and write to static caches before a broadcast notification; no coordinator/view references.
- **Scroll-sync loop prevention works** — `ScrollSyncOrigin` guards plus `isProgrammaticScroll` covering the full animation duration.
- **Bounded caches:** WebRenderer image cache, preview image/diagram caches (`NSCache` with count/byte limits), reading-position memory (100, LRU), recent files (10).
- **No catastrophic regex backtracking** in SyntaxHighlighter or editor highlighting — all negated-class / unrolled-loop / lazily-bounded patterns.
- **`Element.id` collisions:** uses C0 field separators + per-case prefixes; collision-free for realistic input.
- **Unterminated constructs** (fences, `$$`, frontmatter) all terminate at EOF; no infinite loops; search loops advance `max(1, …)`.
- **Error handling in user-facing flows** (save/load/reload/duplicate/rename/move/all exports/updater) routes to alerts or toasts; no silent swallowing. Force-unwraps are all compile-time-safe framework patterns; zero `try!`.
- **`MultiCursorController`** (the 33-line suspect) is fully alive.
- **File operations** (Rename/Move/Duplicate) don't silently overwrite — `moveItem` throws on existing destination, Duplicate uses `NSSavePanel`.

---

## 4. Prioritized Fix Order (top 5)

1. **L3 — "Keep My Changes" silently drops the next external edit** (`DocumentManager.swift:1110`). Silent data loss that defeats the existing safeguard, and the fix is a one-line deletion. Highest value-to-effort.
2. **L2 — Non-UTF-8 documents become unsaveable** (`DocumentManager.swift:529-556`). A user editing a CP1252/Latin-1 file who types an emoji hits an unrecoverable, auto-save-triggered save-panel loop. Real, reachable, no workaround.
3. **C1 — CRLF documents shatter rendering** (`MarkdownParser.swift:115`). Every Windows-authored file renders wrong (tables, lists, blockquotes, code). One normalization line fixes it broadly.
4. **P1 + P7 — Per-keystroke full re-parse and main-thread I/O** (`SourceEditorView.swift:287`, `MarkdownTextView.swift:97-114`, `DocumentManager.swift:203-205`). Split mode and large-file open are unusable; debouncing the editor→preview path and moving read/decode off-main is the core responsiveness fix.
5. **S1 — Stored XSS in HTML export** (`MarkdownParser.swift:695`). The only confirmed exploitable injection; a two-character escape (`</` → `<\/`) closes it. Cheap and the highest-severity security item.

(L1 — the mermaid wrong-key cache bug — is the next tier: it makes multi-diagram documents render wrong diagrams, and the fix is a `void`-prefix on the JS call.)
