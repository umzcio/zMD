# Plan 012: Bump pinned Mermaid/KaTeX CDN versions and establish an update cadence

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD/SettingsManager.swift`
> On a mismatch, re-read the live `CDN` enum before proceeding — a version
> may already have moved since this plan was written.

## Status

- **Priority**: P2
- **Effort**: S–M (the version bump itself is S; establishing a recurring
  check process is the M part and is mostly documentation/process, not code)
- **Risk**: LOW–MED — a KaTeX/Mermaid version bump can change rendering
  output subtly; needs a visual check on real math/diagram fixtures before
  landing.
- **Depends on**: none
- **Category**: dependency
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

Both `mermaid` (pinned at `10.9.1`) and `katex` (pinned at `0.16.9`) are
locked with exact-version URLs and Subresource Integrity (SRI) hashes,
consumed identically by both the live preview (`WebRenderer.swift`) and
exported HTML (`MarkdownParser.toHTML`). The pinning + SRI is genuinely good
practice — it stops a compromised CDN or MITM from silently serving
different code — but it also means a security patch in either library
**cannot land without a manual, deliberate version+hash edit**. There is
currently no process ensuring that edit ever happens; the pin can age
indefinitely. As of this plan's writing both versions are roughly two years
behind current releases. Note: this is a low-urgency finding in practice —
KaTeX runs with default `trust:false` and Mermaid 10 defaults to
`securityLevel:'strict'`, so the *current* exposure from staying pinned is
about missing bug/security fixes, not an active vulnerability — but the
missing update *path* is the actual thing worth fixing here.

## Current state

```swift
// zMD/SettingsManager.swift:48-65 (CDN enum, both consumers documented in its own comment)
/// CDN resource URLs for preview/export scripts. Both preview (WebRenderer) and exported HTML
/// (MarkdownParser.toHTML) reference the same strings — defining them once eliminates version
/// drift between the two consumers.
enum CDN {
    // S2: pin Mermaid to an exact version (was the floating `mermaid@10`, which auto-adopted any
    // new 10.x without review) and carry a Subresource Integrity hash for every resource. The
    // `integrity` attribute makes the browser / WKWebView refuse a tampered script instead of
    // executing it — important because these run inside the unsandboxed app's WebView and in any
    // exported HTML opened by others. Hashes are the sha384 of the pinned files served by jsDelivr.
    static let mermaidJS = "https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"
    static let mermaidJSIntegrity = "sha384-WmdflGW9aGfoBdHc4rRyWzYuAjEmDwMdGdiPNacbwfGKxBW/SO6guzuQ76qjnSlr"
    static let katexCSS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css"
    static let katexCSSIntegrity = "sha384-n8MVd4RsNIU0tAv4ct0nTaAbDJwPJzDEaqSD1odI+WdtXRGWt2kTvGFasHpSy3SV"
    static let katexJS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"
    static let katexJSIntegrity = "sha384-XjKyOOlGwcjNTAIQHIpgOno0Hl1YQqzUOEleOLALmuqehneUG+vnGctmUb0ZY0l8"
    static let katexAutoRenderJS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"
    static let katexAutoRenderJSIntegrity = "sha384-+VBxd3r6XgURycqtZ117nYw44OOcIax56Z4dCRWbxyPt0Koah1uHoK0o4+/RRE05"
}
```

Both preview (`WebRenderer.swift`, references `CDN.mermaidJS` /
`CDN.katexJS` etc.) and exported HTML (`MarkdownParser.swift:456-464`,
already read in this repo's audit) consume these same constants — this is
the mechanism that keeps preview and export from drifting from each other;
preserve it (do not hardcode a version string in a second place).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch current published version | `curl -s https://data.jsdelivr.com/v1/packages/npm/mermaid | head -50` (or check https://www.jsdelivr.com/package/npm/mermaid and https://www.jsdelivr.com/package/npm/katex directly) | shows latest version tags |
| Compute SRI hash for a pinned file | `curl -s <file-url> \| openssl dgst -sha384 -binary \| openssl base64 -A` then prefix with `sha384-` | produces a hash string matching jsDelivr's own published integrity values |
| Build | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |

You will need network access to jsDelivr to determine the current version
and compute the new SRI hashes — if you don't have that access as an
executor, stop after Step 1 and report the target versions for a human (or
a network-capable executor) to complete Steps 2–4.

## Scope

**In scope**:
- `zMD/SettingsManager.swift` — the `CDN` enum only.

**Out of scope**:
- Any code that *consumes* `CDN.*` (`WebRenderer.swift`,
  `MarkdownParser.swift`) — they reference the constants generically and
  shouldn't need changes purely from a version bump, unless the new
  major/minor version changed an API this app calls (e.g. Mermaid's
  `mermaid.initialize()` call signature, or KaTeX's `renderMath`/auto-render
  config options) — if so, that's a bigger, riskier change than this plan
  scoped for; see STOP conditions.
- Establishing actual recurring automation (e.g. a scheduled GitHub Action
  that checks for new versions and opens a PR, à la Dependabot/Renovate) —
  this plan documents the *manual* process and does the *one* version bump;
  automating the check itself is a reasonable future plan but is a
  meaningfully bigger scope (CI infrastructure) than "bump two version
  strings," so it's intentionally not bundled here. Note it in your final
  report as a natural follow-up if the plan owner wants it.

## Git workflow

- Branch: `advisor/012-cdn-dependency-bump`
- One commit for the version bump.

