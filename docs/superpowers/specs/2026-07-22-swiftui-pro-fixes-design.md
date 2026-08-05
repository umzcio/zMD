# SwiftUI Pro Fixes Design

## Goal

Resolve all six findings from the July 22 SwiftUI Pro review while preserving zMD's existing behavior, macOS 13 deployment target, AppKit editor integrations, and passing test suite.

## Scope

The implementation covers:

1. Move the application and tests to Swift 6 language mode with complete strict concurrency and Main Actor default isolation.
2. Give the search option buttons meaningful VoiceOver labels and explicit on/off values.
3. Give each image-only view-mode picker segment a semantic text label.
4. Prevent large layout movement when Reduce Motion is enabled while retaining small opacity feedback where appropriate.
5. Make the embedded Help page follow the effective light or dark appearance.
6. Split `ContentView.swift` into focused SwiftUI view files instead of using large `some View` helper methods.

## Constraints

- Keep `MACOSX_DEPLOYMENT_TARGET = 13.0`.
- Use Swift 6 language mode supported by the installed Swift 6.2-or-later toolchain.
- Do not introduce third-party dependencies.
- Keep AppKit bridges where SwiftUI does not replace the existing text editor, window, file watcher, and WebKit behavior on macOS 13.
- Preserve public behavior, shortcuts, document state, scroll synchronization, and update behavior.
- Keep all existing tests passing and add focused tests for logic that can be tested without UI automation.

## Approaches Considered

### 1. Incremental Swift 6 migration with existing observation architecture

Set Main Actor default isolation and strict concurrency, then repair actor boundaries, timer callbacks, cleanup paths, and background work without replacing every `ObservableObject`. This is the selected approach because it removes the proven compiler failures while keeping the change bounded and compatible with macOS 13.

### 2. Full Observation framework migration

Replace `ObservableObject`, `@Published`, and environment objects with `@Observable`, `@State`, `@Bindable`, and typed environment values at the same time. This would be more modern but substantially expands risk across nearly every view and manager, so it is intentionally deferred.

### 3. Raise the deployment target and adopt only newest APIs

Raise the app to a newer macOS release, then adopt newer `Tab`, `onChange`, and presentation APIs. This would simplify some modernization but would drop supported users and violates the deployment constraint.

## Architecture

### Swift concurrency

UI-facing managers and AppKit coordinators remain Main Actor isolated. Background filesystem, regex, export, and update work will use structured concurrency or explicitly safe nonisolated helpers that return immutable values. Callbacks that mutate UI state hop to the Main Actor. Cleanup will be explicit where actor-isolated methods cannot safely be called from a nonisolated deinitializer.

The project will enable:

```text
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
```

These settings will be applied to application and test configurations only after the code compiles cleanly under the same command-line overrides.

### Accessibility

The search buttons retain their compact visual labels but expose `Match Case` and `Use Regular Expression` plus `On` or `Off` values. The view-mode picker uses `Label(mode.rawValue, systemImage:)` with icon-only visual styling so assistive technologies receive each mode name.

### Motion

The shared motion tokens will distinguish small feedback from layout motion. When Reduce Motion is enabled, layout animations become disabled and movement transitions become opacity transitions. Hover and press feedback remains subtle and nonessential.

### Help appearance

The Help HTML declares support for light and dark color schemes and supplies dark-mode colors for the page, separators, code, keyboard keys, and table headings. The existing effective appearance inherited by `WKWebView` selects the matching media query.

### View decomposition

`ContentView` remains the top-level coordinator for overlays, notifications, drag-and-drop, and the selected document. Focused files own the welcome screen, empty-document state, drop handling, editor/minimap composition, normal workspace layout, and split-pane presentation. Inputs are explicit bindings, observable managers, and closures; extracted views do not duplicate source-of-truth state.

## Error Handling

- Swift concurrency changes must preserve current user-visible alerts and should not replace failures with logging-only behavior.
- Cancellation of delayed motion, search, highlighting, and scroll-sync work must leave state in a valid neutral state.
- Background filesystem and update work must publish results only when its existing generation or identity checks still match.

## Testing

1. Run the existing macOS suite with code signing disabled.
2. Add focused tests for semantic helper values where practical, including motion policy and Help color-scheme content.
3. Run a strict Swift 6 build with Main Actor default isolation before changing project settings; it must pass.
4. Run the normal project build and all tests after changing settings.
5. Confirm the worktree contains only intended source, project, test, and documentation changes.

## Success Criteria

- The six reviewed findings are resolved.
- The project builds in Swift 6 mode with complete concurrency checking and Main Actor default isolation.
- All tests pass on macOS.
- The app still targets macOS 13.
- No third-party dependencies are added.
