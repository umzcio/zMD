# Editable Two-File Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each pane of zMD's two-file side-by-side split independently toggle between Rendered (preview) and Edit (source editor), so a user can edit either or both files and reliably copy/paste between them.

**Architecture:** Add two per-pane mode fields to `DocumentManager` (the single source of truth for split state). In `ContentView`'s two-file split block, each pane switches between the existing, already document-parameterized `markdownPreview(for:)` and `sourceEditor(for:)` helpers based on its pane mode. A small shared `splitPaneHeader` subview carries the file name, a `Rendered | Edit` segmented toggle, and an optional close button.

**Tech Stack:** Swift, SwiftUI + AppKit, macOS 13+ deployment target. Spec: `docs/superpowers/specs/2026-06-16-editable-two-file-split-design.md`.

## Global Constraints

- macOS deployment target is **13.0** — no macOS 14+ APIs without an `@available` check. Segmented `Picker` and `switch`-in-`@ViewBuilder` are macOS 11+ and therefore allowed.
- `onChange(of:)` must use the `{ _ in }` (one-parameter) form, NOT the zero-parameter form (macOS 13 compatibility). (Not expected in this plan, but applies if added.)
- **No test target exists** in this project (only the `zMD` app target). Verification is therefore: (a) a clean `xcodebuild` and (b) the scripted manual checks in each task. Do NOT add an XCTest target — that is out of scope and unrelated scaffolding.
- Build command (must stay green after every task):
  `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build`
- Reuse the **non-synced** `sourceEditor(for:)` helper for split panes, NOT `syncedSourceEditor(for:)` — the latter drives the global single-file scroll-sync state and must not run in the two-file layout.
- Adding new Swift files requires editing the `.pbxproj`; this plan adds **no new files**, only edits, to avoid that.

---

### Task 1: Per-pane split mode state on DocumentManager

