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

## Waves

### Wave 1 — Responsiveness (this pass)

- [x] List selection chrome (not `listRowBackground(Color.clear)`)
- [x] Grid tap reliability (`Button` vs `onTapGesture` + drag)
- [x] Instant selection (no spring lag on select)
- [x] List row hover wash
- [x] Drop full-list opacity dim during navigation
- [x] Stop animating entire browser on transport/recovery
- [x] Transfer progress: remove redundant `objectWillChange.send()`

### Wave 2 — Navigation & density

- [ ] Optimistic path bar / breadcrumb while list loads
- [ ] Keyboard focus ring + type-ahead jump (Finder letter jump)
- [ ] Inspector update without hitching list
- [ ] Empty / loading state polish (skeleton only when truly empty)

### Wave 3 — Transfer & mirror chrome

- [ ] Dock badge / status bar without layout thrash
- [ ] Mirror panel control feedback latency
- [ ] Drop target / upload overlay snappier

### Wave 4 — Polish & audit

- [ ] Interaction audit checklist (smoke for UX)
- [ ] Instruments pass on 2k+ file folders
- [ ] Reduce Motion full pass

## Non-goals

- Redesigning product IA wholesale
- QR pairing / new major features
- Android-side server rewrite
