# Ticket 04 — 0.2.6 codebase baseline (architecture & performance)

`wayfinder:research` · **status: closed (resolved)** · `blocked-by:` none (frontier) · unblocks 07, 08
· **claimed:** research subagent (charting session)

## Question

What is the **factual baseline** of the current Mac client for a 3.0 redesign —
structure, hotspots, and constraints — so architecture and performance decisions
are evidence-based?

Research **in-repo primary sources** (and CodeGraph), not blog opinions:

1. **Module map** — App / Capture / Transport / Files / UI / Wire / MCP: real
   ownership and the thickest coupling edges (e.g. UI → FileClient → TransferEngine
   → Transport).
2. **MainActor / observation surface** — which `@MainActor` / `ObservableObject`
   types publish most frequently (transfers, directory listing, connection,
   thumbnails) and known thrash mitigations already shipped (0.2.x UX fluency).
3. **I/O and process boundaries** — Data Channel (`TransportClient`), adb
   (`AdbBridge` / `AdbRunner`), scrcpy process, thumbnail pipeline — failure and
   cost characteristics as documented in code + ARCHITECTURE.
4. **Test & packaging constraints** — SPM targets, what tests protect today,
   DMG/bundle assumptions that a shell rewrite must not break.
5. **Top 5 risk list** for a visual/shell overhaul (what would break first).

**Output:** `wayfinder/research/04-codebase-baseline.md` with citations to file
paths/symbols. Then a short resolution comment on this ticket pointing at that
note. Unblocks performance budgets and architecture evolution bounds.

## Resolution

- **status:** closed (resolved)
- **gist:** 0.2.6 Mac client is a MainActor-heavy DeviceSession graph (UI → FileClient → TransferEngine → TransportClient) with scrcpy out-of-process; transfer thrash is already capped (~15 Hz, isolated observation); packaging forbids naive `Bundle.module`; top shell risks are observation fan-out, shared Data Channel thumbs, and session chrome lifecycle.
- **note:** [`wayfinder/research/04-codebase-baseline.md`](../research/04-codebase-baseline.md)
