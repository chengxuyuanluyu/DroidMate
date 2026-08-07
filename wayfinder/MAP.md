# Wayfinder Map — DroidMate 3.0

> The canonical artifact for this effort. An **index**, not a store: each
> decision lives in exactly one place — its ticket — and the map only gists
> it and links. Open tickets are **not** listed here; they are the open child
> files in `wayfinder/tickets/`.

## Destination

A complete, **implementable DroidMate 3.0 specification package** — product
vision, visual & motion language, shell / information architecture, interaction
contracts, performance budgets, and architecture evolution bounds — such that an
implementation effort can open PR plans **without re-opening the major design
axes**. Same product identity (Mac-native **files + mirroring**); not a new
category. Map end-state is the **spec**, not the shipped binary.

## Notes

- **Domain:** macOS 15+ Apple Silicon SwiftUI app; Data Channel + scrcpy dual
  path (see root `CONTEXT.md`, `docs/ARCHITECTURE.md`, ADRs 0001–0004).
- **Baseline product:** shipped **0.2.6** (files, mirroring, Wi‑Fi UX, zh-Hans,
  MCP-via-adb). 3.0 is a major experience/architecture uplift on that base.
- **North star:** **Feel native** (macOS first-class citizen: materials, type,
  motion, shortcuts, a11y). **Performance is a hard budget**, not a nice-to-have —
  native feel that janks is a failed 3.0.
- **Compat stance:** UX / shell / IA may break boldly; **prefer continuous Data
  Channel + server jar** (small protocol evolution OK; big wire break needs its
  own explicit decision).
- **Skills every session should consult:** `grilling`, `domain-modeling`,
  `prototype`; design/motion: `apple-design`, `emil-design-eng`,
  `improve-animations` / `animation-vocabulary` as needed; structure:
  `codebase-design`. Prefer CodeGraph for structural questions.
- **Standing preferences:** Mac-only product (ADR-0003); no Android APK; no cloud
  account path; match repo style; Reduce Motion respected; Chinese + English
  user-facing strings stay governed.
- **Domain terms:** **Shell**, **Performance Budget**, **Motion Language** in
  root `CONTEXT.md`.
- **Tracker:** local-markdown (`wayfinder/`). Tickets in `wayfinder/tickets/`;
  blocking via `blocked-by` frontmatter line. Research notes in
  `wayfinder/research/`.

## Decisions so far

<!-- one line per CLOSED ticket: gist + link; charting locks listed first -->

- **[Charting] Destination form** — Implementable multi-part **3.0 spec package**
  (not “only abstract ADRs”, not “ship code inside this map”).
- **[Charting] Product ambition** — Professional-grade **same-product reinvention**
  (files + mirroring); not M7+ platform leap as the 3.0 definition.
- **[Charting] North star** — **Feel native** primary; performance as **hard
  constraint** on every experience decision.
- **[Charting] Compat gate** — Bold UX break OK; **prefer protocol/session continuity**
  with 0.2.x where possible.
- **[Charting] Default exclusions** — Android APK, true Wi‑Fi direct+TLS, MCP
  expansion, audio (sndcpy-class), Windows / Intel Mac are **out of this
  destination**. Finder `NSFileProvider` and **embedded mirror** (vs scrcpy SDL
  window) stay in fog until scoped tickets graduate.
- [0.2.6 codebase baseline](tickets/04-codebase-baseline-research.md) — MainActor
  DeviceSession graph; thickest edge UI→FileClient→TransferEngine→Transport;
  transfer thrash already capped (~15 Hz); packaging forbids naive
  `Bundle.module`; shell risks = observation fan-out, shared-channel thumbs,
  session chrome lifecycle. Note:
  [research/04-codebase-baseline.md](research/04-codebase-baseline.md).
- [macOS design & motion primitives](tickets/05-macos-design-motion-research.md) —
  Prefer Liquid Glass **system chrome** (`NavigationSplitView` + toolbar +
  inspector), standard materials in content; springs/matched-geometry + Reduce
  Motion cross-fade; Finder-grade grid/DnD may need surgical AppKit. Note:
  [research/05-macos-design-motion.md](research/05-macos-design-motion.md).
