# Ticket 10 — Shell visual / motion prototype

`wayfinder:prototype` · **status: closed (resolved)** · `blocked-by:` none
· **claimed:** resolved this session

## Question

Does the locked **visual language + shell/IA + motion language** actually feel
like a native 3.0 when made concrete?

Produce a **cheap, disposable** prototype (SwiftUI preview target, static
fixture data, or design canvas — pick lowest cost that still answers the
question). Scope:

- One **connected** browser shell (sidebar + list or grid + status).
- One **connection** surface state (empty or device list — per IA).
- Apply motion rules for: selection, folder navigate feedback, panel present.
- **Not** real adb/scrcpy/transfer.

Success: human can react with “yes, this is the 3.0 direction” or name specific
deltas; link the prototype path from this ticket. Failures feed revisions to
tickets 02/06/09 (reopen only if fundamental).

## Asset

- **Path:** [`wayfinder/prototypes/shell-3.0/`](../prototypes/shell-3.0/)
- **Run:** `cd wayfinder/prototypes/shell-3.0 && swift run`
- **Build:** verified `swift build` OK (macOS 15 / Swift 6.1)
- **Scope covered:** connection workbench → session `NavigationSplitView` (Devices + Locations + list + inspector); same-frame soft selection; Opening chip without list dim; Meso transfers sheet / mirror panel / ⌘K; Macro connect-disconnect; Reduce Motion via system setting.

## Resolution

**Locked 2026-08-07** (human verdict: **方向对** / this is the 3.0 direction).

- No fundamental reopen of tickets 02 / 06 / 09.
- Prototype remains a **directional anchor**, not a pixel contract (ticket 01).
- Soft gate for package complete: Visual + Shell chapters link this asset.

### Package updates

- Link from `docs/3.0/visual-language.md` and `docs/3.0/shell-and-ia.md`.
- Assembly of `vision.md` + `implementation-waves.md` from prior locks (map end).