## Steps

### Step 1: Determine current stable versions

Check the latest stable (non-prerelease) versions of `mermaid` and `katex`
on npm/jsDelivr. Do not jump to a prerelease/beta tag. If Mermaid has had a
major version bump (e.g. 10.x → 11.x) since this plan was written, note
that a major bump carries more API-compatibility risk than a same-major
minor/patch bump — proceed, but flag this explicitly in your final report
so the plan owner knows to scrutinize the visual-check step more closely.

**Verify**: you have a specific target version string for each of `mermaid` and `katex` (KaTeX's auto-render contrib file version tracks the main `katex` version, per the current pin — confirm this is still true for the new version too).

### Step 2: Fetch the new SRI hashes

For each of the four pinned resources (`mermaid.min.js`, `katex.min.css`,
`katex.min.js`, `contrib/auto-render.min.js`), compute the sha384 hash of
the exact new-version file content from jsDelivr:

```bash
curl -s "https://cdn.jsdelivr.net/npm/mermaid@<NEW_VERSION>/dist/mermaid.min.js" \
  | openssl dgst -sha384 -binary | openssl base64 -A
```

Prefix the result with `sha384-` to match the existing format. Repeat for
the other three files at their respective new-version URLs. jsDelivr also
publishes its own computed integrity hashes in its package metadata/CDN
comments if you want a second source to cross-check against — prefer
computing it yourself from the actual fetched bytes, since that's what
`integrity` is protecting against in the first place (trusting a
third-party-reported hash defeats some of the point).

**Verify**: each computed hash is a `sha384-` prefixed base64 string, structurally matching the format of the existing four values in `CDN`.

### Step 3: Update the `CDN` enum

Replace all six version-bearing strings (4 URLs contain the version number,
4 integrity constants) with the new version and newly computed hashes. Keep
every other structural detail unchanged (variable names, the explanatory
comment above the enum, the enum's shape) — this is a values-only change.

**Verify**: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` → `** BUILD SUCCEEDED **`

### Step 4: Visually verify Mermaid diagrams and KaTeX math still render correctly

No automated visual-regression test exists for WebView-rendered content in
this codebase. Manually verify, using a markdown fixture containing:

- A Mermaid flowchart (`graph TD; A-->B; B-->C;`) and at least one other
  Mermaid diagram type already used elsewhere in the app's test fixtures if
  any exist (check for existing `.md` sample files in the repo, e.g. under
  any `docs/` or example-content directory).
- Inline math (`$x^2 + y^2 = z^2$`) and display math
  (`$$\int_0^\infty e^{-x} dx = 1$$`).

Open this fixture in the app's preview, and also export it to HTML and
confirm the exported file (opened in a real browser) renders identically.
If either the version bump silently changed visual output (font rendering,
diagram layout, spacing) in a way that looks broken (not just "slightly
different styling," which is expected/acceptable across a library version
bump), that's a STOP condition, not something to work around.

## Test plan

No new automated tests — this is a data/config change with no new logic to
unit test. The existing `zMDTests/` suite (math-placeholder-related tests
like `testMathExtractionDoesNotReuseUserAuthoredPlaceholderText`) should
still pass unchanged since they test the surrounding extraction/placeholder
logic, not the actual rendered library output. Verification is Step 4's
manual check plus a full existing-suite run.

## Done criteria

- [ ] `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- [ ] `xcodebuild ... test` → all pass (existing suite unaffected)
- [ ] All 4 URLs and 4 integrity hashes in `CDN` reflect the same new target version, computed from actually-fetched file content (not copied from an untrusted third-party claim)
- [ ] Manual visual verification (Step 4) confirms Mermaid diagrams and both inline/display KaTeX math render correctly in both live preview and exported HTML
- [ ] Final report notes the specific old→new version numbers for both libraries, and flags whether either was a major version bump
- [ ] No files outside `zMD/SettingsManager.swift` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- You don't have network access to fetch current versions/compute hashes —
  stop after Step 1, report the target version numbers you were able to
  determine (or that you couldn't determine any), and hand off the
  remaining steps.
- The new Mermaid or KaTeX major version changed an API this app calls
  (confirm by checking `WebRenderer.swift`'s `mermaid.initialize(...)` call
  and KaTeX's `renderMath`/`auto-render` config usage against the new
  version's changelog/migration guide) — if the app's JS calls would need
  to change to remain compatible, that's beyond "bump two version numbers"
  and needs its own plan; report the specific incompatibility rather than
  attempting to also patch `WebRenderer.swift`'s JS-bridge code here.
- Step 4's visual check shows genuinely broken (not just stylistically
  different) rendering — do not ship a version bump that visibly breaks
  math or diagrams; report what broke instead.

## Maintenance notes

- Whoever does this bump next (this is inherently a recurring task, not a
  one-time fix) should follow this same plan's steps — consider this file
  a reusable runbook, not a one-shot artifact, even after this specific
  execution completes.
- If the plan owner wants actual automation (a scheduled check that opens a
  PR when a new version is available), that's a natural Plan-013-style
  follow-up once Plan 006's CI infrastructure exists to run it from —
  reasonable tools for that: Dependabot doesn't natively track raw CDN URLs
  embedded in Swift source (it tracks package manifests), so a custom
  scheduled GitHub Action checking jsDelivr's API and diffing against the
  committed `CDN` enum would be the realistic approach; not attempted here.
