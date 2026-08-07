# 3.0 — Motion language

> **Status:** locked  
> **Source tickets:** [wayfinder/tickets/09-motion-language.md](../../wayfinder/tickets/09-motion-language.md)  
> **Platform research:** [wayfinder/research/05-macos-design-motion.md](../../wayfinder/research/05-macos-design-motion.md)  
> **Hard gates:** [performance-budgets.md](performance-budgets.md) P1/P2/P4 · [visual-language.md](visual-language.md)

## Decisions

1. Three semantic bands: **Micro / Meso / Macro** (not per-view magic curves).
2. System springs for Meso/Macro; **no spring on selection or determinate progress**.
3. **Reduce Motion is a hard dual path** (opacity/instant), not best-effort.
4. Navigation stays utilitarian — feedback first, theater last.
5. Implementation funnels through **DesignSystem motion tokens**.

## Semantic bands

| Token | Use for | Duration band | Easing bias |
|-------|---------|---------------|-------------|
| **Micro** | Hover wash, press feedback, tiny chrome | ~0–120ms | Often **instant** or minimal opacity |
| **Meso** | Inspector, transfer queue/history, connection sheet, mirror control panel present/dismiss | ~200–350ms | System **spring** (snappy/smooth-class) when motion allowed |
| **Macro** | Connection workbench ↔ session workspace; rare onboarding segment changes | ~350–500ms | System spring when allowed; **rare** |

Bands are **guidance for implementers**, not lab-certified millisecond SLAs. Prefer named tokens over raw numbers in views.

## Spring vs linear vs none

| Surface | Rule |
|---------|------|
| Selection soft wash (list + grid) | **None** — same-frame (P1). No spring, no position bounce |
| Multi-select highlight set | **None** on primary selection chrome |
| Transfer progress bar / % | **No spring** — linear or unanimated jumps at ≤15 Hz (P4) |
| Panels / sheets / inspector | Meso spring when motion allowed |
| Progress indeterminate spinner | System `ProgressView` — no custom thrash |
| Status speed/ETA slot width | Prefer **stable layout** over animating width (0.2 fluency) |

## Must be same-frame / must not animate

1. List and grid **selection wash**  
2. Primary multi-select highlight updates  
3. Type-ahead **highlight** of the matched row (scroll-into-view may use shortest motion; highlight paint is immediate)  
4. Transfer progress **value** updates (throttle, don’t spring)  
5. Do **not** spring the entire FileBrowser tree when banners/recovery chrome appear  

## Navigation transitions

| Event | Motion |
|-------|--------|
| Open folder | **No** full-list dim/fade. Keep prior entries readable; show navigating chip/affordance within P2. Content identity swap: instant or **minimal** cross-fade only if it does not thrash scroll identity |
| Device switch (sidebar) | Content rebind: **instant or minimal cross-fade** — not a deep navigation push drama |
| Connection workbench → session | **One** Macro transition (or system navigation replacement). Reduce Motion → cross-fade or instant |
| Session → connection (disconnect) | Symmetric to above; respect disconnect confirmations from shell contract |
| Inspector show/hide | Meso |
| Transfer queue/history summon | Meso |
| ⌘K palette | System-like present; short Meso or system materialization |
| Mirror control panel | Meso present/dismiss; **no** animation contract for the external scrcpy window |

Optional **matched geometry** only for small elements (e.g. icon → panel affordance). **Forbidden:** full-screen content morphs, content-layer Liquid Glass performance pieces.

## Reduce Motion (hard contract)

When `accessibilityReduceMotion` is enabled:

| Instead of | Use |
|------------|-----|
| Springs / large moves | **Opacity cross-fade** or **instant** |
| Micro hover motion | Off or static hover color |
| Macro workspace change | Cross-fade or instant swap |
| Decorative loops | **Never** |

Selection remains **same-frame**. Transfer progress remains non-spring.

## Scrcpy-adjacent UI

- Control chrome may use Meso.
- App does **not** animate or “smooth” the external scrcpy process window.
- Recording timers / follow UI must not fight transfer progress animation budget (prefer discrete text updates).

## Non-goals

- Parallax scrolling backgrounds  
- Looping Lottie/brand decoration  
- Content-region glass morph showcases  
- Bouncy selection row scale  
- Per-brand custom physics tuning as a product pillar  
- iOS-style deep hierarchical push for every folder  

## Implementation rule

Provide a single API surface in DesignSystem, e.g.:

- `DM.Motion.micro` / `.meso` / `.macro`  
- `DM.Motion.progress` (explicitly non-spring)  
- `DM.Motion.reduced` helpers or document pairing with `accessibilityReduceMotion`

**Views must not** invent one-off `Animation.spring(response:damping:)` literals for product chrome without going through tokens (exceptions: true system controls that animate themselves).

## Handoff

- Shell prototype (ticket 10) must demonstrate: same-frame selection, Meso panel, Reduce Motion path, no list-dim navigation.  
- Architecture allow-list already permits DesignSystem expansion — no engine changes for motion.
