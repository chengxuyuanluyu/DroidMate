# DroidMate 3.0 — Specification package

> **Status:** **package complete (decision-locked)** · implementation Waves **0–6 landed** (see [implementation-waves.md](implementation-waves.md))  
> **Map:** [wayfinder/MAP.md](../../wayfinder/MAP.md)  
> **Shape decision:** [wayfinder/tickets/01-spec-package-shape.md](../../wayfinder/tickets/01-spec-package-shape.md)  
> **Prototype:** [wayfinder/prototypes/shell-3.0](../../wayfinder/prototypes/shell-3.0/) (direction: yes)

Implementable product/experience/architecture bounds for the 3.0 uplift.
**Not** the shipped binary. Wire protocol and dual-channel topology remain
documented in [ARCHITECTURE.md](../ARCHITECTURE.md), [PROTOCOL.md](../PROTOCOL.md),
and [adr/](../adr/).

## Chapter index

| Chapter | File | Status |
|---------|------|--------|
| Vision | [vision.md](vision.md) | **locked** |
| Visual language | [visual-language.md](visual-language.md) | **locked** |
| Motion language | [motion-language.md](motion-language.md) | **locked** |
| Shell & IA | [shell-and-ia.md](shell-and-ia.md) | **locked** |
| Interaction contracts | [interaction-contracts.md](interaction-contracts.md) | **locked** |
| Performance budgets | [performance-budgets.md](performance-budgets.md) | **locked** |
| Architecture bounds | [architecture-bounds.md](architecture-bounds.md) | **locked** |
| Implementation waves | [implementation-waves.md](implementation-waves.md) | **locked** |
| Migration (appendix) | [migration.md](migration.md) | optional (not blocking) |
| Open questions (appendix) | [open-questions.md](open-questions.md) | intentional residuals only |

Status values: `draft` → `in-progress` → **`locked`**.

## Package complete (map Destination) when

1. Every **mandatory** chapter above is **`locked`**
2. Each locked chapter has a **Decisions** block + wayfinder ticket links
3. No major-axis open questions remain (or they live in appendix / map out-of-scope)
4. An implementer can draft a PR-plan outline from this package alone

Soft: shell visual prototype (wayfinder ticket 10) linked from Visual/Shell, or
explicit “principles only” note.

## Out of this package

Full sprint task lists, pixel-contract mock dumps, CI matrix, launch copy, code.
