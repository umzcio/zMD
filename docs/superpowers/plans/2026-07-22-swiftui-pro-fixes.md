# SwiftUI Pro Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve all six approved SwiftUI Pro findings and ship zMD in strict Swift 6 language mode without dropping macOS 13 support.

**Architecture:** Keep the existing `ObservableObject` and AppKit integration architecture, but make UI-facing code Main Actor isolated and repair all strict-concurrency boundaries. Extract the large `ContentView` helper hierarchies into focused SwiftUI types, and centralize testable accessibility, motion, and Help-page policy without changing user-visible workflows.

**Tech Stack:** Swift 6.2+, SwiftUI, AppKit, WebKit, XCTest, Xcode 26, macOS 13 deployment target.

## Global Constraints

- Keep `MACOSX_DEPLOYMENT_TARGET = 13.0`.
- Use Swift 6 language mode supported by the installed Swift 6.2-or-later toolchain.
- Do not introduce third-party dependencies.
- Keep AppKit bridges where SwiftUI does not replace the existing text editor, window, file watcher, and WebKit behavior on macOS 13.
- Preserve public behavior, shortcuts, document state, scroll synchronization, and update behavior.
- Keep all existing tests passing and add focused tests for logic that can be tested without UI automation.

---

### Task 1: Accessibility, motion policy, and adaptive Help content

**Files:**
- Modify: `zMD/SearchBar.swift:99-126`
- Modify: `zMD/TabBar.swift:49-58`
- Modify: `zMD/SettingsManager.swift:32-65`
- Modify: `zMD/HelpView.swift:38-166`
- Create: `zMD/AccessibilityCopy.swift`
- Create: `zMD/HelpHTML.swift`
- Modify: `zMDTests/InlineMarkdownTests.swift`
- Modify: `zMD.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `AccessibilityCopy.matchCase`, `AccessibilityCopy.regularExpression`, and `AccessibilityCopy.toggleValue(_:)`.
- Produces: `Motion.layoutAnimation(reduceMotion:) -> Animation?`, used by `Motion.standard` and `Motion.morph`.
- Produces: `HelpHTML.content`, loaded by `HelpWebView`.

- [ ] **Step 1: Add focused failing tests for policy and generated content**

Add these XCTest methods to `InlineMarkdownTests`:

```swift
func testAccessibilityToggleCopyReportsState() {
    XCTAssertEqual(AccessibilityCopy.matchCase, "Match Case")
    XCTAssertEqual(AccessibilityCopy.regularExpression, "Use Regular Expression")
    XCTAssertEqual(AccessibilityCopy.toggleValue(true), "On")
    XCTAssertEqual(AccessibilityCopy.toggleValue(false), "Off")
}

func testReduceMotionDisablesLayoutAnimation() {
    XCTAssertNil(Motion.layoutAnimation(reduceMotion: true))
    XCTAssertNotNil(Motion.layoutAnimation(reduceMotion: false))
}

func testHelpHTMLSupportsDarkAppearance() {
    XCTAssertTrue(HelpHTML.content.contains("color-scheme: light dark"))
    XCTAssertTrue(HelpHTML.content.contains("prefers-color-scheme: dark"))
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-derived test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:zMDTests/InlineMarkdownTests/testAccessibilityToggleCopyReportsState \
  -only-testing:zMDTests/InlineMarkdownTests/testReduceMotionDisablesLayoutAnimation \
  -only-testing:zMDTests/InlineMarkdownTests/testHelpHTMLSupportsDarkAppearance
```

Expected: FAIL because `AccessibilityCopy`, `Motion.layoutAnimation(reduceMotion:)`, and `HelpHTML` do not exist.

- [ ] **Step 3: Implement the accessibility copy and attach semantic modifiers**

Create `AccessibilityCopy.swift`:

```swift
import Foundation

enum AccessibilityCopy {
    static let matchCase = "Match Case"
    static let regularExpression = "Use Regular Expression"

    static func toggleValue(_ isEnabled: Bool) -> String {
        isEnabled ? "On" : "Off"
    }
}
```

Update the two `SearchBar` buttons:

```swift
.accessibilityLabel(AccessibilityCopy.matchCase)
.accessibilityValue(AccessibilityCopy.toggleValue(isCaseSensitive))

.accessibilityLabel(AccessibilityCopy.regularExpression)
.accessibilityValue(AccessibilityCopy.toggleValue(isRegex))
```

Update the `TabBar` picker item:

```swift
Label(mode.rawValue, systemImage: mode.icon)
    .labelStyle(.iconOnly)
    .help(mode.rawValue)
```

- [ ] **Step 4: Implement testable Reduce Motion layout policy**

Update `Motion`:

```swift
static func layoutAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeInOut(duration: 0.2)
}

