# 3.0 — Interaction contracts

> **Status:** locked  
> **Source tickets:** [wayfinder/tickets/03-interaction-north-star-depth.md](../../wayfinder/tickets/03-interaction-north-star-depth.md)  
> **Related:** UX fluency baseline in `docs/superpowers/specs/2026-07-31-ux-fluency-initiative.md` (0.2.x); visual selection language in [visual-language.md](visual-language.md)

## Decisions

1. **File browser = Finder-grade in-app**, not system Finder replacement.
2. **Connection = evolve** situational home (0.2.3+), not a greenfield IA.
3. **Transfers = first-class** queue/history surface.
4. **Mirroring controls = thin panel**; scrcpy remains an **external** window.
5. **⌘K + core shortcuts = power-user core**, not a plugin platform.
6. **Multi-device = sidebar session switch** with single primary content focus.
7. **Keyboard = Must release gate** on primary paths; **VoiceOver = progressive Should**.
8. Explicit **non-goals** listed below (Provider, embedded mirror, multi-window product, plugins, custom gesture language).

## Pillars by priority

### Must (3.0 interaction contract)

| Pillar | Pass when |
|--------|-----------|
| Finder-grade browse | Multi-select, type-ahead, keyboard navigation, drag in/out, list + grid, path/breadcrumb navigation feel trustworthy for daily phone storage work |
| Same-frame feedback | Selection highlight and critical chrome updates without “almost” lag (continues 0.2 fluency bar) |
| Situational connection | USB / wireless / mDNS / pairing wizard mental model retained; stages and failures are clear and actionable |
| First-class transfers | User can open queue + history, cancel/pause understandably, see failures; status bar summarizes |
| Thin mirror controls | Start/stop, quality, recording, nav keys reachable without hunting; does not require embedding video |
| Command core | ⌘K (or successor) reaches connect / browse / transfer / mirror high-frequency actions; shortcuts documented |
| Multi-device sidebar | Switch sessions; failed device shows reconnect path; one primary browser focus |

### Should

- Richer inspector / preview without identity thrash
- Batch transfer failure summary and recovery affordances
- Connection diagnostics that shorten time-to-fix
- Shortcut discoverability (cheatsheet / menu key equivalents completeness)

### Later (not 3.0 interaction Must)

- Finder `NSFileProvider` / system file integration
- Embedded mirror surface (replacing or wrapping scrcpy SDL)
- Multi-window or side-by-side dual-device browse
- Full VoiceOver certification-style audit as ship gate
- Audio forwarding

## Surface contracts (detail)

### File browser

- **In scope:** Finder-like *application* browser for device storage.
- **Out of scope:** Becoming the user’s default Mac file manager or providing system-wide file provider (unless a future map reopens fog).
- Preserve and raise: type-ahead, multi-select, drop targets, list/grid parity of selection language ([visual-language.md](visual-language.md)).

### Connection

- Keep **job-based** situational home (have USB → wireless path; have recent/mDNS → one-click; else add phone wizard).
- 3.0 invests in native shell presentation and error quality, not a new metaphor.

### Transfers

- Queue and history are **peer surfaces** to browse (openable, not only a slim status strip).
- Thumbnail/background work must not impersonate user-transfer progress (0.2.6 direction remains policy).

### Mirroring

- Controls are a **panel/toolbar concern**; pixels stay in scrcpy’s process/window (ADR-0001).
- Deeper integration is Later / fog — not this contract.

### Command palette & shortcuts

- Cover the happy paths of the Must pillars.
- No extension API / command marketplace in 3.0.

### Multi-device

- Pool of sessions + sidebar switch.
- Not required: simultaneous dual content columns.

## Keyboard & accessibility

| Concern | 3.0 gate |
|---------|----------|
| Full keyboard primary paths | **Must** — browse, multi-select, transfer actions, connect flows usable without pointer |
| VoiceOver | **Should (progressive)** — don’t ship hostile main paths; full certification not a hard gate |
| Reduce Motion | Honored per [motion-language.md](motion-language.md) when locked; until then follow 0.2 fluency + system setting |

## Non-goals (interaction)

- Replace Finder or ship NSFileProvider as a 3.0 Must
- Rewrite scrcpy into an in-app renderer
- Per-app windowing / Sidecar-class multi-window product
- Plugin-style command ecosystem
- Novel trackpad gesture language beyond system norms

## Handoff

- Shell placement of these surfaces → [shell-and-ia.md](shell-and-ia.md) (ticket 06).
- Numeric lag/scroll/transfer rates → [performance-budgets.md](performance-budgets.md) (ticket 07).
