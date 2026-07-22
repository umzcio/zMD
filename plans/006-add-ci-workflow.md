# Plan 006: Add a GitHub Actions CI workflow for build + test

> **Executor instructions**: Follow this plan step by step, verifying each
> step. If a "STOP conditions" trigger occurs, stop and report. Update
> `plans/README.md`'s status row when done.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- zMD.xcodeproj/project.pbxproj` and confirm `.github/workflows/` is still absent (`ls .github/workflows 2>/dev/null`). If either has changed materially, re-verify the signing settings below before proceeding.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: Plan 005 is not a hard dependency, but running this after Plan 005 lands means CI immediately exercises a bigger test suite. Fine to run in either order.
- **Category**: dx
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

There is no `.github/workflows/` directory — nothing runs the build or the
existing test suite (`zMDTests/InlineMarkdownTests.swift`, 15 tests as of
this writing) automatically. The test target is fully wired into the Xcode
project already (`TEST_HOST`/`BUNDLE_LOADER` configured, confirmed in
`project.pbxproj`), so `xcodebuild ... test` works today from any clean
checkout — the only missing piece is something that runs it on every push.
Without CI, a compile break or a test regression is invisible until the
maintainer happens to build locally, which for a solo-maintained project can
be days after the breaking commit landed.

## Current state

- No `.github/workflows/` directory exists.
- The project uses **manual, Developer-ID code signing** for all
  configurations:

```
# zMD.xcodeproj/project.pbxproj (both Debug and Release configs)
CODE_SIGN_IDENTITY = "Developer ID Application";
CODE_SIGN_STYLE = Manual;
MACOSX_DEPLOYMENT_TARGET = 13.0;
```

(plus `DEVELOPMENT_TEAM` and `ENABLE_HARDENED_RUNTIME = YES` — confirm the
exact current values with `grep -n "DEVELOPMENT_TEAM\|ENABLE_HARDENED_RUNTIME"
zMD.xcodeproj/project.pbxproj` before writing the workflow, since a CI
runner has no Developer ID certificate in its keychain and a bare
`xcodebuild build` will fail at the codesign step with a signing error, not
a real build failure — this is a known false-red trap for exactly this kind
of manual-signing project.)

- Two native targets exist: `zMD` (app) and `zMDTests` (unit tests) —
  confirmed via `grep -n "isa = PBXNativeTarget" zMD.xcodeproj/project.pbxproj`.
- Deployment target is macOS 13.0 — the CI runner should be macOS 13 or
  later (GitHub-hosted `macos-14` runners are readily available and
  backward-compatible for building a 13.0-target app; verify current GitHub
  Actions runner availability if this plan is executed much later than
  written, as hosted runner images change over time).