static var standard: Animation? {
    layoutAnimation(reduceMotion: reduceMotion)
}

static var morph: Animation? {
    reduceMotion ? nil : .easeInOut(duration: 0.3)
}
```

All existing `.animation(_:value:)` and `withAnimation(_:)` call sites accept optional animations, so no behavior changes when Reduce Motion is off.

- [ ] **Step 5: Extract and adapt the Help HTML**

Create `HelpHTML.swift` containing the existing document as `static let content`. Add this CSS without changing the Help copy:

```css
:root { color-scheme: light dark; }

@media (prefers-color-scheme: dark) {
    body { color: #f5f5f7; background-color: #1c1c1e; }
    h1, th, td { border-color: #48484a; }
    code, kbd, th { background-color: #2c2c2e; }
    kbd { border-color: #636366; }
}
```

Load it from `HelpView`:

```swift
webView.loadHTMLString(HelpHTML.content, baseURL: nil)
```

- [ ] **Step 6: Add the new source files to the app target and rerun focused tests**

Add `AccessibilityCopy.swift` and `HelpHTML.swift` as file references and Sources build files in `project.pbxproj`.

Run the command from Step 2.

Expected: PASS for all three focused tests.

- [ ] **Step 7: Commit the independently working UI policy fixes**

```bash
git add zMD/AccessibilityCopy.swift zMD/HelpHTML.swift zMD/SearchBar.swift \
  zMD/TabBar.swift zMD/SettingsManager.swift zMD/HelpView.swift \
  zMDTests/InlineMarkdownTests.swift zMD.xcodeproj/project.pbxproj
git commit -m "fix: improve SwiftUI accessibility and adaptive presentation"
```

---

### Task 2: Decompose `ContentView` into focused views

**Files:**
- Modify: `zMD/ContentView.swift`
- Create: `zMD/DropHandler.swift`
- Create: `zMD/WelcomeView.swift`
- Create: `zMD/PressableButtonStyle.swift`
- Create: `zMD/RecentFileButtonStyle.swift`
- Create: `zMD/EmptyDocumentView.swift`
- Create: `zMD/NormalContentView.swift`
- Create: `zMD/FocusModeContentView.swift`
- Create: `zMD/SplitPaneHeader.swift`
- Create: `zMD/DocumentViewModeContent.swift`
- Create: `zMD/SourceEditorWithMinimap.swift`
- Modify: `zMD.xcodeproj/project.pbxproj`

**Interfaces:**
- `NormalContentView(showOutline:selectedHeadingId:)` consumes the existing environment managers.
- `FocusModeContentView(selectedHeadingId:)` consumes the existing environment managers.
- `DocumentViewModeContent(document:selectedHeadingId:)` owns preview/source/synchronized-split composition for one document.
- `SplitPaneHeader(name:mode:onClose:)` owns only the two-file split header.
- `SourceEditorWithMinimap` retains the existing binding and scroll/search callback signature exactly.

- [ ] **Step 1: Run the full existing test suite as the green refactor baseline**

Run:

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-derived test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS with 45 tests after Task 1 adds three tests.

- [ ] **Step 2: Move non-workspace support types without changing their bodies**

Move these exact current declarations into the named files, preserving every stored property, modifier, callback, and comment:

```text
ContentView.swift:322-387  -> DropHandler.swift
ContentView.swift:389-588  -> WelcomeView.swift
ContentView.swift:590-598  -> PressableButtonStyle.swift
ContentView.swift:600-616  -> RecentFileButtonStyle.swift
ContentView.swift:618-634  -> EmptyDocumentView.swift
ContentView.swift:748-797  -> SourceEditorWithMinimap.swift
```

Each destination begins with `import SwiftUI`; `DropHandler.swift` also imports `UniformTypeIdentifiers`. Delete the moved declarations from `ContentView.swift` so each type has one definition.

- [ ] **Step 3: Extract normal and focus workspace views**

Replace the `normalContent()` and `focusModeContent()` methods with:

```swift
NormalContentView(
    showOutline: $showOutline,
    selectedHeadingId: $selectedHeadingId
)

FocusModeContentView(selectedHeadingId: $selectedHeadingId)
```

Both extracted views declare the existing managers through `@EnvironmentObject` and pass bindings downward rather than creating duplicate state.

- [ ] **Step 4: Extract split header and document mode composition**

Create these exact top-level interfaces:

```swift
struct SplitPaneHeader: View {
    let name: String
    @Binding var mode: SplitPaneMode
    let onClose: (() -> Void)?
}

struct DocumentViewModeContent: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @EnvironmentObject private var settings: SettingsManager
    let document: MarkdownDocument
    @Binding var selectedHeadingId: String?
}
```

Move the existing `viewModeContent`, preview, source, and synchronized split branches into `DocumentViewModeContent.body`. Preserve all search, scroll-position, render-tick, and scroll-sync arguments.

- [ ] **Step 5: Register all new Swift files in the app target**

Add one `PBXFileReference`, one `PBXBuildFile`, one group child, and one Sources entry for every created Swift file. Keep `ContentView.swift` registered exactly once.

- [ ] **Step 6: Run tests and a Debug build after the mechanical refactor**

Run:

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-derived test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-derived build CODE_SIGNING_ALLOWED=NO
```

Expected: both commands PASS; no duplicate-type or missing-file errors.

- [ ] **Step 7: Commit the independently verified view decomposition**

```bash
git add zMD/ContentView.swift zMD/DropHandler.swift zMD/WelcomeView.swift \
  zMD/PressableButtonStyle.swift zMD/RecentFileButtonStyle.swift \
  zMD/EmptyDocumentView.swift zMD/NormalContentView.swift \
  zMD/FocusModeContentView.swift zMD/SplitPaneHeader.swift \
  zMD/DocumentViewModeContent.swift zMD/SourceEditorWithMinimap.swift \
  zMD.xcodeproj/project.pbxproj
git commit -m "refactor: decompose the main SwiftUI workspace"
```

---

### Task 3: Make AppKit lifecycles valid under Swift 6 isolation

**Files:**
- Modify: `zMD/FileWatcher.swift`
- Modify: `zMD/DirectoryWatcher.swift`
- Modify: `zMD/SettingsView.swift`
- Modify: `zMD/MinimapView.swift`
- Modify: `zMD/SourceEditorView.swift`
- Modify: `zMD/MarkdownTextView.swift`
- Modify: `zMD/ToastManager.swift`

**Interfaces:**
- Existing public and delegate interfaces remain unchanged.
- AppKit subclasses and representable coordinators stay Main Actor isolated.
- Timer and framework callbacks re-enter the Main Actor before touching UI state.

- [ ] **Step 1: Reproduce the strict Swift 6 failures**

Run:

```bash
xcodebuild -quiet -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-swift6 build -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO SWIFT_VERSION=6 SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
```

Expected: FAIL with actor-isolation diagnostics in the listed AppKit lifecycle files.

- [ ] **Step 2: Make deinitialization actor-safe**

Use Swift 6.2 isolated deinitializers for types whose cleanup touches Main Actor state:

```swift
isolated deinit {
    teardown()
}
```

For types without a `teardown()` method, keep their existing cleanup statements inside `isolated deinit`. Do not remove observer, timer, dispatch-source, or event-monitor cleanup.

- [ ] **Step 3: Re-enter the Main Actor from Sendable callbacks**

Wrap callbacks that touch AppKit or isolated state:

```swift
Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
    Task { @MainActor [weak self] in
        self?.performUpdate()
    }
}
```

Apply this pattern to the compiler-reported timer, FSEvents, and delegate callbacks only; preserve existing weak captures and cancellation behavior.

- [ ] **Step 4: Iterate the strict build until this file group is clean**

Run the Step 1 command after each compiler-guided batch.

Expected: no remaining errors or warnings originating from the seven listed files.

- [ ] **Step 5: Run the normal suite to catch lifecycle regressions**

Run:

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-derived test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS, including file watcher and folder lifecycle tests.

- [ ] **Step 6: Commit the lifecycle concurrency fixes**

```bash
git add zMD/FileWatcher.swift zMD/DirectoryWatcher.swift zMD/SettingsView.swift \
  zMD/MinimapView.swift zMD/SourceEditorView.swift zMD/MarkdownTextView.swift \
  zMD/ToastManager.swift
git commit -m "fix: isolate AppKit lifecycles for Swift 6"
```

---

### Task 4: Resolve remaining strict-concurrency boundaries and enable Swift 6

**Files:**
- Modify: `zMD/AlertManager.swift`
- Modify: `zMD/ContentView.swift`
- Modify: `zMD/DocumentManager.swift`
- Modify: `zMD/ExportManager.swift`
- Modify: `zMD/FolderManager.swift`
- Modify: `zMD/SettingsManager.swift`
- Modify: `zMD/UpdateManager.swift`
- Modify: `zMD/zMDApp.swift`
- Modify: `zMD.xcodeproj/project.pbxproj`

**Interfaces:**
- Existing manager, parser, export, update, and renderer call sites remain source-compatible.
- Background helpers accept immutable Sendable inputs and return immutable values.
- UI state mutation occurs on the Main Actor.

- [ ] **Step 1: Run a clean strict diagnostic build**

Run:

```bash
xcodebuild -quiet -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-swift6-clean clean build -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO SWIFT_VERSION=6 SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
```

Expected: any remaining diagnostics identify the exact manager/background boundaries still requiring migration.

- [ ] **Step 2: Repair each remaining boundary without suppressing checking**

Use these allowed patterns, selected by responsibility:

```swift
Task { @MainActor in
    isolatedManager.publish(result)
}
```

```swift
nonisolated static func compute(input: SendableInput) -> SendableOutput {
    // Pure background computation with no shared mutable state.
}
```

```swift
let result = await Task.detached(priority: .userInitiated) {
    pureSendableComputation(input)
}.value
```

Prefer `Task` and async functions; do not add `@unchecked Sendable` unless a framework-owned object is externally synchronized and the invariant is documented beside the conformance.

- [ ] **Step 3: Prove the override build is clean**

Run the Step 1 command without `clean`.

Expected: `BUILD SUCCEEDED`, with no Swift concurrency diagnostics.

- [ ] **Step 4: Enable Swift 6 settings in every app and test build configuration**

Replace each `SWIFT_VERSION = 5.0;` and add:

```text
SWIFT_VERSION = 6.0;
SWIFT_STRICT_CONCURRENCY = complete;
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
```

Keep every `MACOSX_DEPLOYMENT_TARGET = 13.0;` unchanged.

- [ ] **Step 5: Build and test using project settings only**

Run:

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-derived build CODE_SIGNING_ALLOWED=NO
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-derived test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both PASS without command-line Swift language or isolation overrides.

- [ ] **Step 6: Commit the Swift 6 migration**

```bash
git add zMD zMDTests zMD.xcodeproj/project.pbxproj
git commit -m "build: migrate zMD to strict Swift 6"
```

---

### Task 5: Final verification and branch audit

**Files:**
- Review: all files changed from `master...HEAD`

**Interfaces:**
- Consumes: all deliverables from Tasks 1-4.
- Produces: a verified bug branch ready for integration.

- [ ] **Step 1: Run the complete test suite from a fresh derived-data directory**

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-final test -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all 45 tests PASS.

- [ ] **Step 2: Run a clean Debug build using only committed project settings**

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  -derivedDataPath /tmp/zmd-final clean build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED` with no source warnings.

- [ ] **Step 3: Audit the final diff and project file**

```bash
git diff --check master...HEAD
git diff --stat master...HEAD
git status --short
rg -n 'MACOSX_DEPLOYMENT_TARGET = 13.0|SWIFT_VERSION = 6.0|SWIFT_STRICT_CONCURRENCY = complete|SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor' zMD.xcodeproj/project.pbxproj
```

Expected: no whitespace errors, a clean worktree, macOS 13 retained, and Swift 6 settings present in all relevant configurations.

- [ ] **Step 4: Review each approved finding against the implementation**

Confirm by source inspection:

```text
1. Strict Swift 6 build passes.
2. Search toggles expose labels and values.
3. View-mode segments use semantic Label values.
4. Reduce Motion disables layout movement.
5. Help HTML supports effective dark appearance.
6. ContentView no longer owns the extracted view types or large view-builder helpers.
```

- [ ] **Step 5: Record the final command results in the handoff**

Report the exact test count, clean-build status, branch name, and any non-source Xcode environment warnings without modifying production files.
