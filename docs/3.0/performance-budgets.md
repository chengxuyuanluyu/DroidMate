# 3.0 — Performance budgets

> **Status:** locked  
> **Source tickets:** [wayfinder/tickets/07-performance-budgets.md](../../wayfinder/tickets/07-performance-budgets.md)  
> **Baseline:** [wayfinder/research/04-codebase-baseline.md](../../wayfinder/research/04-codebase-baseline.md)  
> **Related:** 0.2 UX fluency (`docs/superpowers/specs/2026-07-31-ux-fluency-initiative.md`)

## Decisions

1. Exactly **five ship-blocking** budgets (below). Design/impl that breaks them is not “done.”
2. **Separate perceived UI feedback** from **device I/O completion** (especially directory list).
3. **Transfer progress observation isolation** is a **product invariant**, not optional polish.
4. **Verification is hybrid** — automate structural invariants; manual Instruments/SMOKE for frame-feel.
5. **Breach response order** prefers isolation/throttle before protocol changes (compat stance).

## Ship-blocking budgets

| ID | Budget | Pass when | Fail when |
|----|--------|-----------|-----------|
| **P1** | Selection same-frame | Click/keyboard selection shows soft wash with **no** intentional spring/animation delay on the selection chrome | Selection lags a frame+ due to animation or full-tree rebuild |
| **P2** | Navigation feedback ≤100ms | Folder open shows navigating affordance (chip / `isNavigating`) within ~100ms of action | UI freezes or gives no feedback while waiting on list |
| **P3** | Large directory scroll (~2k list) | Normal trackpad fling over ~2000 list rows stays smooth (no sustained hitching) | Scroll jank from full-list recompute, heavy per-row work, or transfer-driven invalidation |
| **P4** | Transfer UI publish discipline | Progress updates **≤15 Hz** and only on **≥0.5%** progress change (or equivalent); FileBrowser **not** rebuilt from transfer ticks; **background/thumb** work excluded from user progress/queue/badge/completion | Chunk-rate UI thrash; thumbs counted as user transfer; list repaints on every progress tick |
| **P5** | Bounded connect/adb | adb-class ops have **hard timeouts**; connection flow is **cancellable**; UI never waits forever | Spinner with no timeout/cancel; main thread blocked on adb |

### Notes on P2 vs list completion

Remote `DIR_LIST` latency is **USB/device-bound**. P2 requires **honest, fast feedback**, not a 100ms data SLA. Empty-state / prior entries / chip patterns from 0.2 remain valid strategies.

### Notes on P3 vs grid thumbs

- List is the **hard** large-folder scroll surface.
- Grid may **skip remote thumbnail fetch** at high entry counts (0.2 threshold ~1500 is an acceptable default policy).
- Full-resolution thumbs for every cell at 2k is **not** a 3.0 budget.

### Notes on P4 (inherits 0.2.6)

Structural requirements (must not regress):

- Do not forward `TransferEngine` progress into `FileClient.objectWillChange` in a way that rebuilds the file list.
- Status/queue views may observe `TransferEngine` directly.
- `background: true` downloads (thumbnails) stay out of user-facing progress aggregation.

### Thumbnail concurrency (supports P3/P4)

| Rule | Default |
|------|---------|
| Concurrent thumb downloads | 1–2 |
| While foreground user transfer | Thumbs yield / wait |
| Path change | Cancel in-flight thumbs |
| Decode failures | Drop bad cache entries; allow re-fetch |

### P5 magnitude

Exact timeout seconds may match or refine 0.2 (e.g. ~5s-class shells). The **contract** is: **finite wait + cancel path**, not a frozen table of every adb invocation.

## Not ship-blocking

| Topic | Stance |
|-------|--------|
| scrcpy end-to-end latency | Should-level / external process; see ARCHITECTURE aspirational numbers — not a 3.0 package hard gate |
| Process memory ceiling | Engineering hygiene; no fixed MB cap in this chapter |
| Per-call adb millisecond SLOs | Avoid false precision; covered by P5 |

## Verification

| Layer | What |
|-------|------|
| **Automated** | Unit/invariant tests: progress throttle, background exclusion, non-fan-out wiring where assertable |
| **Manual release gate** | Instruments + SMOKE: P1 selection, P3 ~2k scroll, P5 cancel/timeout on connect failure paths |
| **Out of scope for CI** | Full synthetic frame-budget suite for all SwiftUI chrome |

Extend [docs/SMOKE.md](../SMOKE.md) (or a short 3.0 checklist linked from there) when implementation starts — not required to lock this chapter.

## Breach response order

When a budget fails in design or implementation review:

1. **Observation isolation / publish throttle** (fix thrash first)  
2. **Reduce content work** (thumbs, visible-range, sort off main)  
3. **Split view observation boundaries** (stop mega-observed roots)  
4. **Last resort:** protocol or session-model changes (needs explicit architecture decision)

## Handoff

- Architecture freeze/allow must preserve P4 isolation → [architecture-bounds.md](architecture-bounds.md) (ticket 08).  
- Motion must not violate P1 (no spring on selection) → [motion-language.md](motion-language.md) (ticket 09).