- Build/test commands already established and known-working (used
  throughout this repo's release process):

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Local build (sanity check before pushing workflow) | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Local test | `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug test -destination 'platform=macOS'` | all pass |
| YAML syntax check | `python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` (or any local YAML linter available) | no error |

You cannot fully verify this workflow runs correctly on GitHub Actions
without actually pushing it and observing a run — since the plan's
instructions say not to push without operator instruction, do the local
build/test verification (which proves the *commands* work) and note in your
final report that a live Actions run should be observed after this is
pushed, by the plan owner.

## Scope

**In scope**:
- `.github/workflows/ci.yml` (new file)

**Out of scope**:
- Any release/deploy workflow (signing, notarization, DMG creation) — those
  require the local-only notary credentials (see Plan 002) and should stay
  a manual, local `scripts/build-dmg.sh` process; do not attempt to move
  release signing into CI as part of this plan.
- SwiftLint/formatting checks — that's Plan-worthy on its own if the
  maintainer wants it (noted as a deferred low-priority item in this
  plan set's README), not bundled here.
- Any change to `project.pbxproj` — the CI-only signing override is passed
  as command-line arguments to `xcodebuild` in the workflow file, not baked
  into the project settings (which must stay correct for the real signed
  release build).

## Git workflow

- Branch: `advisor/006-add-ci-workflow`
- One commit adding the workflow file.

## Steps

### Step 1: Confirm the exact signing settings to override

```bash
grep -n "DEVELOPMENT_TEAM\|CODE_SIGN_IDENTITY\|CODE_SIGN_STYLE\|ENABLE_HARDENED_RUNTIME" zMD.xcodeproj/project.pbxproj
```

Confirm all four configurations (Debug/Release × zMD/zMDTests, or however
many actually exist) use manual signing with a Developer ID identity. This
confirms the override in Step 2 is necessary and sufficient.

### Step 2: Write `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

jobs:
  build-and-test:
    runs-on: macos-14
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode.app

      - name: Build (Debug, unsigned)
        run: |
          xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            DEVELOPMENT_TEAM="" \
            build

      - name: Test (Debug, unsigned)
        run: |
          xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            DEVELOPMENT_TEAM="" \
            test -destination 'platform=macOS'
```

Notes on choices, so you understand what to adjust if a step fails:

- `runs-on: macos-14` — targets a runner image that supports building for
  a macOS 13.0 deployment target with a recent Xcode. If GitHub's available
  hosted images have moved on by the time this runs, adjust to whatever
  current macOS runner label is available (check
  `https://github.com/actions/runner-images` — note this requires
  fetching a URL, which you may not have access to as an executor; if so,
  try `macos-14` first and fall back to `macos-latest` if the job fails to
  find that label).
- `xcode-select` step — pins to whatever Xcode `/Applications/Xcode.app`
  resolves to on the runner (GitHub-hosted macOS runners preinstall
  multiple Xcode versions under `/Applications/Xcode_X.Y.app` symlinked or
  selectable — if the default `/Applications/Xcode.app` doesn't exist or
  resolves to an unsuitable version, you may need `sudo xcode-select -s
  /Applications/Xcode_16.app` or similar; adjust based on what the actual
  CI run reports, which you cannot observe locally — flag this explicitly
  in your final report as something to verify on the first live run).
- The four `CODE_SIGN*`/`DEVELOPMENT_TEAM` overrides are the mechanism that
  avoids the false-red signing-error trap identified in "Current state" —
  do not drop any of the four; each disables a different part of the
  signing requirement chain (`CODE_SIGNING_ALLOWED=NO` is the primary one,
  but `CODE_SIGN_IDENTITY=""` and `DEVELOPMENT_TEAM=""` guard against
  `CODE_SIGN_STYLE = Manual` still trying to resolve a specific identity).
- No dependency-install step — this repo has zero external dependencies
  (no SwiftPM packages, confirmed during recon), so `actions/checkout` is
  sufficient before building.

**Verify**: `python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` → no error (confirms valid YAML). This does NOT confirm the workflow runs correctly on GitHub's infrastructure — see the note in "Commands you will need."

### Step 3: Locally reproduce the CI build/test commands

Before considering this done, run the exact same override flags locally to
catch any obvious problem (missing scheme, wrong destination string) before
it surfaces only on a real CI run:

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  build
```

```bash
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  test -destination 'platform=macOS'
```

**Verify**: both exit with `** BUILD SUCCEEDED **` / all tests passing, run locally (on your own dev machine, not the runner — this confirms the commands themselves are correct even though the runner environment can't be fully replicated locally).

## Test plan

No new Swift tests — this plan adds test *infrastructure*, not test cases.
Verification is Step 3's local reproduction of the exact CI commands.

## Done criteria

- [ ] `.github/workflows/ci.yml` exists and is valid YAML
- [ ] The unsigned build/test commands (Step 3) succeed locally with the exact override flags used in the workflow
- [ ] No changes to `zMD.xcodeproj/project.pbxproj` (signing config for the real build stays untouched)
- [ ] Final report explicitly flags: "first live GitHub Actions run should be observed by the plan owner to confirm the runner image/Xcode selection works — this could not be verified without pushing"
- [ ] `plans/README.md` status row updated

## STOP conditions

- Local reproduction (Step 3) fails for a reason unrelated to signing (a
  real build/test failure) — stop, this means either the repo has a
  pre-existing break or your local environment differs from what's assumed;
  report the exact failure rather than adjusting the workflow to hide it.
- You discover the project actually has SwiftPM dependencies or other setup
  this plan didn't account for (contradicts the "zero external dependencies"
  recon fact) — stop and report, since the workflow would need a
  dependency-resolution step this plan doesn't include.

## Maintenance notes

- If the maintainer later wants CI to also run on other branches or gate PR
  merges, that's a one-line `on:` trigger change — not worth over-engineering
  now.
- If the release process (Plan 002's context: local-only `build-dmg.sh`)
  ever moves into CI, it needs its own dedicated signing/notarization
  credentials as a GitHub Actions secret, kept separate from local dev
  credentials — do not casually extend this CI workflow to also run
  `build-dmg.sh` without that being its own deliberately-scoped plan.
- SwiftLint/formatting (deferred, not in this plan) would be a natural
  second CI job once added — leave room for that as a sibling job under the
  same workflow file rather than requiring a new file.
