# 3.0 — Architecture bounds

> **Status:** locked  
> **Source tickets:** [wayfinder/tickets/08-architecture-evolution-bounds.md](../../wayfinder/tickets/08-architecture-evolution-bounds.md)  
> **Baseline:** [wayfinder/research/04-codebase-baseline.md](../../wayfinder/research/04-codebase-baseline.md)  
> **Shell:** [shell-and-ia.md](shell-and-ia.md) · **Budgets:** [performance-budgets.md](performance-budgets.md)  
> **Protocol truth:** [ARCHITECTURE.md](../ARCHITECTURE.md), [PROTOCOL.md](../PROTOCOL.md), [adr/](../adr/)

## Decisions

1. **Strangler strategy** — Shell UI + design system is the main battlefield; engines stay.
2. **Frozen list** below is hard without a budget-driven reopen.
3. **Allow list** covers UI decomposition and observation hygiene for P1–P5.
4. **No protocol break** and **no ADR-0001–0004 reopen** for the 3.0 experience uplift by default.
5. **Optional** new SPM UI target later — not a map/spec requirement.
6. **Server jar** default unchanged.

## Target sketch (same topology, clearer UI boundary)

```
DroidMateApp
├── Shell UI (SwiftUI)          ← primary 3.0 change surface
│     DesignSystem / DM
│     Connection workbench | Session workspace (split + inspector)
├── ConnectionManager
│     └── DeviceSession[]
│           ├── TransportClient  ── Data Channel ──► DroidMate Server jar
│           ├── FileClient → TransferEngine
│           ├── ClipboardBridge
│           └── NotificationBridge
├── ScrcpyController  ── process ──► scrcpy (+ device scrcpy server)
└── DroidMateWire (shared with DroidMateMCP binary)
```

Runtime ownership of sessions, transfers, and wires matches 0.2.6; 3.0 must not invent a second session graph without an explicit new decision.

## Frozen subsystems

| Subsystem | Freeze means |
|-----------|----------------|
| **DroidMateWire protocol** | No wire break; codec/DTO remain shared App+MCP contract |
| **Data Channel semantics** | HELLO/capabilities, files, clipboard, notifications stay the product pipe |
| **TransferEngine core** | Keep scheduling/progress/history model; fix edges for budgets, don’t rewrite |
| **TransportClient** | Soft reconnect / intentional disconnect / ready gate remain |
| **ScrcpyController** | External process mirroring (ADR-0001); not an in-app renderer |
| **MCP posture** | adb tools only; no app Data Channel session (ADR-0004) |
| **Packaging resources** | Safe resource loading (`ResourceBundle` pattern); DMG layout assumptions |

**Reopen rule:** only after performance breach order steps 1–3 fail and a new wayfinder/architecture decision records why.

## Allowed work (3.0)

| Area | Allowed |
|------|---------|
| Shell UI | Implement [shell-and-ia.md](shell-and-ia.md) with system split/toolbar chrome |
| Design system | Expand `DesignSystem` / `DM` to match [visual-language.md](visual-language.md) |
| View graph | Split `FileBrowserView` and related chrome; reduce multi-`@ObservedObject` fan-in |
| Observation | Narrow subscriptions; preserve P4 isolation (TransferEngine ⟂ file list rebuilds) |
| Connection UI | Restyle situational workbench; keep connect/recover flows calling existing manager APIs |
| FileClient surface | Small API/UX-facing tweaks; no protocol message redesign |
| Tests | Extend invariants for P4/P5; keep Wire/transfer unit coverage green |
| SPM shape | **May** extract UI/design library during implementation — optional |

## Explicitly not required / not default

- Greenfield shell package as a big-bang cutover  
- TransferEngine or TransportClient rewrite  
- Global store / TCA adoption as architecture mandate  
- Mandatory `@Observable` migration  
- Protocol v2  
- Embedded mirror (reopens ADR-0001)  
- Server-side feature rewrite for cosmetics  
- MCP feature expansion  

## ADR stance

| ADR | 3.0 action |
|-----|------------|
| 0001 scrcpy mirroring | **Stand** — external mirror |
| 0002 protocol scope | **Stand** — Data Channel scope |
| 0003 Mac-only product | **Stand** |
| 0004 MCP uses adb | **Stand** |

New ADR only if a future decision changes one of the above or freezes a surprising new boundary.

## Relationship to existing docs

- This chapter bounds **what implementation may touch**.  
- Dual-channel topology and failure modes remain in [ARCHITECTURE.md](../ARCHITECTURE.md).  
- Frame layouts remain in [PROTOCOL.md](../PROTOCOL.md).  
- Do not duplicate protocol into the 3.0 package.

## Handoff

- Implementation wave order should start from DesignSystem + Shell, engines last → [implementation-waves.md](implementation-waves.md) (assemble near map end).  
- Motion must respect P1 and system chrome → [motion-language.md](motion-language.md) (ticket 09).
