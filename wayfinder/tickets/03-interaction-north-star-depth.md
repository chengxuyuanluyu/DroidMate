# Ticket 03 — Interaction north-star depth

`wayfinder:grilling` · **status: closed (resolved)** · `blocked-by:` none
· **claimed:** resolved this session

## Question

How **deep** does 3.0 go toward reference products for **interaction**, given
north star “feel native” and product = files + mirroring?

References to place on a spectrum (not all need parity):

| Surface | Possible bar |
|---------|----------------|
| File browser | Finder-like (type-ahead, multi-select, keyboard, drop) vs “good enough app browser” |
| Connection | Current situational home (0.2.3+) polish vs redesign |
| Transfers | Queue/history as first-class vs status-bar-only |
| Mirroring controls | Thin panel over scrcpy vs deeper integration |
| Command palette / shortcuts | Power-user complete vs core set |
| Multi-device | Sidebar switch only vs richer session management |

Lock:

1. A **short ranked list** of interaction pillars for 3.0 (must / should / later).
2. Explicit **non-goals** for interaction (e.g. full Finder replace, per-app
   windowing deferred).
3. Whether **full keyboard + VoiceOver** is a release gate or progressive.

This feeds shell/IA (ticket 06) and performance budgets (ticket 07) without
designing every gesture in this session.

## Write target

Resolution lands in the matching chapter under `docs/3.0/` (see package README). Shape: ticket 01.

## Resolution

**Locked 2026-08-07** (user: all recommendations).

### Surface bars

| Surface | 3.0 bar |
|---------|---------|
| File browser | **Finder-grade in-app** (multi-select, keyboard, type-ahead, drag/drop, list/grid, path nav). Not a system Finder replacement. |
| Connection | **Evolve** 0.2.3 situational home — polish clarity/errors/native shell; keep mental model. |
| Transfers | **First-class** queue + history surface; status bar is summary, not sole UI. |
| Mirroring | **Thin control panel**; scrcpy stays **external window**. |
| Command palette | **Power-user core** (⌘K + documented shortcuts); not extensible plugin tree. |
| Multi-device | **Sidebar session switch**, one primary content focus; multi-connect OK. |

### Must / Should / Later

**Must:** Finder-grade in-app browse; situational connection polish; first-class transfers; thin mirror controls; core ⌘K/shortcuts; sidebar multi-device; same-frame selection/nav feedback (fluency bar).

**Should:** Stronger inspector/preview; batch transfer failure handling; smoother connection diagnostics; shortcut discoverability.

**Later:** NSFileProvider; embedded mirror; multi-window / side-by-side two devices; full VoiceOver certification pass; audio.

### Keyboard & VoiceOver

- **Keyboard = Must gate** on primary paths (browse / multi-select / transfer / connect).
- **VoiceOver = progressive Should** — main paths must not be hostile; not a full a11y certification gate for 3.0.

### Interaction non-goals (3.0)

- Replacing Finder / shipping NSFileProvider as default
- Rewriting scrcpy into an embedded renderer
- Per-app windowing / Sidecar-class multi-window
- Plugin command marketplace
- Inventing a novel trackpad gesture language (follow system)

### Package

Written to [`docs/3.0/interaction-contracts.md`](../../docs/3.0/interaction-contracts.md) **locked**.  
Unblocks **ticket 06** (Shell/IA) together with closed ticket 02.
