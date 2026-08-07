# Research 05 — macOS design system & motion primitives

**Ticket:** [05-macos-design-motion-research](../tickets/05-macos-design-motion-research.md)  
**Scope:** Platform-native building blocks (macOS 15+, SwiftUI / AppKit) that should constrain DroidMate 3.0 visual & motion language.  
**Product lens:** Mac utility — file browser + connection + scrcpy mirroring controls.  
**Sources:** Apple Developer Documentation, HIG, SwiftUI updates, first-party WWDC sessions.  
**Date:** 2026-08-07

---

## Executive takeaway

DroidMate 3.0 should **ride the system chrome**, not invent a second one.

On current SDKs, “feel native” is largely:

1. **Liquid Glass navigation layer** (sidebar, toolbar, menus) via standard `NavigationSplitView` + toolbar APIs — not hand-drawn materials.
2. **Standard materials only in the content layer** (lists, grids, status).
3. **System motion** (springs, zoom/matched-geometry morphs, glass morphing) with **Reduce Motion / cross-fade** as first-class paths.
4. **Mac input density**: multi-select `List`/`Table`, keyboard focus, hover affordances, menu-bar commands.
5. **Surgical AppKit** only where Finder-grade file grids exceed SwiftUI (selection physics, large virtualized icon grids, true file-URL drag).

Fighting any of those five is the main way a redesign fails the north star.

---

## 1. Materials & chrome

### 1.1 Two material layers (hard rule)

Apple now distinguishes:

| Layer | Material | Role |
| --- | --- | --- |
| **Functional / navigation** | **Liquid Glass** | Sidebars, toolbars, tab bars, floating controls — distinct layer above content |
| **Content** | **Standard materials** (`Material` ultraThin…thick; AppKit `NSVisualEffectView`) | Structure *within* content: app backgrounds, grouped tables, panels under glass |

Primary docs:

- [Materials (HIG)](https://developer.apple.com/design/human-interface-guidelines/materials) — Liquid Glass vs standard materials; macOS notes `NSVisualEffectView.Material` + behind-window / within-window blending.
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) — rebuild with latest SDK; standard components pick up glass automatically; **remove custom backgrounds** on bars/split views.
- [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)

**Rules from Apple that constrain 3.0:**

- **Do not put Liquid Glass in the content layer** (file grid cells, transfer rows, status strips as glass slabs). Exception: transient interactive knobs (slider/toggle) may take glass while active.
- **Use Liquid Glass sparingly on custom chrome** — limit to the most important functional elements; overuse distracts from content.
- **Regular vs clear glass:** regular for legibility (sidebars, alerts, text-heavy surfaces); clear only over rich media (e.g. optional mirror preview chrome) with dimming if needed.
- **Test Reduce Transparency / Increase Contrast / preferred Liquid Glass look** — system components adapt; custom glass must be verified.

### 1.2 Shell structure for a utility + browser hybrid

Canonical Mac shell for DroidMate-class apps:

```
Window
└── NavigationSplitView
    ├── sidebar: devices / locations / connection state
    ├── content: file browser (list/table/icon grid)
    └── detail or .inspector: selection inspector / transfer / device props
+ system toolbar (actions: connect, path, view mode, scrcpy)
+ menu bar commands
```

**Prefer:**

