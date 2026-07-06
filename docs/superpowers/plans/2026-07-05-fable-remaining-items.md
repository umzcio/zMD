# Fable Remaining Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining partial/open fable audit items: math export timeout behavior, raw HTML export safety, source-vs-rendered replace consistency, WebView background robustness, a parser regression harness, and the shared inline-token model.

**Architecture:** Keep block parsing in `MarkdownParser`. Add a small pure `InlineMarkdown` tokenizer that centralizes inline precedence and lets each backend emit its own representation. Keep Web/AppKit render-specific behavior in the existing preview/export files.

**Tech Stack:** Swift 5, AppKit, SwiftUI, WebKit, XCTest, Xcode project target wiring.

---

### Task 1: Add A Pure Inline Tokenizer

**Files:**
- Create: `zMD/InlineMarkdown.swift`
- Modify: `zMD.xcodeproj/project.pbxproj`

- [ ] Create `InlineMarkdown.Token` with cases for `text`, `lineBreak`, `code`, `strong`, `emphasis`, `strikethrough`, `image`, and `link`.
- [ ] Implement `InlineMarkdown.tokenize(_:)` as a left-to-right scanner.
- [ ] Preserve current supported syntax only: backslash escapes, `<br>`, code spans, images, links, `**bold**`, `*italic*`, and `~~strike~~`.
- [ ] Add the file to the app target sources.
- [ ] Build with `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build`.

### Task 2: Use Tokens In HTML, Print, And DOCX Emitters

**Files:**
- Modify: `zMD/MarkdownParser.swift`
- Modify: `zMD/PrintManager.swift`
- Modify: `zMD/ExportManager.swift`

- [ ] Replace regex sequencing in `MarkdownParser.formatInlineHTML` with token emission.
- [ ] Preserve existing URL scheme filtering and attribute escaping for links/images.
- [ ] Replace print inline regex sequencing with token emission.
- [ ] Replace DOCX inline regex sequencing with token emission.
- [ ] Keep backend-specific output details unchanged where possible.
- [ ] Build after this task.

### Task 3: Add Focused Parser Tests

**Files:**
- Create: `zMDTests/InlineMarkdownTests.swift`
- Modify: `zMD.xcodeproj/project.pbxproj`

- [ ] Add a macOS XCTest target named `zMDTests`.
- [ ] Add tests for code-span precedence, mixed inline images, URL single escaping, task-list tokenization stability, and long-fence math protection through public export/parser helpers where exposed.
- [ ] Run `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'`.

### Task 4: Finish M5 Math Export Timeout Behavior

**Files:**
- Modify: `zMD/ExportManager.swift`

- [ ] Replace per-expression 5-second waits with one bounded group wait for all math renders in an export.
- [ ] Keep result ordering by index.
- [ ] Ensure late completions cannot mutate data read by the exporter after timeout.
- [ ] Build and run tests.

### Task 5: Finish M10 Raw HTML Export Safety

**Files:**
- Modify: `zMD/MarkdownParser.swift`
- Test: `zMDTests/InlineMarkdownTests.swift`

- [ ] Replace regex-only raw HTML sanitization with conservative safe handling.
- [ ] Preserve only a small allowlist of raw tags/attrs if practical; otherwise escape the raw block as text.
- [ ] Keep markdown-generated HTML links/images unaffected.
- [ ] Add tests for `/onclick`, encoded JavaScript schemes, and benign escaped raw HTML behavior.
- [ ] Build and run tests.

### Task 6: Finish M13 Replace Consistency

**Files:**
- Modify: `zMD/DocumentManager.swift`
- Modify: `zMD/ContentView.swift`

- [ ] Make replace controls use source match counts only.
- [ ] Keep rendered preview search navigation based on rendered counts when replace is not active.
- [ ] Ensure replace is unavailable in preview-only mode and source-backed in source/split modes.
- [ ] Build and run tests.

### Task 7: Finish L12 WebView Background Robustness

**Files:**
- Modify: `zMD/WebRenderer.swift`

- [ ] Move non-opaque WebView setup into a small helper.
- [ ] Use public properties where available.
- [ ] Guard the private fallback so failure cannot terminate render setup.
- [ ] Build and run tests.

### Task 8: Final Verification

**Files:**
- No source changes expected.

- [ ] Run `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build`.
- [ ] Run `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` if the test target is successfully added.
- [ ] Summarize closed, partially closed, and residual fable items.
