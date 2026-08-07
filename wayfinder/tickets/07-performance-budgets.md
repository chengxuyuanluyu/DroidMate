# Ticket 07 — Performance budgets

`wayfinder:grilling` · **status: closed (resolved)** · `blocked-by:` none
· **claimed:** resolved this session

## Question

What **measurable performance budgets** gate DroidMate 3.0 design and
implementation decisions?

Using the baseline research (ticket 04), lock budgets for at least:

1. **UI thread** — interaction-to-highlight / folder open perceived response
2. **Large directories** — scroll smoothness target at ~2k entries; list vs grid.
3. **Transfers** — progress publish rate; completion feedback; thumbnail isolation.
4. **Thumbnails** — decode/cache cost ceilings or concurrency caps.
5. **Connection / adb** — hard timeouts vs engineering hygiene.
6. **How budgets are verified**

## Write target

Resolution lands in the matching chapter under `docs/3.0/` (see package README). Shape: ticket 01.

## Resolution

**Locked 2026-08-07** (user: all recommendations).

### Ship-blocking budgets (exactly five)

1. **Selection same-frame** — pointer/keyboard selection paints wash without extra spring delay.
2. **Navigation feedback ≤100ms** — navigating chrome (`isNavigating` / chip) visible; **not** a bound on remote DIR_LIST completion.
3. **~2k-entry list scroll** — no sustained main-thread hitches under normal trackpad fling; grid may keep conservative remote-thumb policy (≥1500 skip remote thumbs OK).
4. **Transfer UI ≤15 Hz** + **≥0.5% delta** publish; **no** TransferEngine progress fan-out rebuilding FileBrowser; user vs background/thumb progress isolation.
5. **No hang forever** — adb/connect paths have **hard timeouts** (≈0.2 order, e.g. ~5s-class shells) and **cancellable** connection UI; exact seconds tunable, infinite wait = breach.

### Thumbnail policy (part of #3/#4)

- Concurrency 1–2; yield while foreground user transfers; cancel in-flight on path change; large-folder remote-thumb threshold retained.

### Not ship-blocking (Should / engineering)

- scrcpy e2e latency (external process; ARCHITECTURE aspirational only)
- Absolute process memory cap
- Per-adb-call frozen millisecond tables

### Verification

- **Automate** invariants: progress throttle, background excluded from user progress, observation non-fan-out where testable.
- **Manual** pre-release: Instruments + SMOKE for same-frame selection, 2k scroll, cancel-in-flight connect.
- No claim of full CI frame testing.

### Breach response order

1. Observation isolation / publish throttle  
2. Reduce content work (thumbs, visibility)  
3. Split view observation boundaries  
4. **Last:** protocol / session model changes  

### Package

[`docs/3.0/performance-budgets.md`](../../docs/3.0/performance-budgets.md) **locked**.  
Term **Performance Budget** → `CONTEXT.md`.
