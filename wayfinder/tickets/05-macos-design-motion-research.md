# Ticket 05 — macOS design system & motion primitives (research)

`wayfinder:research` · **status: closed (resolved)** · `blocked-by:` none (frontier) · unblocks 09
· **claimed:** research subagent (charting session)

## Question

What **platform-native building blocks** (macOS 15+, SwiftUI / AppKit bridges)
should constrain DroidMate 3.0’s visual and motion language so “feel native” is
implementable rather than aspirational?

Research **primary sources** (Apple docs, release notes, SDK headers as needed):

1. **Materials & chrome** — available SwiftUI materials, toolbar/sidebar APIs,
   window style options relevant to a utility + browser hybrid app.
2. **Motion** — matched geometry, transitions, animation completion, Reduce
   Motion hooks; what is first-class in SwiftUI on Mac vs needs AppKit.
3. **Input & density** — multi-select, keyboard navigation patterns Apple
   documents for lists/collections on Mac; pointer/hover expectations.
4. **Limits** — known Mac SwiftUI gaps that force AppKit or custom drawing for
   Finder-grade file grids (if any hard limits appear).
5. **Implication list** for 3.0 — “prefer X API”, “avoid fighting Y”.

**Output:** `wayfinder/research/05-macos-design-motion.md` with links to Apple
documentation. Resolution points at that note. Unblocks motion language ticket.

## Resolution

- **Status:** closed (resolved)
- **Gist:** 3.0 must ride **Liquid Glass system chrome** (`NavigationSplitView` +
  toolbar/`ToolbarSpacer` + inspector) and keep **standard materials in content**;
  motion is springs/matched-geometry/glass-morph with a mandatory **Reduce Motion
  → cross-fade** path; Mac density means multi-select List/Table, keyboard, hover;
  Finder-grade grids/DnD may force surgical **AppKit** bridges — don’t fight glass
  or invent content-layer glass.
- **Note:** [wayfinder/research/05-macos-design-motion.md](../research/05-macos-design-motion.md)
- **Unblocks:** ticket 09 (motion language) with API + dual-path constraints ready.