| Building block | Why for DroidMate |
| --- | --- |
| [`NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview) | System Liquid Glass sidebar; fluid column reflow on resize ([Adopting Liquid Glass — Windows](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)) |
| [`ListStyle.sidebar`](https://developer.apple.com/documentation/swiftui/liststyle/sidebar) | Native sidebar density; respects System Settings sidebar icon size ([Sidebars HIG](https://developer.apple.com/design/human-interface-guidelines/sidebars)) |
| Standard `.toolbar { }` + grouping / [`ToolbarSpacer`](https://developer.apple.com/documentation/swiftui/toolbarspacer) | Liquid Glass toolbar; item groups on shared glass; spacers split groups ([SwiftUI updates June 2025](https://developer.apple.com/documentation/updates/swiftui)) |
| [`.inspector`](https://developer.apple.com/videos/play/wwdc2023/10161/) on detail | Trailing inspector for selection metadata / transfer details without a custom panel stack |
| [`backgroundExtensionEffect()`](https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()) | Edge-to-edge content under floating sidebar/inspector (hero thumbnails, mirror strip) |
| [`scrollEdgeEffectStyle(_:for:)`](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)) | Legibility when content scrolls under bars |
| SF Symbols in toolbars/menus | System hover/selection; no custom bezels ([Toolbars HIG](https://developer.apple.com/design/human-interface-guidelines/toolbars)) |

**Window / scene types:**

- Primary browser window: default document-style window with unified toolbar chrome ([Windows HIG — macOS](https://developer.apple.com/design/human-interface-guidelines/windows)).
- Optional auxiliary: [`UtilityWindow`](https://developer.apple.com/documentation/swiftui/utilitywindow) (macOS 15+) for floating connection/log/tools — not a second full shell.
- Avoid custom window frames/controls (HIG: “Avoid creating custom window UI”).

**AppKit materials when bridging:**

Semantic `NSVisualEffectView.Material` cases remain the reference for content-layer vibrancy: `sidebar`, `titlebar`, `headerView`, `contentBackground`, `selection`, etc. ([Material enum](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum)). Use for hosted AppKit panes; do not invent alternate blurs.

**What to strip from 0.2.x-style custom chrome (design constraint):**

- Hand-painted toolbar backgrounds, opaque sidebar fills, ad-hoc “glass” rectangles.
- Mixing text + icon labels inconsistently inside one glass group.
- Critical actions only at the bottom of a sidebar (often clipped when windows are dragged).

WWDC first-party: [Build a SwiftUI app with the new design (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/323/), [What’s new in SwiftUI (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/256/), [Get to know the new design system (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/356/).

---

## 2. Motion

### 2.1 HIG principles (platform contract)

From [Motion (HIG)](https://developer.apple.com/design/human-interface-guidelines/motion):

- Motion is **purposeful**; gratuitous animation fails.
- **Make motion optional** — never the only channel for status (pair with text, haptics-not-relevant-on-Mac, or static state).
- Prefer **brief, precise** feedback; avoid animating **high-frequency** UI (hover ticks, every list refresh).
- **Cancellable** — don’t force users to wait out animation to act again.
- Liquid Glass motion is **input-sensitive** (trackpad more subdued than touch) — system components already handle this.

### 2.2 First-class SwiftUI motion APIs (Mac)

| Capability | API / pattern | Use in 3.0 |
| --- | --- | --- |
| Implicit / explicit animation | `animation(_:value:)`, `withAnimation` | State changes: path, selection highlight, panel open |
| Springs | `Animation.spring` / interactive springs | Default language for UI retargeting (folder open, inspector) |
| Matched geometry | `matchedGeometryEffect(id:in:…)` | Icon → preview, view-mode morphs (list ↔ grid) *when same hierarchy* |
| Navigation zoom | `navigationTransition(.zoom(sourceID:in:))` (iOS 18+ family; use where available for large cells) | Thumbnail → preview / editor continuity ([WWDC24 10145](https://developer.apple.com/videos/play/wwdc2024/10145/)) |
| Glass morphing | `glassEffect`, `GlassEffectContainer`, `glassEffectID`, `glassEffectTransition` (`.matchedGeometry` / `.materialize`) | Custom floating control clusters (connect FAB group, multi-action glass buttons) — not file cells ([Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)) |
| Transitions | `.transition`, insertion/removal | Sheets, overlays; prefer system sheet morph from presenting control |
| Symbol motion | SF Symbols effects | Connection / transfer status glyphs |
| Completions / bridging | `UIView`/`NSView` animate with SwiftUI `Animation` (iOS 18 / macOS 15 era interop) | Scrcpy or AppKit-hosted surfaces staying in phase with SwiftUI ([WWDC24 10145](https://developer.apple.com/videos/play/wwdc2024/10145/)) |
| Animatable synthesis | `@Animatable` macro (2025) | Custom progress / path indicators |

### 2.3 Reduce Motion (mandatory path)

Environment:

- [`accessibilityReduceMotion`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
- [`accessibilityPrefersCrossFadeTransitions`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilitypreferscrossfadetransitions) (Reduce Motion + Prefer Cross-Fade)

**3.0 motion language must define dual curves:**

| Full motion | Reduced |
| --- | --- |
| Spring morph, matched geometry, glass blend | Opacity / cross-fade only; instant layout |
| Zoom navigation | Cross-fade or push without scale |
| Large travel (sidebar collapse, window mode) | Fade + hard cut |

Also respect **Reduce Transparency** when custom materials exist ([Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)).

### 2.4 SwiftUI vs AppKit on Mac

| Concern | SwiftUI | AppKit |
| --- | --- | --- |
| Standard window transitions | Preferred | Legacy `NSAnimationContext` only for pure AppKit panes |
| Cross-framework sync | SwiftUI `Animation` driving `NSView` animate | Bridge via representable `context.animate` pattern (WWDC24) |
| Selection / scroll physics in large collections | Good for List/Table; weaker for custom icon grids | `NSCollectionView` / `NSTableView` still gold standard for Finder-like behavior |
| Continuously interactive gestures | SwiftUI gesture + interactiveSpring | AppKit gesture recognizers via `NSGestureRecognizerRepresentable` (2025) when needed |

**Avoid:** parallel Core Animation timelines fighting SwiftUI transactions; double-animating the same property from AppKit and SwiftUI.

---

## 3. Input & density

### 3.1 Selection

- **`List` / `Table` with `selection: Binding<Set<ID>>`** — multi-select is first-class; Shift/Command behavior comes with system lists/tables.
- Per-row opt-out: [`selectionDisabled(_:)`](https://developer.apple.com/documentation/swiftui/view/selectiondisabled(_:)) ([SwiftUI updates](https://developer.apple.com/documentation/updates/swiftui)).
- Multi-select context menus are supported (WWDC22 SwiftUI on iPad / shared APIs) — selection set should drive bulk transfer / delete / share.
- [Lists and tables HIG — macOS](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables): sortable columns, resizable columns, alternating rows for wide multicolumn tables; use **outline** for hierarchy (folders), not a flat table.

### 3.2 Keyboard

- Full keyboard access is a platform expectation ([Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)): focus rings, tab order, arrow navigation in lists/tables.
- SwiftUI: `focusable`, `focused`, `onKeyPress`, menu `commands` / keyboard shortcuts ([Input events](https://developer.apple.com/documentation/swiftui/input-events)).
- **Do not override system shortcuts**; file-browser expectations: arrows, Enter open, Cmd-A select all, Delete, Cmd-C/V where meaningful.
- Control sizes on Mac: default ~28×28 pt, min 20×20 pt (HIG Accessibility). Prefer **compact density** in inspectors (`controlSize`) while keeping hit targets legal.

### 3.3 Pointer / hover

- [`onHover`](https://developer.apple.com/documentation/swiftui/view/onhover(perform:)) / `onContinuousHover` for reveal-on-hover actions (e.g. bookmark, quick info) — pair with **always-available** menu / accessibility actions (WWDC25 a11y session pattern).
- System toolbar symbols get hover automatically; custom hover chrome should not invent non-Mac hover colors.
- Density: larger list/table row padding is now the Liquid Glass default — **don’t compress rows back to iOS-like density** after rebuild ([Adopting Liquid Glass — lists](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)).

### 3.4 Drag & drop (file browser reality)

SwiftUI `Transferable` / `draggable` works for many cases, but **sandbox may rewrite file URLs to temporary copies** (documented developer pain on current SDKs). For Finder-grade “drag real device/file URL,” plan an AppKit pasteboard path when product requires it — treat as a known limit (see §4), not a styling issue.

---

## 4. Limits — where SwiftUI forces AppKit / custom

These are **hard or soft limits** that affect a Finder-grade file browser + utility chrome. Prefer SwiftUI until one of these is hit; then bridge surgically.

| Gap | Symptom | Practical escape |
| --- | --- | --- |
| **Very large virtualized icon grids** | `LazyVGrid` in `ScrollView` can hitch, blank, or mis-estimate heterogeneous cell heights under fast scroll (community + performance work ongoing; Apple improved List speed, not all grid cases) | `NSCollectionView` compositional layout hosted via `NSViewRepresentable`, or hybrid: SwiftUI chrome + AppKit grid |
| **Finder-identical selection physics** | Rubber-band marquee, type-select, discontinuous range quirks | AppKit collection/table |
| **True file URL drag** | SwiftUI drag often yields container temp URLs | AppKit drag session / `NSItemProvider` with real URL |
| **Pixel-identical sidebar selection chrome** | Custom selected-row accent (text vs fill) hard to match Finder/Photos exactly | Prefer system `List` + sidebar style; avoid custom row backgrounds that break Liquid Glass |
| **Heavy continuous video surface (scrcpy)** | External process / SDL window; not a SwiftUI `VideoPlayer` | Keep process boundary (existing architecture); if embedding later, `NSView` host — motion language treats it as **foreign surface** (no fake glass over video frames without clear glass + dimming rules) |
| **NSToolbar edge cases** | Overflow, principal items, dual-title | Mostly covered by SwiftUI toolbar; fall back to AppKit toolbar only if customization exceeds SwiftUI |
| **Outline + multi-column + live resize perfection** | `Table` is strong; extreme Finder columns still easier in `NSOutlineView` | Use SwiftUI `Table` first; AppKit outline for deep hierarchy + many columns if needed |

**Interop primitives (allowed, not “defeat”):**

- [`NSViewRepresentable`](https://developer.apple.com/documentation/swiftui/nsviewrepresentable) / [`NSHostingView`](https://developer.apple.com/documentation/swiftui/nshostingview)
- [`NSHostingSceneRepresentation`](https://developer.apple.com/documentation/swiftui/nshostingscenerepresentation) (scene bridging, 2025)
- Shared animation: SwiftUI animations on AppKit views ([Unifying your app’s animations](https://developer.apple.com/documentation/swiftui/unifying-your-app-s-animations), WWDC24 10145)

---

## 5. Implication list for DroidMate 3.0

### Prefer

1. **`NavigationSplitView` + system sidebar list** for shell IA (devices / places / connection).
2. **System toolbar + `ToolbarSpacer` groups** for connect / path / view mode / mirror actions; SF Symbols only in shared glass groups.
3. **Liquid Glass only on navigation/functional chrome**; standard materials / solid fills in the file browser content.
4. **`Table` for details view, `List` for compact, `LazyVGrid` for icon view until scale forces AppKit.**
5. **`.inspector` for selection / transfer / device properties** instead of bespoke trailing panels.
6. **`backgroundExtensionEffect` + scroll edge effects** so content breathes under floating chrome.
7. **Spring-based motion language** with explicit **Reduce Motion → cross-fade** dual path; read `accessibilityReduceMotion` / `accessibilityPrefersCrossFadeTransitions`.
8. **Glass morphing (`GlassEffectContainer` + IDs)** only for small control clusters (e.g. connection actions), never per-file-cell.
9. **Multi-select `Set` bindings + multi-item context menus + menu bar commands** as the transfer/bulk UX spine.
10. **Hover reveals + always-on accessibility actions / menus** for the same operations.
11. **SwiftUI `Animation` bridged into any AppKit-hosted grid** so selection and chrome stay in one timeline.
12. **Rebuild against latest SDK** so Liquid Glass / row metrics arrive “for free”; avoid `UIDesignRequiresCompatibility`-style freezes long-term.

### Avoid / do not fight

1. **Custom blur stacks** under toolbars/sidebars that fight Liquid Glass and scroll edge effects.
2. **Liquid Glass file cells, transfer rows, or full-window glass skins.**
3. **iOS-density spacing** reintroduced on Mac after Liquid Glass padding increases.
4. **Motion as sole status** (e.g. only a bouncing glyph for “connected”).
5. **Non-cancellable multi-second transitions** on path change or device switch.
6. **Parallel animation systems** (raw `CAAnimation` + SwiftUI) on the same view tree without a single owner.
7. **Replicating Finder pixel-perfect chrome** with custom drawing when system `List`/`Table` is 90% there — invest in behavior (keys, multi-select, DnD), not fake materials.
8. **Assuming SwiftUI drag is Finder DnD** for real file URLs without verifying pasteboard contents.
9. **Putting critical controls only at sidebar bottom** or only in hover-only UI.
10. **Animating every list diff** on directory refresh — high-frequency surfaces stay quiet.
11. **Embedding scrcpy as if it were a SwiftUI card with heavy glass chrome** without media-clear rules and performance budgets.
12. **One-size motion curves on Mac trackpad** that ignore that system glass is already quieter for pointer input.

### Direct handoff to ticket 09 (Motion Language)

Ticket 09 should codify, not rediscover:

- Token table: duration / spring (response, damping) for: selection, panel, navigation, destructive, connection state.
- Reduce Motion matrix (full vs reduced) for each token.
- Forbidden: per-cell glass, continuous ambient motion on file grids, uncancellable path transitions.
- Allowed morphs: view-mode change, inspector present, glass control cluster, optional zoom from large thumbnail.

### Direct handoff to tickets 02 / 06 / 10

- **02 Visual language:** materials tokens map to Liquid Glass (chrome) vs standard materials (content); SF Symbol + controlSize ladder.
- **06 Shell/IA:** `NavigationSplitView` + inspector is the default skeleton unless research on multi-window says otherwise.
- **10 Prototype:** prove system chrome first; only then custom glass accents.

---

## Primary source index

| Topic | URL |
| --- | --- |
| Materials HIG | https://developer.apple.com/design/human-interface-guidelines/materials |
| Motion HIG | https://developer.apple.com/design/human-interface-guidelines/motion |
| Sidebars HIG | https://developer.apple.com/design/human-interface-guidelines/sidebars |
| Toolbars HIG | https://developer.apple.com/design/human-interface-guidelines/toolbars |
| Lists & tables HIG | https://developer.apple.com/design/human-interface-guidelines/lists-and-tables |
| Windows HIG | https://developer.apple.com/design/human-interface-guidelines/windows |
| Split views HIG | https://developer.apple.com/design/human-interface-guidelines/split-views |
| Accessibility HIG | https://developer.apple.com/design/human-interface-guidelines/accessibility |
| Adopting Liquid Glass | https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass |
| Applying Liquid Glass to custom views | https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views |
| SwiftUI updates | https://developer.apple.com/documentation/updates/swiftui |
| NavigationSplitView | https://developer.apple.com/documentation/swiftui/navigationsplitview |
| Input events | https://developer.apple.com/documentation/swiftui/input-events |
| accessibilityReduceMotion | https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion |
| AppKit integration | https://developer.apple.com/documentation/swiftui/appkit-integration |
| NSVisualEffectView.Material | https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum |
| WWDC25 — Build a SwiftUI app with the new design | https://developer.apple.com/videos/play/wwdc2025/323/ |
| WWDC25 — What’s new in SwiftUI | https://developer.apple.com/videos/play/wwdc2025/256/ |
| WWDC25 — Get to know the new design system | https://developer.apple.com/videos/play/wwdc2025/356/ |
| WWDC24 — Enhance your UI animations and transitions | https://developer.apple.com/videos/play/wwdc2024/10145/ |
| WWDC23 — Inspectors in SwiftUI | https://developer.apple.com/videos/play/wwdc2023/10161/ |
| Landmarks (Liquid Glass sample) | https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass |

---

## Out of scope for this note

- Concrete spring numbers / token names (ticket 09).
- Final shell wireframes (tickets 06 / 10).
- Performance budgets for scroll FPS (ticket 07) — only flags that glass overuse and large grids are risk areas.
- Implementation in the app target.
