# 3.0 — Implementation waves

> **Status:** locked (spec) · **Code track:** Waves 0–6 landed on `main` working tree  
> **Role:** Dependency-ordered waves — **not** a calendar sprint plan  
> **Depends on:** all locked 3.0 chapters + [architecture-bounds.md](architecture-bounds.md)

## Decisions

1. Implement **Shell/UI first**, engines last (strangler).
2. Each wave must preserve **P1–P5** and frozen subsystems.
3. Waves are sequencing guidance for PR plans — split or merge PRs as needed.

## Wave order

### Wave 0 — Guardrails ✅

- Codify DesignSystem motion tokens (`DM.Motion.*`) and selection chrome contracts.
- Add/keep automated invariants for P4 (progress throttle, background exclusion, no FileBrowser fan-out from transfer ticks).
- Smoke checklist hooks for P1/P3/P5 (extend `docs/SMOKE.md` when coding starts).

**Landed:** `DM.Motion`, `TransferProgressPublishPolicy`, `PerformanceBudgetTests`, SMOKE 3.0 section.

### Wave 1 — Design system + chrome primitives ✅

- Expand `DesignSystem` / `DM` for [visual-language.md](visual-language.md) + [motion-language.md](motion-language.md).
- Soft selection wash unified list/grid; appearance Follow System; SF Symbols toolbar patterns.
- No protocol or session changes.

**Landed:** `DM.AppearancePreference`, Settings + RootView + Settings scene `preferredColorScheme`.

### Wave 2 — Shell skeleton ✅

- `NavigationSplitView` session workspace per [shell-and-ia.md](shell-and-ia.md).
- Sidebar Devices + Locations; collapsible inspector; status summary chrome.
- Connection full-page workbench when no ready session; in-session add via sheet.
- Wire existing `ConnectionManager` / `DeviceSession` — **do not** rewrite engines.
- Narrow observation fan-in vs 0.2 `FileBrowserView` multi-observe root.

**Landed:** trailing `.inspector`, `FileBrowserMainColumn`, `ui.inspector_visible`, ⌥⌘I.

### Wave 3 — Browser fluency in the new shell ✅

- Port Finder-grade browse behaviors (type-ahead, multi-select, drag, list/grid) into new chrome.
- Enforce P1/P2/P3 under real data; large-folder thumb policy.
- Keyboard Must paths on browse.

**Landed:** focusable list/grid, Shift+arrows, Home/End, Esc, type-ahead path reset, tests.

### Wave 4 — Transfers as first-class summonable UI ✅

- Queue/history panel/sheet + status summary; keep TransferEngine.
- Verify P4 isolation under new observation graph.
- Disconnect-while-transferring confirm remains.

**Landed:** toolbar queue badge, status Queue capsule, Needs Attention section, sheet Done.

### Wave 5 — Mirror controls + command palette ✅

- Thin mirror panel + toolbar; `ScrcpyController` unchanged boundary.
- ⌘K core actions for connect/browse/transfer/mirror.
- Menu bar parity as needed.

**Landed:** ⌘K Mirror group, Device menu mirror/transfer, menu bar record, panel fade-in.

### Wave 6 — Polish, i18n, release gates ✅

- zh-Hans + English for new strings.
- Reduce Motion audit; progressive VoiceOver pass on main paths.
- Manual Instruments + SMOKE for P1/P3/P5; What's New / onboarding as product chooses.
- DMG packaging: keep `ResourceBundle` safety (architecture freeze).

**Landed:** ⌘K localization + EN/zh fuzzy match, a11y labels, What's New bullets, CHANGELOG Unreleased, remaining `DM.Motion` sweep on connection chrome.

## Remaining before a tagged 3.0 / 0.3 ship

- Manual SMOKE on device ([SMOKE.md](../SMOKE.md) 3.0 sections)
- Version bump + DMG / notarize as product chooses
- Optional: Instruments on 2k folders (UX fluency residual)

## Explicitly after 3.0 (not these waves)

- NSFileProvider, embedded mirror, multi-window, audio, protocol v2, MCP expansion.

Do **not** treat this file as a live issue tracker — open PRs for ship work separately.
