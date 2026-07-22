# Plan 002: Rotate notary credentials and stop leaking their identifiers in build-dmg.sh

> **Executor instructions**: Follow this plan step by step. Confirm each
> step's expected result before moving on. If anything in "STOP conditions"
> occurs, stop and report — do not improvise. When done, update the status
> row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 2a1682e..HEAD -- scripts/build-dmg.sh scripts/.notary-config.example`
> If either file changed since this plan was written, re-read the live file
> before proceeding.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `2a1682e`, 2026-07-05

## Why this matters

`scripts/build-dmg.sh` used to hardcode the App Store Connect API **Key ID**
and **issuer UUID** used for notarization. Those were moved to a gitignored
`scripts/.notary-config.local` at some point, and the current tree is clean
— but git history still contains multiple commits where those two
identifiers were committed in plaintext. History is not something a
`.gitignore` retroactively fixes: anyone who clones the repo (or already
has) can read those values out of old revisions of `scripts/build-dmg.sh`.

Separately, the *current* script still has two smaller leaks of the same
identifiers:

1. It writes the notarization log to a fixed, predictable path
   (`/tmp/zmd-notary.log`), readable by any local user and — the same
   `mktemp`-vs-fixed-path class of bug this app's own `UpdateManager.swift`
   already had to fix once (see its S4 remediation comment) — potentially
   pre-creatable/symlinkable by another local process.
2. On a notarization failure, it echoes a "recovery command" that includes
   the Key ID and issuer UUID directly into stdout, which lands in whoever's
   terminal/CI log is running the script.

**This plan does two things**: (a) walks you through what to change in the
committed script (mechanical, testable), and (b) tells you exactly what
human/manual step the plan's owner (not you) must do afterward, since
credential rotation happens in the Apple Developer portal, not in this repo.
**Do not attempt to read, print, or otherwise reproduce the actual Key ID or
issuer UUID value anywhere — not in commit messages, not in comments, not in
your final report.** Reference them only as "the notary API Key ID" / "the
notary issuer UUID".

## Current state

- `scripts/build-dmg.sh` — release build/sign/notarize/staple script,
  sourced by the human maintainer locally (not run in CI — there is no CI
  yet; see Plan 006).
- `scripts/.notary-config.local` — gitignored, holds the actual
  `NOTARY_KEY` (path to a `.p8` file), `NOTARY_KEY_ID`, `NOTARY_ISSUER`.
  Confirmed gitignored and untracked; not a target of this plan.
- `scripts/.notary-config.example` — committed placeholder template; also
  confirmed clean (no real values).

The two leak sites in the current script:

```bash
# scripts/build-dmg.sh:260-272 (submission block)
        echo "==> Submitting DMG to Apple notary service (this can take a few minutes)..."
        xcrun notarytool submit "$DMG_PATH" \
            --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
            --wait 2>&1 | tee /tmp/zmd-notary.log
        STATUS=$(grep -E "^\s*status:" /tmp/zmd-notary.log | tail -1 | awk '{print $2}')
        if [ "$STATUS" != "Accepted" ]; then
            echo "==> ERROR: notarization status was '$STATUS', expected 'Accepted'."
            echo "    Fetch full log:"
            SUBMIT_ID=$(grep -E "^\s*id:" /tmp/zmd-notary.log | head -1 | awk '{print $2}')
            echo "    xcrun notarytool log $SUBMIT_ID --key $NOTARY_KEY --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER"
            exit 1
        fi
```

There is a second, near-identical submission block later in the script for
the re-staple pass (the script submits twice — once for the app, once for
the repackaged DMG; grep for `xrun notarytool submit` to find both). Apply
the same fix to both.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check | `bash -n scripts/build-dmg.sh` | exit 0, no output |
| Full dry build (only if you have local signing certs — likely NOT available to you as an executor without human-provided credentials; see STOP conditions) | `bash scripts/build-dmg.sh` | `==> Done! DMG at: ...` |

## Scope

**In scope**:
- `scripts/build-dmg.sh` — both `xcrun notarytool submit ... tee /tmp/...`
  blocks and their following error-recovery `echo` lines.

**Out of scope**:
- `scripts/.notary-config.local` / `scripts/.notary-config.example` — no
  code change needed; already correctly gitignored/placeholder-only.
- Actually rotating the credential in App Store Connect — that's a manual,
  human-only step (Step 3 below explains it but you cannot perform it).
- Rewriting git history to scrub the old commits — a separate, higher-risk
  decision the plan owner should make explicitly (a force-push rewrite
  affects anyone with an existing clone); not in scope for this plan.

## Git workflow

- Branch: `advisor/002-notary-script-hygiene`
- One commit, conventional style matching this repo (see `git log --oneline
  -10` for tone — imperative present-tense subject, e.g. `fix: ...` or
  `chore: ...`).
- Do NOT push unless instructed.

## Steps

### Step 1: Route the notary log through `mktemp` instead of a fixed path

Replace `/tmp/zmd-notary.log` with a per-invocation temp file, and clean it
up when the script exits (success or failure) so it doesn't accumulate.
Add near the top of the script, after the existing `set -euo pipefail` and
path setup:

```bash
NOTARY_LOG="$(mktemp -t zmd-notary)"
trap 'rm -f "$NOTARY_LOG"' EXIT
```

Then replace every occurrence of the literal `/tmp/zmd-notary.log` in both
submission blocks with `"$NOTARY_LOG"` (quoted, since `mktemp` output can
theoretically contain characters that need quoting even though it usually
won't).

**Verify**: `grep -n "/tmp/zmd-notary.log" scripts/build-dmg.sh` → no matches. `grep -n 'NOTARY_LOG' scripts/build-dmg.sh` → shows the `mktemp` line, the `trap`, and both `tee`/`grep` usages now referencing `$NOTARY_LOG`.

### Step 2: Stop echoing the Key ID / issuer UUID in the failure-recovery hint

Replace the recovery-command echo so it doesn't interpolate the credential
variables. Point the user at the config file instead — they already have
it, since the script just used it to authenticate:

```bash
        if [ "$STATUS" != "Accepted" ]; then
            echo "==> ERROR: notarization status was '$STATUS', expected 'Accepted'."
            echo "    Fetch full log with the credentials in your notary config:"
            SUBMIT_ID=$(grep -E "^\s*id:" "$NOTARY_LOG" | head -1 | awk '{print $2}')
            echo "    xcrun notarytool log $SUBMIT_ID --key \"\$NOTARY_KEY\" --key-id \"\$NOTARY_KEY_ID\" --issuer \"\$NOTARY_ISSUER\""
            exit 1
        fi
