# UX Fluency Initiative — DroidMate

**Date:** 2026-07-31  
**Goal:** Interaction and smoothness feel professional (Finder-grade), not “almost works”.

## North-star criteria

| Signal | Pass when |
|--------|-----------|
| Selection | Single click paints highlight same frame |
| Navigation | Folder open keeps list readable; progress non-blocking |
| Scroll | Large folders stay smooth (List/Lazy, no full-tree rebuild) |
| Transfer UI | Progress ≤15 Hz, no double-publish thrash |
| Feedback | Hover / press language consistent; Reduce Motion respected |
| Errors | Localized, actionable; no dead chrome |
| Type-ahead | Letter keys jump to matching names (Finder-like) |

## Waves

### Wave 1 — Responsiveness ✅

- [x] List selection chrome (not `listRowBackground(Color.clear)`)
- [x] Grid tap reliability (`Button` vs `onTapGesture` + drag)
- [x] Instant selection (no spring lag on select)
- [x] List row hover wash
- [x] Drop full-list opacity dim during navigation
- [x] Stop animating entire browser on transport/recovery
- [x] Transfer progress: remove redundant `objectWillChange.send()`

### Wave 2 — Navigation & density ✅

- [x] Breadcrumb stable identity (path-based, not UUID-per-render)
- [x] Type-ahead jump (list + grid) + unit tests
- [x] Inspector re-id by selection; no animated thrash on reselect
- [x] Path bar search focus animation softened
- [x] Navigation progress chip only (no list dim) — from Wave 1

### Wave 3 — Transfer & mirror chrome ✅

- [x] Status bar fixed-width speed/ETA slots (less layout thrash)
- [x] Progress bar un-springed
- [x] Mirror panel: fewer blanket `objectWillChange` on serial set churn
- [x] Drop overlay snappier materialize

### Wave 4 — Polish & audit ✅

- [x] Reduce Motion on grid hover, nav chip, path bar, list hover
- [x] Manual UX smoke checklist below
- [x] Typeahead unit tests (+ restart / cycle cases)
- [x] CR follow-ups: grid column geometry, scroll-to-selection, 15 Hz transfer publish, typeahead anchor
- [ ] Instruments on 2k+ folders — optional local QA (not CI)

## Manual UX smoke (before release)

1. **Select** — list: single click folder → blue fill same frame; ⌘/⇧ multi-select
2. **Grid select** — single click reliable; drag-out still works
3. **Type-ahead** — type first letters of a folder name; same letter cycles
4. **Navigate** — open deep folders: list stays opaque; “Opening…” chip only
5. **Breadcrumb** — click middle segment; no flicker
6. **Transfer** — multi-file upload: status bar %/speed stable width; queue opens
7. **Drop** — drag files over list: overlay appears quickly
8. **Mirror bar** — open mirror; floating bar follows without jank
9. **Reduce Motion** — system setting on: no bouncy chrome
10. **Locale** — zh-Hans: connection errors Chinese; selection still works

## Non-goals

- Redesigning product IA wholesale
- QR pairing / new major features
- Android-side server rewrite
