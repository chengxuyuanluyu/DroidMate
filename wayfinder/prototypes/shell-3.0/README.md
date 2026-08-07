# Shell 3.0 prototype (THROW AWAY)

**Question:** Does the locked DroidMate 3.0 visual language + shell/IA + motion
language feel native when concrete?

**Not production.** Fixture data only — no adb, scrcpy, or real transfers.

## Run

```bash
cd wayfinder/prototypes/shell-3.0
swift run
```

Requires macOS 15+ / Swift 6.1 toolchain.

## What to judge

1. **Connection workbench** (cold start) → click a phone → session shell
2. **Session shell:** Devices + Locations sidebar, file list, inspector, status
3. **Selection** — should paint **same frame** (no spring)
4. **Open a folder** — “Opening…” chip, list does **not** full-dim
5. **Transfers** (toolbar or ⌘J) — Meso panel; with Reduce Motion → cross-fade
6. **Mirror controls** — thin panel only (no embedded video)

System Settings → Accessibility → Display → **Reduce motion** to test dual path.

## Spec pointers

- `docs/3.0/shell-and-ia.md`
- `docs/3.0/visual-language.md`
- `docs/3.0/motion-language.md`
- Ticket: `wayfinder/tickets/10-shell-visual-prototype.md`
