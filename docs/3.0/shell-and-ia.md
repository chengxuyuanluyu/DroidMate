# 3.0 — Shell & information architecture

> **Status:** locked  
> **Source tickets:** [wayfinder/tickets/06-shell-and-ia-direction.md](../../wayfinder/tickets/06-shell-and-ia-direction.md)  
> **Depends on:** [visual-language.md](visual-language.md), [interaction-contracts.md](interaction-contracts.md)  
> **Platform research:** [wayfinder/research/05-macos-design-motion.md](../../wayfinder/research/05-macos-design-motion.md)  
> **Directional prototype:** [wayfinder/prototypes/shell-3.0](../../wayfinder/prototypes/shell-3.0/) (ticket 10 — direction confirmed)

## Decisions

1. **Evolve** 0.2 mental model — do not restructure into top-level spaces or multi-window product.
2. **Active session shell** = `NavigationSplitView` (sidebar + content) + **collapsible inspector** + status summary chrome.
3. **Connection** = full-page workbench when no ready session; sheet/temporary full-page when adding/repairing in-session.
4. **Transfers** = first-class summonable queue/history (not permanent fourth column); status bar remains summary.
5. **Mirror controls** = toolbar + thin expandable panel; **scrcpy external window**.
6. **Sidebar IA** = Devices (top) + Locations for active device (bottom).
7. **Settings** = system Settings window; **⌘K** = action palette, not settings dump.
8. **Multi-device** = single window, sidebar session switch, one primary content focus.
9. **Must-not-regress** list and **shell non-goals** below are part of the contract.

## Primary flows

### A — First run / no ready session

```
Main window
└── Connection workbench (full page)
    ├── situational home (USB / wireless / mDNS / recent)
    └── add-phone wizard when needed
```

Success → create Device Session → transition to **Flow B**.

### B — Active session workspace

```
Main window
├── NavigationSplitView
│   ├── Sidebar
│   │   ├── Devices (online / failed / reconnect)
│   │   └── Locations (active device shortcuts)
│   ├── Content — File browser (list | grid)
│   └── Inspector (optional) — selection metadata / preview
├── Toolbar — path, view mode, transfer, mirror, connect actions
├── Status summary — transfer/session chips (not the only transfer UI)
└── Summonable: Transfer queue/history · Mirror control panel · ⌘K · Connection sheet
```

External: **scrcpy** SDL/window process (not inside content).

## Surface placement

| Surface | Placement |
|---------|-----------|
| Connection (cold) | Full-page workbench |
| Connection (in-session add/repair) | Sheet or temporary full-page |
| Browse | Content column (primary) |
| Locations | Sidebar, **scoped to active device** |
| Devices / multi-session | Sidebar list; switch changes content binding |
| Selection details | Trailing **inspector** (collapsible) |
| Transfers | Summonable first-class panel/sheet + status summary |
| Mirror controls | Toolbar + thin expandable panel |
| Mirror video | External scrcpy window |
| Settings | macOS Settings scene/window |
| Command palette | Modal ⌘K overlay |
| Menu bar | Standard macOS commands + optional transfer/mirror shortcuts |

## Navigation model

- **Always visible (in session):** sidebar structure, content browser, way to open transfers and mirror controls, status summary.
- **Progressive disclosure:** inspector, transfer queue/history, mirror panel, connection sheet, ⌘K.
- **No** permanent transfers column as default layout.
- Prefer system split/toolbar so **Liquid Glass** applies on navigation chrome; content uses standard materials ([visual-language.md](visual-language.md)).

## Multi-device (shell only)

- One main window owns a pool of sessions (`ConnectionManager` concept).
- Sidebar selection sets **active** session; file client / inspector / locations bind to it.
- Failed device: visible state + reconnect action (interaction Must).
- **Not required:** window-per-device, tabs-per-device, dual content columns.

## Must not regress (0.2.x → 3.0 shell)

1. Situational connection home (job-based USB/wireless/mDNS paths)  
2. Multi-device sidebar + session switch  
3. File browse reachable whenever a session is active  
4. Confirm disconnect while transfers are running  
5. Command palette / shortcuts reach core connect·browse·transfer·mirror actions  
6. Mirror can be started from session UI (not CLI-only)

## Shell non-goals (3.0)

- Default separate product windows for transfers or connection  
- Top-level IA rewrite (devices/transfers as equal “app spaces”)  
- Embedded mirror canvas inside content  
- Side-by-side dual-device browse  

## Handoff

- Architecture freeze/allow relative to this shell → [architecture-bounds.md](architecture-bounds.md) (ticket 08).  
- Motion for column/panel transitions → [motion-language.md](motion-language.md) (ticket 09).  
- Concrete look validation → wayfinder ticket 10 prototype.  
- Domain term **Shell** may be promoted into root `CONTEXT.md` when glossary is next updated.
