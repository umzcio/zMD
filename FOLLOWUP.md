# Follow-up Items

Items deferred from the code-review remediation (`code-review-fixes` branch) because they require an architectural decision, plus adjacent problems spotted but intentionally not touched per the "minimum viable fix" rule.

## Deferred findings (need a human design decision)

### P1 — Split mode: full re-parse + full `NSTextStorage` replacement per keystroke
**Why deferred:** The minimal report fix ("debounce preview updates, diff the element list, patch only changed `NSTextStorage` ranges, rehash the cache key") is a redesign of the editor→preview update path and the cache key scheme, not a localized change. It changes the threading/update model.
**Design sketch:**
- Add a debounce (150–300ms) between `SourceEditorView.textDidChange` → `onContentChange` and the preview rebuild, so keystrokes coalesce.
- In `MarkdownTextView.buildAttributedString`, diff the new `[Element]` against the previous list (by `Element.id`) and `replaceCharacters(in:with:)` only the changed ranges instead of `setAttributedString` on the whole document.
- Key the element cache on a cheap hash (e.g. SipHash of content) rather than embedding each element's full text in the key string.

### P2 — Per-keystroke O(n) work in Source mode (status bar / outline / minimap)
**Why deferred:** Requires introducing debounce state into multiple SwiftUI views (`StatusBarView`, `OutlineView`, the minimap version token in `ContentView`) and moving word-count off-main. Cross-view infrastructure change.
**Design sketch:** A shared debounced "document metrics" publisher on `DocumentManager` (word/char count, headings) recomputed 300–500ms after the last edit on a background queue, with views observing the published result instead of recomputing in `body`. Use `content.utf8.count` or an edit counter for the minimap version token.

### P3 — (kept in fix loop) cursor line/col
Note: re-evaluated during the fix loop — see tracking table for final disposition.

### P4 — Full-document syntax re-highlight after every typing pause
**Why deferred:** The fix ("highlight only the visible glyph range plus edited lines, re-run on scroll") requires a scroll observer and visible-range tracking in `SourceEditorView` — a new incremental-highlighting subsystem.
**Design sketch:** Compute `layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)`, map to a character range, expand to full lines, and run the 11 highlight passes over that range only. Add an `NSView.boundsDidChangeNotification` observer on the scroll view's content view to re-highlight on scroll. Keep the full-document pass only for export/print.

### P7 — Synchronous file read + 5-stage decode + writes on the main thread
**Why deferred:** Moving `loadDocument`/`reloadDocument`/`saveDocument` I/O to a background queue and publishing back on main is a threading-model change touching every open/save/reload entry point, with new ordering/race considerations (interacts with the file-watcher suppression logic in L3/L4).
**Design sketch:** Read `Data(contentsOf:)` + `decodeFileData` on `DispatchQueue.global(qos: .userInitiated)`, then hop to main to publish the `MarkdownDocument`. For saves, snapshot `content` on main, write off-main, then update `isDirty`/watcher suppression back on main. Add a lightweight loading state for the (rare) large-file case.

### P8 — Exports run heavy work on the main thread (incl. 30s blocking zip wait)
**Why deferred:** Moving DOCX/PDF/HTML generation to a background queue requires reworking the `NSSavePanel` completion flow and adding a progress indicator; the `createZipArchive` `group.wait` must move off main. Threading change across `ExportManager`.
**Design sketch:** After the save panel returns a URL, dispatch generation to `DispatchQueue.global(qos: .userInitiated)`; only the final `NSAttributedString(html:)` shim needs main (hop for that step). Show a determinate/indeterminate progress UI; report completion/failure via the existing toast/alert path.

### P9 — Math placeholder substitution: O(n×m) rescans + serialized 5s-timeout waits
**Why deferred:** Replacing the serial per-equation semaphore waits with a concurrent render + single-pass substitution is a pipeline redesign in `ExportManager.extractMathFromMarkdown`.
**Design sketch:** Kick off all `renderMath` calls concurrently into a results dictionary keyed by placeholder id; wait once with a single overall timeout (e.g. 30s) using a `DispatchGroup`; then do one regex pass over the HTML matching `ZMDMATHPH(\d+)ZMDEND` and build the output once via a single `NSMutableString` rather than N `replacingOccurrences` copies.

### Q7 — PrintManager's third, degraded inline-formatting engine
**Why deferred:** The correct fix is to extract the attributed-string inline formatter out of `MarkdownTextView` into a shared helper parameterized by fonts/colors and have `PrintManager` call it. That is a refactor that changes print output (adds escape-sentinel handling, code-span protection, `<br>`), and sharing rendering state between a print path and the live renderer needs care. A half-measure (copy-pasting the sentinel logic into PrintManager) would just add a fourth copy.
**Design sketch:** Pull `MarkdownTextView`'s inline formatter (escape sentinels → code spans first → inline math → bold/italic/strike/link) into a standalone `InlineMarkdownFormatter` struct taking a small style config; call it from both `MarkdownTextView` and `PrintManager.formatInlineMarkdown`.

## Adjacent issues spotted but not touched (per minimum-viable-fix rule)

_(populated during the fix loop if any are found)_
