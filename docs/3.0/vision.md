# 3.0 — Vision

> **Status:** locked  
> **Source:** wayfinder charting locks + closed tickets 01–10  
> **Map:** [wayfinder/MAP.md](../../wayfinder/MAP.md)

## Decisions

1. **Product identity unchanged:** Mac-native **files + mirroring** companion — not a new category.
2. **Ambition:** Professional-grade **same-product reinvention** (feel first-class on macOS), not an M7+ platform leap as the definition of 3.0.
3. **North star:** **Feel native** (materials, type, motion, shortcuts, progressive a11y). **Performance is a hard budget** — native that janks fails 3.0.
4. **Compat:** UX/shell/IA may break boldly; **prefer continuous Data Channel + server jar** (small protocol evolution OK; big wire break needs its own decision).
5. **Map deliverable:** Implementable **spec package** in `docs/3.0/` — not the shipped binary inside the wayfinder map.
6. **Prototype:** Shell feel validated as direction ([wayfinder/prototypes/shell-3.0](../../wayfinder/prototypes/shell-3.0/)).

## North star (one line)

> DroidMate 3.0 should feel like a **macOS-first utility** you trust daily for phone files and casting — quiet craft, system chrome, Finder-grade in-app browse — without fighting the platform or the 0.2 reliability core.

## In scope for the 3.0 product cut (spec-level)

As locked across interaction, shell, visual, motion, performance, architecture chapters:

- Hybrid visual language (system chrome + soft product craft)
- Evolved connection workbench + session `NavigationSplitView` shell
- Finder-grade **in-app** file browser; first-class transfers; thin mirror controls + external scrcpy
- Motion language (Micro/Meso/Macro) with Reduce Motion dual path
- Five ship-blocking performance budgets (P1–P5)
- Strangler architecture: Shell/UI main battlefield; engines/protocol frozen by default

## Non-goals (3.0 definition)

| Out | Why |
|-----|-----|
| Android APK / phone UI | ADR-0003 |
| True Wi‑Fi direct + TLS (bypass wireless adb) | Phase-2 networking |
| MCP capability expansion | ADR-0004 stands |
| Audio forwarding | Deferred |
| Windows / Intel Mac first-class | Deferred |
| Finder `NSFileProvider` as Must | Later / fog |
| Embedded mirror renderer | Later; would reopen ADR-0001 |
| Multi-window product / dual-device content columns | Later |
| Implementing+shipping binary **inside** the wayfinder map | Separate implementation effort |

## Relationship to 0.2.6

3.0 is an **experience and shell architecture uplift** on a shipped, usable 0.2.6 base (files, mirroring, Wi‑Fi UX, zh-Hans, transfer hardening). Reliability invariants (especially transfer observation isolation) are **kept and elevated to budgets**, not discarded for aesthetics.

## Success for implementers

An engineer can open this package, draft a PR-plan outline (see [implementation-waves.md](implementation-waves.md)), and build without re-grilling product on major axes. Pixel perfection is not required from the prototype — **principles + waves** are.
