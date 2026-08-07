# Ticket 06 — Shell & information architecture direction

`wayfinder:grilling` · **status: closed (resolved)** · `blocked-by:` none
· **claimed:** resolved this session

## Question

How should the **Shell** (window chrome + primary navigation) and **information
architecture** change for 3.0?

Given 0.2.x roughly: Connection workbench → session with sidebar (devices +
locations) + file browser + status/transfers + optional mirror controls +
command palette.

Poles:

- **Evolve** — keep mental model; restyle and fix density/flow (lower risk).
- **Restructure** — new primary nav (e.g. devices as top-level spaces, transfers
  as a peer area, connection as sheet/onboarding only).
- **Split surfaces** — e.g. dedicated transfer window / inspector strategies.

Lock:

1. Primary nav model and what is always visible vs progressive.
2. Where **connection**, **browse**, **transfers**, **mirror controls**,
   **settings** live.
3. Multi-device model at the Shell level (not protocol).
4. What **must not regress** from 0.2.x (e.g. situational Wi‑Fi home, multi-device
   sidebar).

Feeds architecture bounds and the shell visual prototype.

## Write target

Resolution lands in the matching chapter under `docs/3.0/` (see package README). Shape: ticket 01.

## Resolution

**Locked 2026-08-07** (user: all recommendations).

### Strategy

**Evolve** the 0.2 mental model (connection workbench → device session workspace).
Restyle onto system `NavigationSplitView` + Liquid Glass navigation chrome;
do **not** restructure into top-level “spaces” or a multi-window product.

### Session shell (active device)

- **Default:** sidebar + content; **inspector** collapsible for selection detail.
- **Sidebar:** Devices (top) + Locations for **active** device (bottom).
- **Content:** file browser (primary).
- **Status summary:** always-available chrome (progress/speed/session hints).
- **Transfers:** first-class **summonable** queue/history (⌘J / toolbar / ⌘K) —
  panel/sheet/inspector mode — not a permanent fourth column.
- **Mirror controls:** session toolbar + expandable thin panel; video in **external
  scrcpy** window; menu bar start/stop OK.
- **Settings:** system Settings window; **⌘K** for cross-cutting actions, not a
  full settings replacement.

### Connection placement

- **No ready session → full-page** situational Connection workbench.
- **In session →** add/repair phone via **sheet or temporary full-page**, not a
  permanent sidebar wizard.

### Multi-device (shell)

- Single main window; sidebar switches `activeDevice`; content bound to active
  session; failed rows expose reconnect.

### Must not regress (from 0.2.x)

1. Situational connection home  
2. Multi-device sidebar + session switch  
3. In-session file browse always reachable  
4. Confirm disconnect while transfers run  
5. Command palette / key shortcuts for core actions  
6. Mirror startable from session UI (not CLI-only)

### Shell non-goals (3.0)

- Default separate product windows for transfers/connection  
- Top-level device/transfer “spaces” IA rewrite  
- Embedded mirror canvas in content  
- Side-by-side dual-device content  

### Package

[`docs/3.0/shell-and-ia.md`](../../docs/3.0/shell-and-ia.md) **locked**.  
Unblocks **ticket 08** (with research 04) and **ticket 10** (with 02 + 09).