- [3.0 spec package shape & “done” criteria](tickets/01-spec-package-shape.md) —
  Package at **`docs/3.0/`** (EN, multi-chapter); mandatory vision / visual /
  motion / shell-IA / interaction / performance / architecture-bounds +
  implementation-waves; protocol truth stays ARCHITECTURE+PROTOCOL+ADR; hard
  done = all mandatory **locked** + ticket-linked Decisions + PR-plan-ready;
  no full task list/mocks/CI/copy/code in package. Scaffold created.
- [Visual design language stance](tickets/02-visual-design-language.md) —
  **Hybrid** + two-layer materials (glass chrome / standard content); Follow
  System appearance; **system accent**; evolve soft selection wash; SF Symbols +
  system type; utility density OK. Chapter:
  [docs/3.0/visual-language.md](../docs/3.0/visual-language.md) **locked**.
- [Interaction north-star depth](tickets/03-interaction-north-star-depth.md) —
  Finder-grade **in-app** browse; evolve connection; **first-class** transfers;
  thin mirror controls + external scrcpy; ⌘K core; sidebar multi-device; keyboard
  Must / VoiceOver progressive Should. Chapter:
  [docs/3.0/interaction-contracts.md](../docs/3.0/interaction-contracts.md)
  **locked**. Unblocks ticket 06.
- [Shell & information architecture direction](tickets/06-shell-and-ia-direction.md) —
  **Evolve** connection→session workspace; `NavigationSplitView` + collapsible
  inspector; summonable transfers; thin mirror panel + external scrcpy; Devices
  + Locations sidebar; Settings window + ⌘K. Chapter:
  [docs/3.0/shell-and-ia.md](../docs/3.0/shell-and-ia.md) **locked**.
  Unblocks ticket 08.
- [Performance budgets](tickets/07-performance-budgets.md) — Five ship gates:
  same-frame selection; nav feedback ≤100ms; ~2k list scroll; transfer UI ≤15Hz
  + observation isolation; bounded cancellable adb/connect. Hybrid verify;
  breach order isolation→…→protocol last. Chapter:
  [docs/3.0/performance-budgets.md](../docs/3.0/performance-budgets.md) **locked**.
- [Architecture evolution bounds](tickets/08-architecture-evolution-bounds.md) —
  **Strangler** UI/shell; freeze Wire/session/transfer/transport/scrcpy/MCP/
  packaging; allow view split + observation hygiene; no protocol/ADR reopen by
  default; optional SPM UI target. Chapter:
  [docs/3.0/architecture-bounds.md](../docs/3.0/architecture-bounds.md) **locked**.
- [Motion language principles](tickets/09-motion-language.md) — Micro/Meso/Macro
  bands; system springs for panels; **no spring on selection/progress**; Reduce
  Motion hard dual-path; utilitarian nav; `DM.Motion.*` single entry. Chapter:
  [docs/3.0/motion-language.md](../docs/3.0/motion-language.md) **locked**.
  Unblocks ticket 10.
- [Shell visual / motion prototype](tickets/10-shell-visual-prototype.md) —
  Human verdict **方向对** (this is the 3.0 direction). Asset:
  [prototypes/shell-3.0](prototypes/shell-3.0/). No reopen of 02/06/09.
- **[Assembly] Vision + implementation waves locked** — charting + tickets 01–10
  promoted into [docs/3.0/vision.md](../docs/3.0/vision.md) and
  [docs/3.0/implementation-waves.md](../docs/3.0/implementation-waves.md).
  **Map destination reached:** `docs/3.0/` package decision-complete.

## Not yet specified

<!-- fog cleared for this destination; residuals in package appendix -->

_None blocking._ Residual Later / implementation-time items:
[docs/3.0/open-questions.md](../docs/3.0/open-questions.md).

## Out of scope

<!-- beyond this destination; never graduates on this map -->

- **Implementing and shipping the 3.0 binary** — this map stops when the spec is
  decision-complete and implementable; build is a later effort (`/execute-plan`
  or a new map).
- **Android APK / phone-side UI** — ADR-0003.
- **True Wi‑Fi direct (bypass wireless adb) + TLS pairing** — Phase-2 networking.
- **MCP capability expansion** beyond current adb-tool posture (ADR-0004 stands
  unless a future map reopens it).
- **Audio forwarding** (sndcpy-class).
- **Windows client / Intel Mac** as first-class targets.
