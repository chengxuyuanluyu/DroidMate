# Wi‑Fi Connection UX Redesign

**Date:** 2026-07-31  
**Status:** Approved for implementation  
**Product:** DroidMate (macOS)

## Problem

Wireless adb forces a two-port model (pair port ≠ connect port) and dynamic connect ports. The current connection pane shows USB switch, full pair+connect form, recent list, and explanatory copy on one screen. Daily reconnect pays the first-time cognitive cost every visit.

## Goals

| User state | Target experience |
|------------|-------------------|
| Previously paired, same LAN, wireless debugging on | ≤1 click: “My phones” → Connect → session |
| USB authorized | ≤1 click: “Switch to Wi‑Fi” → safe to unplug |
| Brand-new phone / Mac | Step wizard; never both ports on one screen |
| Failure | Actionable human copy + next step |

## Non-goals (this iteration)

- QR pairing (P2)
- Protocol-layer mDNS direct connect (still wireless adb + forward)
- Android companion app
- Changing left-hand adb device list semantics

## Information architecture

Remove the primary **USB | Wi‑Fi** segmented control as the main mental model for the method pane.

```
Enter connection workspace method pane
  ├─ USB ready present     → primary card: Switch to Wi‑Fi
  ├─ No USB, has targets   → primary card: My phones (connect)
  └─ Empty                 → primary card: Add phone (wizard entry)
                             + USB tip as secondary
```

“Targets” = wireless serials already in `adb devices`, plus Recent endpoints.

Secondary always available: **Add phone…** (wizard), and when USB exists, it does not hide “My phones” if wireless targets also exist—USB card stays primary.

## Paths

### A. Daily reconnect (“My phones”)

- Row: label (`host` · last port or full `host:port`), Wi‑Fi icon, **Connect**
- Prefer: serial already in `adb devices` → start DroidMate only
- Else: `adb connect` Recent endpoint
- Fail: actionable error + “Update address” / “Pair again”
- Never show pair port or 6-digit code on this surface

### B. USB → wireless

- Primary when any non-`host:port` ready USB serial exists
- Reuse `enableWirelessFromUSB` (read IP before tcpip)
- Success copy: on Wi‑Fi, safe to unplug; refresh list; prefer phones view

### C. Add phone (wizard)

| Step | Phone action | Mac UI only |
|------|--------------|-------------|
| 1 Prepare | Wireless debugging on, same Wi‑Fi | Checklist + Next |
| 2 Pair | Pairing sheet open | Pair address + 6-digit code + Pair |
| 3 Connect | Main wireless screen IP & port | Connect address only (host prefilled) + Connect & open |

- Smart paste: `IP:port` and 6-digit code from clipboard
- Host prefilled step 2→3; **connect port left empty** so user cannot reuse pair port by accident
- On success: remember endpoint, dismiss wizard, show My phones

## Error copy (product)

| Case | Message direction |
|------|-------------------|
| Pair failed | Keep pairing sheet open; code may expire; open sheet again |
| Connect failed / port changed | Use IP & port from main Wireless debugging screen (not pairing sheet) |
| No IP / wrong network | Same Wi‑Fi as Mac; try without VPN |
| USB cannot read IP | Phone Wi‑Fi on, or use Add phone |
| adb up, session failed | Retry open DroidMate |

## Phases

| Phase | Scope |
|-------|--------|
| **P0** | Context home, My phones, USB primary card, 3-step wizard, smart paste, error copy — **done** |
| **P1** | `adb mdns services` / `connectWifiResolving` to refresh connect port when Recent fails — **done** |
| **P2** | Optional QR pairing |

## Code boundaries

| Area | Change |
|------|--------|
| `ConnectionView` | Drive scene selection; drop mode segmented as primary IA |
| `ConnectionWifiForm` | Replace with scene views + wizard |
| `ConnectionWifiActions` | Clear pair-only / connect-only / USB flows; map errors to product strings |
| `AdbBridge` | P0: minimal; P1: mDNS helpers |

## Acceptance

1. With USB ready: first glance is Switch to Wi‑Fi, not pair form.
2. Without USB + Recent: first glance is My phones.
3. Pair port + code only inside wizard step 2.
4. Daily path never shows “pairing port” copy.
5. Wrong port on connect step points user to main-screen port.
