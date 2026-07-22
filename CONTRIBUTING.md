# Contributing to zMD

Thanks for your interest in zMD — a native SwiftUI/AppKit markdown editor for
macOS. Contributions of all kinds are welcome: bug reports, fixes, features,
and documentation.

## Getting started

**Requirements:** macOS 13+, Xcode 15+.

```bash
git clone https://github.com/umzcio/zMD.git
cd zMD
open zMD.xcodeproj        # then ⌘R
```

Or from the command line:

```bash
# Build
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build

# Run the tests
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test \
  -destination 'platform=macOS'
```

There are no external dependencies — no SwiftPM packages, no CocoaPods. The
only web content is Mermaid/KaTeX, loaded in a hidden WKWebView.

A clean build produces **zero warnings**. Please keep it that way.

## Project layout

The architecture is documented in [CLAUDE.md](CLAUDE.md) (it doubles as the
developer guide). The short version:

- `DocumentManager.swift` — central document state (tabs, save/load, dirty
  tracking). Always go through its methods; never mutate `openDocuments`
  directly.
- `MarkdownParser.swift` — the single source of truth for block-level
  parsing. Preview **and** all exports consume its `[Element]` output.
- `InlineMarkdown.swift` — the shared inline tokenizer (bold/italic/code/
  links/images/strikethrough). All four render backends (preview, HTML,
  DOCX, print) route through it.
- `MarkdownTextView.swift` — the NSTextView-based preview renderer.
- `ExportManager.swift` — PDF/HTML/RTF/DOCX export.

### Adding new markdown syntax

Rendering and export must stay in sync:

1. Add a case to `MarkdownParser.Element` and parsing logic in
   `MarkdownParser.parse()` (block-level) or a token in
   `InlineMarkdown.tokenize()` (inline).
2. Add HTML conversion in `MarkdownParser.elementToHTML()`.
3. Add preview rendering in `MarkdownTextView`'s `renderElement()` dispatch.
4. Add DOCX/print handling in `ExportManager` / `PrintManager` if the
   element needs backend-specific output.
5. Add a test in `zMDTests/` covering the new syntax.

## Code conventions

- Match the surrounding style; the codebase is plain Swift with no linter
  config (yet).
- **Deployment target is macOS 13.** No macOS 14+ APIs without an
  `if #available` check. Notably, `onChange(of:)` must use the
  one-parameter `{ _ in }` form — the zero-parameter form is macOS 14+.
- Singletons (`DocumentManager.shared`, etc.) are observed with
  `@ObservedObject`, not `@StateObject`, since they are pre-existing shared
  instances.
- Comments should state invariants the code can't express — not narrate fix
  history.

## Submitting changes

1. Fork and create a topic branch off `master`.
2. Keep commits focused; explain *why* in the body when it isn't obvious.
3. Before opening a PR:
   - `xcodebuild … build` succeeds with no new warnings
   - `xcodebuild … test` passes
   - If you touched rendering or export, manually spot-check a markdown
     fixture in preview **and** at least one export format (they share the
     parser, but backend-specific bugs are the most common regression).
4. Open a PR against `master` with a clear description of the behavior
   change.

## Reporting bugs

Open an issue at <https://github.com/umzcio/zMD/issues> with:

- macOS version and zMD version (zMD → About, or
  `defaults read /Applications/zMD.app/Contents/Info.plist CFBundleShortVersionString`)
- Steps to reproduce — a minimal markdown snippet that triggers the bug is
  worth a thousand words
- What you expected vs. what happened

## Releases

Releases are cut by the maintainer (signed, notarized, stapled DMG via
`scripts/build-dmg.sh`). Contributors don't need signing credentials — an
unsigned Debug build is fine for development.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE.md).
