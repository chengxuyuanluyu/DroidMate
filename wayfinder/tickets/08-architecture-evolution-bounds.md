# Ticket 08 — Architecture evolution bounds

`wayfinder:grilling` · **status: closed (resolved)** · `blocked-by:` none
· **claimed:** resolved this session

## Question

What may **change in the Mac client architecture** for 3.0, and what is a hard
**no-rewrite** boundary?

## Write target

Resolution lands in the matching chapter under `docs/3.0/` (see package README). Shape: ticket 01.

## Resolution

**Locked 2026-08-07** (user: all recommendations).

### Strategy

**Strangler:** primary 3.0 work is Shell UI + DesignSystem under locked shell/IA and
visual language. Keep session/transfer/transport/wire/scrcpy engines; peel
god-views and narrow observation. Deep rewrites only if P1–P5 cannot be met
after isolation/throttle (see performance breach order).

### Frozen (unless budget breach + explicit reopen)

1. `DroidMateWire` frame protocol codec (no break)  
2. Data Channel session semantics (control/files/clipboard/notifications)  
3. `TransferEngine` core state machine (boundary fixes OK; no greenfield rewrite)  
4. `TransportClient` connect/reconnect model  
5. `ScrcpyController` external-process mirroring (ADR-0001)  
6. MCP via adb only (ADR-0004)  
7. Packaging: `ResourceBundle` / no fragile packaged `Bundle.module` path  

### Allowed

- Full Shell UI evolution per `shell-and-ia.md`  
- Split FileBrowser observation fan-in; extract shell composition  
- Strengthen DesignSystem/`DM`  
- Connection workbench restyle  
- Inspector / summonable transfer chrome  
- Tighten observation for P4  
- Small FileClient API surface tweaks for UI — **not** wire protocol  
- Optional later SPM split (e.g. UI lib) — **not required** by this map  

### Observation

Stay `@MainActor` + `ObservableObject`-centric. **Ban** re-introducing
TransferEngine progress fan-out into FileBrowser roots. Narrow observation is
encouraged. Framework migrations (`@Observable`, TCA) are **not** 3.0 musts.

### Protocol / ADR / server

- Prefer **no** protocol break; do **not** reopen ADR-0001–0004 for the experience uplift.  
- Protocol truth remains ARCHITECTURE + PROTOCOL + adr/.  
- Default: **no** DroidMate Server jar behavior rewrite; compatible small evolution only via separate decision if ever needed.

### Package

[`docs/3.0/architecture-bounds.md`](../../docs/3.0/architecture-bounds.md) **locked**.
