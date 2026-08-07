# Ticket 09 — Motion language principles

`wayfinder:grilling` · **status: closed (resolved)** · `blocked-by:` none
· **claimed:** resolved this session

## Question

What is DroidMate 3.0’s **Motion Language** — shared rules so animation feels
intentional and platform-consistent rather than per-view random?

## Write target

Resolution lands in the matching chapter under `docs/3.0/` (see package README). Shape: ticket 01.

## Resolution

**Locked 2026-08-07** (user: all recommendations).

### Bands

| Token | Role | Guidance |
|-------|------|----------|
| **Micro** | hover/press affordance | ~0–120ms; often instantaneous |
| **Meso** | panels, inspector, transfer queue, sheets | ~200–350ms |
| **Macro** | connection workbench ↔ session, rare onboarding | ~350–500ms; rare |

### Spring vs not

- Meso/Macro: prefer **system springs** (SwiftUI snappy/smooth-class).
- Progress bars/determinate progress: **no spring** (linear or unanimated).
- Selection wash: **no spring** — same-frame / instant opacity only (**P1**).

### Same-frame / no-motion list

Selection wash, multi-select primary highlight, transfer progress chrome (no spring), avoid whole-FileBrowser spring on banners.

### Navigation

- Folder open: no full-list dim; chip feedback (**P2**); optional tiny cross-fade only if safe.
- Device switch: instant or minimal cross-fade.
- Connection → session: one Macro (or system nav); Reduce Motion → cross-fade/instant.
- Inspector/transfer/sheet: Meso; optional small matched-geometry; no full-screen morph theater.

### Reduce Motion (hard)

No springs/large moves; Meso/Macro → opacity or instant; Micro hover may off; selection still same-frame; no decorative loops.

### Scrcpy

Panel may Meso; no app-side animation promises for external scrcpy window.

### Non-goals

Parallax, looping decoration, content-layer glass morph shows, bouncy selection rows, brand physics demos.

### Implementation

Single DesignSystem entry (`DM.Motion.*` or equivalent); no scattered magic numbers.

### Package

[`docs/3.0/motion-language.md`](../../docs/3.0/motion-language.md) **locked**.  
Unblocks **ticket 10**. Term **Motion Language** → `CONTEXT.md`.
