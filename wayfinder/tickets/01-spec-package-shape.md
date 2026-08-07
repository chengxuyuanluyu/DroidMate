# Ticket 01 — 3.0 spec package shape & “done” criteria

`wayfinder:grilling` · **status: closed (resolved)** · `blocked-by:` none
· **claimed:** resolved this session

## Question

What **concrete set of documents** (paths, sections, owners) constitutes the
DroidMate 3.0 specification package, and what is the **acceptance checklist**
that means this map’s Destination is reached?

Settle at least:

1. **Doc tree** — e.g. `docs/3.0/` vs single mega-spec vs ADRs + one vision doc.
2. **Required chapters** — vision, visual language, motion language, shell/IA,
   interaction contracts, performance budgets, architecture bounds, (optional)
   migration notes — which are mandatory vs appendix.
3. **Done means** — every chapter has locked decisions (with ticket links), open
   questions = 0 on major axes, and an implementer can draft a PR plan without
   new product grilling on those axes.
4. **What is explicitly not in the package** — e.g. pixel-perfect mock dumps,
   full task breakdown, CI matrix (unless you want them).

This ticket does **not** write the full content of those docs — it only locks
their shape and completion bar so later tickets know where answers land.

## Resolution

**Locked 2026-08-07** (user: all recommendations).

### Doc tree

- Package root: **`docs/3.0/`**
- Index: `docs/3.0/README.md` (chapter list + per-chapter status)
- One markdown file per chapter (not a single mega-spec; not scattered only
  across PLAN/ADR without a package index)

### Relationship to existing docs

- **3.0 package** = source of truth for **vision, visual/motion language, shell/IA,
  interaction contracts, performance budgets, architecture evolution bounds**
- **`docs/ARCHITECTURE.md` + `docs/PROTOCOL.md` + `docs/adr/*`** remain source of
  truth for dual-channel topology and wire protocol
- 3.0 Architecture bounds chapter **points at** those docs; new/amended ADRs only
  when ticket 08 (or later) forces a hard architectural change

### Mandatory chapters

| File | Chapter |
|------|---------|
| `vision.md` | Product ambition, north star, non-goals |
| `visual-language.md` | Visual design language |
| `motion-language.md` | Motion language |
| `shell-and-ia.md` | Shell & information architecture |
| `interaction-contracts.md` | Interaction pillars (must / should / later) |
| `performance-budgets.md` | Measurable performance budgets |
| `architecture-bounds.md` | What may change vs frozen vs protocol stance |

### Appendix / conditional

| File | When |
|------|------|
| `migration.md` | If 0.2→3.0 settings/history decisions land; else omit or stub “TBD / out of first implementable cut” |
| `open-questions.md` | Only if map ends with intentional residual fog |
| Prototype links | In Visual / Shell chapters → ticket 10 asset; **no** standalone mock chapter |
| `implementation-waves.md` | **In package:** dependency-ordered waves (not a calendar sprint plan) |

### Language

- **English primary** for all `docs/3.0/` files (align with existing docs/ADRs).
- Chinese may appear in discussion; agents land English on disk.

### Map Destination = package complete when (hard gates)

1. `docs/3.0/README.md` lists every **mandatory** chapter with status **`locked`**
2. Each locked chapter opens with a **Decisions** summary + links to closed
   wayfinder tickets that produced them
3. No open questions remain on major axes (fog closed, deferred to Later, or
   moved to map Out of scope)
4. An implementer can draft a **PR plan outline** (module order + do-not-touch
   list) from the package alone, without further product grilling on those axes

**Soft gate:** ticket 10 prototype linked from Visual/Shell chapters; if skipped,
Shell chapter must state “no prototype — principles govern.”

### Explicitly not in the package

- Full task breakdown / sprint tickets
- Pixel-perfect full mock sets as contract
- CI matrix
- Launch marketing copy final
- Implementation source code

### Scaffold

Empty chapter shells + README created under `docs/3.0/` in the resolving
session so later tickets know write targets. Content fills as other tickets
resolve — this ticket does not author chapter substance beyond structure.