```

The key change: the echoed line now shows the *variable names* (`$NOTARY_KEY`
etc., literally, not interpolated — note the escaped `\$`) as a copy-pasteable
template the user fills from their own shell environment, rather than the
actual values. Apply the identical change to the second submission block's
error path.

**Verify**: `grep -n 'NOTARY_KEY_ID\b' scripts/build-dmg.sh` — the only remaining occurrences should be the `--key-id "$NOTARY_KEY_ID"` invocations (unavoidable — the script needs the real value to authenticate) and the two now-literal `\$NOTARY_KEY_ID` template strings in the echoed hints. None should be an *interpolated* value in an `echo`.

### Step 3: Syntax-check and report the manual rotation step

```bash
bash -n scripts/build-dmg.sh
```
→ exit 0, no output (this only checks syntax; it doesn't run notarization,
which requires real credentials you as an executor likely don't have).

You cannot perform Step 3's actual credential rotation — it requires
interactive access to App Store Connect (Users and Access → Integrations →
API Keys) that only the human plan owner has. In your final report to the
plan owner, include this exact instruction verbatim so they don't have to
re-derive it:

> The notary API Key ID and issuer UUID are recoverable from this repo's git
> history (multiple commits touching `scripts/build-dmg.sh` before the
> credentials were moved to a gitignored local config). Revoke that API key
> in App Store Connect → Users and Access → Integrations → API Keys, generate
> a replacement, and update the values in your local (gitignored)
> `scripts/.notary-config.local`. The `.p8` private key file itself was never
> committed, so only the Key ID and issuer UUID need rotating — but rotate
> them regardless of whether you believe anyone has actually read the old
> commits; the identifiers are burned the moment they're in history.

## Test plan

No new automated tests apply — this is a shell script with no test target.
Verification is the `bash -n` syntax check (Step 3) plus manual review that
no credential value is interpolated into any `echo`/`print` statement
(Step 2's `grep` check).

## Done criteria

- [ ] `bash -n scripts/build-dmg.sh` exits 0
- [ ] `grep -n "/tmp/zmd-notary.log" scripts/build-dmg.sh` returns no matches
- [ ] Both `xcrun notarytool submit` blocks use `$NOTARY_LOG` instead of the fixed path
- [ ] Neither error-recovery `echo` interpolates the actual `$NOTARY_KEY_ID`/`$NOTARY_ISSUER` values (only the literal template string)
- [ ] The final report to the plan owner includes the manual-rotation instruction from Step 3, verbatim
- [ ] No files outside `scripts/build-dmg.sh` are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The script's structure around the `xcrun notarytool submit` calls doesn't
  match the excerpt (drifted since this plan was written) — re-read the live
  file and adapt the edit, don't guess.
- You find yourself about to print, log, or commit the actual credential
  value anywhere — stop immediately, this is a hard rule violation, not a
  judgment call.
- You're asked (or tempted) to perform the actual App Store Connect
  rotation — you cannot do this; report the instruction from Step 3 instead
  of attempting any workaround.

## Maintenance notes

- If CI is added later (Plan 006), it should use its own dedicated
  short-lived credential (e.g. a GitHub Actions secret), not this same
  rotated local key — keep local dev/release signing and any future CI
  signing on separate credentials so one compromise doesn't require
  coordinated rotation of both.
- Git-history scrubbing (BFG / `git filter-repo`) was deliberately left out
  of this plan's scope because it's a repo-history-rewriting operation with
  real blast radius (breaks every existing clone's history, requires a
  force-push). If the plan owner wants that done, it should be its own
  explicitly-scoped, explicitly-approved plan — not bundled into a
  script-hygiene fix.