**Files:**
- Modify: `zMD/DocumentManager.swift` (split-view `@Published` block near line 14-16; `openInSplitView`/`closeSplitView` near 421-430; add `SplitPaneMode` enum near the `ViewMode` enum at line 884)
- Test: none (no test target — verified by build + Task 3 manual checks)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SplitPaneMode: String, CaseIterable { case rendered; case edit }`
  - `DocumentManager.splitPrimaryMode: SplitPaneMode` (`@Published`, default `.rendered`)
  - `DocumentManager.splitSecondaryMode: SplitPaneMode` (`@Published`, default `.rendered`)
  - `openInSplitView(documentId:)` and `closeSplitView()` both reset the two modes to `.rendered`.

- [ ] **Step 1: Add the `SplitPaneMode` enum**

In `zMD/DocumentManager.swift`, immediately above the existing `enum ViewMode: String, CaseIterable {` (line 884), add:

```swift
enum SplitPaneMode: String, CaseIterable {
    case rendered
    case edit
}

```

- [ ] **Step 2: Add the two `@Published` pane-mode fields**

In the `// Split view` state block (currently):

```swift
    // Split view
    @Published var secondaryDocumentId: UUID?
    @Published var isSplitViewActive: Bool = false
```

change it to:

```swift
    // Split view
    @Published var secondaryDocumentId: UUID?
    @Published var isSplitViewActive: Bool = false
    // Per-pane mode for the two-file split. Each pane independently shows the rendered preview
    // or an editable source editor. Reset to .rendered whenever the split is opened or closed.
    @Published var splitPrimaryMode: SplitPaneMode = .rendered
    @Published var splitSecondaryMode: SplitPaneMode = .rendered
```

- [ ] **Step 3: Reset modes on open and close**

Replace the existing `openInSplitView`/`closeSplitView` (lines 421-430) with:

```swift
    func openInSplitView(documentId: UUID) {
        guard documentId != selectedDocumentId else { return }
        secondaryDocumentId = documentId
        isSplitViewActive = true
        splitPrimaryMode = .rendered
        splitSecondaryMode = .rendered
    }

    func closeSplitView() {
        secondaryDocumentId = nil
        isSplitViewActive = false
        splitPrimaryMode = .rendered
        splitSecondaryMode = .rendered
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add zMD/DocumentManager.swift
git commit -m "feat: add per-pane mode state for the two-file split

Adds SplitPaneMode (.rendered/.edit) and splitPrimaryMode/splitSecondaryMode
on DocumentManager, reset to .rendered on openInSplitView/closeSplitView.
Consumed by the two-file split UI in the next task.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Per-pane Rendered/Edit toggle in the two-file split UI

**Files:**
- Modify: `zMD/ContentView.swift` (two-file split block, lines 239-283; add `splitPaneHeader` to the `extension ContentView` near the other helper views around line 610)
- Test: none (no test target — verified by build + Task 3 manual checks)

**Interfaces:**
- Consumes: `DocumentManager.splitPrimaryMode`, `DocumentManager.splitSecondaryMode`, `SplitPaneMode` (Task 1); existing `markdownPreview(for:)`, `sourceEditor(for:)`, `MarkdownDocument.name`, `documentManager.closeSplitView()`.
- Produces: `splitPaneHeader(name:mode:onClose:) -> some View` (a header bar: file-name + `Rendered | Edit` segmented toggle + optional close button).

- [ ] **Step 1: Add the shared `splitPaneHeader` helper**

In `zMD/ContentView.swift`, inside `extension ContentView { … }` (the block that already contains `markdownPreview(for:)` and `sourceEditor(for:)`, starting around line 610), add this method:

```swift
    /// Header bar for a two-file split pane: file name, a Rendered|Edit toggle bound to that
    /// pane's mode, and an optional close button (used only on the secondary pane).
    @ViewBuilder
    func splitPaneHeader(name: String, mode: Binding<SplitPaneMode>, onClose: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            Picker("", selection: mode) {
                Text("Rendered").tag(SplitPaneMode.rendered)
                Text("Edit").tag(SplitPaneMode.edit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
    }
```

- [ ] **Step 2: Restructure the two-file split block to switch each pane on its mode**

Replace the entire `HSplitView { … }` block at `ContentView.swift:242-283` (the one inside `if documentManager.isSplitViewActive, let secondaryId …`) with:

```swift
                        HSplitView {
                            // Primary (left) pane
                            VStack(spacing: 0) {
                                splitPaneHeader(
                                    name: document.name,
                                    mode: $documentManager.splitPrimaryMode,
                                    onClose: nil
                                )
                                Divider()
                                switch documentManager.splitPrimaryMode {
                                case .rendered:
                                    markdownPreview(for: document)
                                case .edit:
                                    sourceEditor(for: document)
                                }
                            }

                            // Secondary (right) pane
                            VStack(spacing: 0) {
                                splitPaneHeader(
                                    name: secondaryDoc.name,
                                    mode: $documentManager.splitSecondaryMode,
                                    onClose: { documentManager.closeSplitView() }
                                )
                                Divider()
                                switch documentManager.splitSecondaryMode {
                                case .rendered:
                                    MarkdownTextView(
                                        content: secondaryDoc.content,
                                        baseURL: secondaryDoc.url,
                                        directoryBookmark: secondaryDoc.directoryBookmarkData,
                                        scrollToHeadingId: .constant(nil),
                                        searchText: "",
                                        currentMatchIndex: 0,
                                        searchMatches: [],
                                        fontStyle: settings.fontStyle,
                                        zoomLevel: settings.zoomLevel,
                                        initialScrollPosition: documentManager.getScrollPosition(for: secondaryDoc.url),
                                        onScrollPositionChanged: { position in
                                            documentManager.setScrollPosition(position, for: secondaryDoc.url)
                                        },
                                        onMatchCountChanged: nil
                                    )
                                case .edit:
                                    sourceEditor(for: secondaryDoc)
                                }
                            }
                        }
```

Note: the secondary `.rendered` branch is the **same** `MarkdownTextView(...)` configuration that was there before (empty search, `.constant(nil)` heading), preserving today's behavior; only the header and the mode switch are new.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

(If the build reports a `@ViewBuilder` ambiguity on the `switch`, confirm each `case` returns exactly one view — the code above already does.)

- [ ] **Step 4: Commit**

```bash
git add zMD/ContentView.swift
git commit -m "feat: per-pane Rendered/Edit toggle in the two-file split

Each pane of the two-file split now has a header with a Rendered|Edit
segmented toggle. Rendered shows the preview; Edit shows the editable
sourceEditor bound to that document. The left pane gains a header; the
secondary rendered branch keeps its existing configuration.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Acceptance verification (build + manual smoke test)

**Files:**
- Modify: none expected. If a defect is found, fix it minimally in the relevant file and re-run this task; otherwise this task adds no code.
- Test: manual (no test target). Use the `run` skill to launch the app and the `verify` skill to confirm behavior.

**Interfaces:**
- Consumes: the running app built from Tasks 1-2.
- Produces: a verified feature + a noted follow-up (preview-mode copy remains out of scope).

- [ ] **Step 1: Clean build from scratch**

Run: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug clean build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Launch the built app**

Run: `open "$(xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $2}')/zMD.app"`
(Or simpler if a build is already in DerivedData: open the `zMD.app` under the project's `build/Debug` or DerivedData `Build/Products/Debug`.)
Expected: zMD launches.

- [ ] **Step 3: Reproduce the original scenario and verify the toggles exist**

Manual steps:
1. Open two markdown files (⌘O twice, or drag two `.md` files onto the window).
2. Put them in the two-file side-by-side split (the existing "open in split view" action that sets `secondaryDocumentId`).
3. Confirm **each pane now has a header with a `Rendered | Edit` toggle**, and both default to **Rendered** (panes look exactly like before this change).

Expected: two rendered panes, each with its own toggle; left pane now has a header too.

- [ ] **Step 4: Acceptance test — edit + copy/paste between two files (the original complaint)**

Manual steps:
1. Set the **left** pane to **Edit** and the **right** pane to **Edit**.
2. Confirm both panes are now editable source editors showing each file's markdown.
3. In the left editor, select a block of text, press ⌘C.
4. Click into the right editor, place the caret, press ⌘V.
5. Verify the pasted text matches the copied text **exactly** (no dropped/duplicated/auto-closed characters).
6. Type in each editor and confirm the change persists to the correct file: press ⌘S in each and confirm the "File saved" toast; reopen to confirm.

Expected: reliable copy/paste between the two editable panes; edits save to the correct files.

- [ ] **Step 5: Coexistence checks — two live editors must not interfere**

Manual steps (this is the risk flagged in the spec):
1. **Autocomplete isolation:** trigger autocomplete in the left editor (type a partial token); confirm the popup appears over the left editor only and does not appear or steal focus in the right editor.
2. **Undo isolation:** make an edit in the left editor, press ⌘Z; confirm only the left file is affected and the right editor's content is unchanged.
3. **Focus/caret:** click between the two editors; confirm the caret/first-responder moves correctly and typing goes to the focused pane only.

Expected: each editor's autocomplete, undo, and caret are independent.

- [ ] **Step 6: Mode-reset behavior**

Manual steps:
1. With both panes in Edit, close the split (the ✕ on the secondary header).
2. Re-open the two-file split.
3. Confirm both panes start in **Rendered** again (the reset in `openInSplitView`/`closeSplitView`).

Expected: a freshly opened split is Rendered/Rendered.

- [ ] **Step 7: Record the result and the known follow-up**

If all checks pass: note in the PR/commit that copying from a **Rendered** pane is still the separate known-incomplete selection feature and remains out of scope (users copy reliably by switching that pane to Edit).

If any check fails: STOP, apply the systematic-debugging skill, fix minimally, and re-run Steps 1-6. Do not expand scope beyond making the acceptance checks pass.

- [ ] **Step 8: Commit any fixes (only if Step 7 required changes)**

```bash
git add -A
git commit -m "fix: <specific issue found during acceptance verification>

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Per-pane independent Rendered/Edit toggle → Task 1 (state) + Task 2 (UI). ✓
- Default Rendered, reset on open/close → Task 1 Step 3; verified Task 3 Step 6. ✓
- Edit pane = editable source editor saving to the right file → Task 2 (`sourceEditor(for:)`); verified Task 3 Step 4. ✓
- Non-synced editor to avoid scroll-sync contention → Task 2 uses `sourceEditor(for:)` (not `syncedSourceEditor`). ✓ (stated in Global Constraints.)
- Left pane gains a header; secondary rendered branch unchanged → Task 2 Step 2. ✓
- Out of scope: preview-mode copy, 3-mode pane, scroll-sync changes → not implemented; preview-copy noted in Task 3 Step 7. ✓
- Risk: two coexisting editors → Task 3 Step 5 explicit checks. ✓
- Acceptance test (copy/paste) → Task 3 Step 4. ✓

**Placeholder scan:** No TBD/TODO; all code steps contain complete code; manual steps are concrete. The only "fix the issue found" step (Task 3 Step 8) is intentionally conditional on an acceptance failure, not a placeholder for unspecified work.

**Type consistency:** `SplitPaneMode` (`.rendered`/`.edit`), `splitPrimaryMode`/`splitSecondaryMode`, and `splitPaneHeader(name:mode:onClose:)` are named identically everywhere they appear across Tasks 1-2. Helper names `markdownPreview(for:)` and `sourceEditor(for:)` match the existing code.
