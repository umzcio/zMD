# Animation plans — zMD

Written by the `improve-animations` audit at commit `023ae28`. Each plan is
self-contained: exact file paths, current-code excerpts, target values, and a
feel check. Execute with any agent; review diffs against the audit bar (no
`easeIn`, UI motion ≤ 300ms, transform/opacity-class changes preferred,
Reduce Motion keeps fades but drops movement).

`plans/` predates these and belongs to general engineering work — animation
plans live here to keep the numbering independent.

## Plans

| # | Title | Severity | Status |
|---|-------|----------|--------|
| 001 | Sync split-pane scrolling instantly | HIGH | DONE |
| 002 | Remove command palette scroll animation | HIGH | DONE |
| 003 | Honor Reduce Motion in movement tokens and AppKit scrolls | HIGH | DONE |
| 004 | Scope root layout animations to the chrome | HIGH | DONE |
| 005 | Drive sidebar animations from their toggles | MEDIUM | DONE |
| 006 | Remove the view-mode switch animation | MEDIUM | DONE |
| 007 | Add press feedback with asymmetric timing | MEDIUM | DONE |
| 008 | Calm the dirty-dot entrance and pulse | MEDIUM | REJECTED — owner kept the v2.8.1 feel-checked spring (plans/021) |
| 009 | Consolidate hand-typed springs into a Motion token | MEDIUM | PARTIAL — toast + welcome-icon springs kept at v2.8.1 values (plans/022, 023); Motion.springy token retained but currently unused |
| 010 | Trim the welcome entrance to the UI budget | LOW | REJECTED — owner kept the v2.8.1 feel-checked stagger (plans/023) |
| 011 | Use an entrance curve for the focus-exit pill hover | LOW | DONE |
| 012 | Animate split view open/close | MEDIUM | DONE |
| 013 | Crossfade the welcome ⇄ editor window swap | MEDIUM | DONE |
| 014 | Animate the search bar's replace-row expansion | LOW | DONE |

## Recommended execution order

1. **001, 002** — highest leverage, tiny diffs, fully independent. Do these first.
2. **003** — introduces `Motion.fastMovement`/`entranceMovement`; unblocks 008 and 014.
3. **004** — restructures `ContentView.swift`'s chrome; run before 013 and 014 (they edit the same region).
4. **005, 006, 007** — independent MEDIUMs, any order.
5. **008, 009, 010, 011** — token-dependent or polish; 008 needs 003.
6. **012, 013, 014** — missed opportunities; 013 after 004, 014 after 003+004.

## Dependencies

- **008 → 003**: uses `Motion.fastMovement`.
- **014 → 003 + 004**: uses `Motion.fastMovement`; edits the search-bar region 004 restructures.
- **013 → 004**: sits on the root VStack 004 cleans up.
- **009 ↔ 008**: 009 explicitly does not touch `TabBar.swift:118` (008 owns it) — running one without the other leaves no conflict.
- **003 ↔ 001/002/004**: 003 deliberately skips their call sites; no overlap.

## Notes for executors

- Build check for every plan: `xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug build`.
- Each plan's feel check is not optional — motion can be mechanically correct
  and still feel wrong. Toggle Reduce Motion (System Settings → Accessibility
  → Display) for every plan that touches movement.
