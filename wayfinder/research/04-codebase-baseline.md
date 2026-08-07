# 04 — Codebase baseline (Mac client 0.2.6)

**Ticket:** [`wayfinder/tickets/04-codebase-baseline-research.md`](../tickets/04-codebase-baseline-research.md)  
**Baseline product:** shipped **0.2.6** (see `CHANGELOG.md`, `mac/scripts/build-dmg.sh` `VERSION` default)  
**Sources:** in-repo code under `mac/`, `CONTEXT.md`, `docs/ARCHITECTURE.md`, ADRs 0001–0004, UX fluency spec, tests. No product decisions invented here.

---

## 1. Module map

### SPM products & targets

From `mac/Package.swift`:

| Product / target | Path | Role |
|------------------|------|------|
| **DroidMateWire** (library) | `Sources/DroidMateWire` | Foundation-only: frame protocol DTOs + adb bootstrap (`AdbLocator`, `AdbRunner`, `PortForwarder`, `ServerLauncher`) |
| **DroidMate** (executable) | `Sources/DroidMate` | Mac app; depends on Wire; resources: `Resources` + copied `Bin/` |
| **DroidMateMCP** (executable) | `Sources/DroidMateMCP` | Agent MCP server; depends on Wire + MCP SDK — **not** the app target |
| **DroidMateTests** | `Tests/DroidMateTests` | App + Wire unit tests (`@testable import DroidMate`) |
| **DroidMateMCPTests** / **DroidMateWireTests** | respective paths | Path safety; wire frame tests |

Platform gate: **macOS 15+** (`platforms: [.macOS(.v15)]`).  
App re-exports Wire via `mac/Sources/DroidMate/WireReexport.swift` (`@_exported import DroidMateWire`) so app/tests keep a single import surface.

Domain terms for ownership: root `CONTEXT.md` (Device Session, Transfer Engine, DroidMateWire, Adb*). Topology: `docs/ARCHITECTURE.md`.

### Logical modules inside the app

Matches `docs/ARCHITECTURE.md` §模块职责, grounded in tree under `mac/Sources/DroidMate/`:

| Module | Key types (file:symbol) | Owns |
|--------|-------------------------|------|
| **App** | `DroidMateApp` (`App/DroidMateApp.swift`), `AppDelegate`, `MenuBarController`, `ResourceBundle`, `DiagnosticsExporter` | Entry, menus, terminate barrier, packaging-safe resources |
| **Capture** | `ConnectionManager`, `DeviceSession`, `ScrcpyController` | Device pool, per-device session lifecycle, scrcpy process control |
| **Transport** | `TransportClient`, `AdbBridge`, `AdbAppManager` | Data Channel TCP; adb shell UX helpers (battery/storage/Wi‑Fi) |
| **Files** | `FileClient`, `TransferEngine`, `ThumbnailCache`, `NameConflict`, `TransferHistoryStore` | Nav/list, transfers, FS ops, thumbs, history |
| **Clipboard / Notifications** | `ClipboardBridge`, `NotificationBridge`, `TransferNotificationCenter` | Feature bridges on Data Channel; local UN notifications |
| **UI** | ~38 SwiftUI files under `UI/` (`FileBrowserView`, `ConnectionView`, `DesignSystem`/`DM`, …) | Shell chrome, connection workspace, browser |
| **Wire** (shared) | `Protocol`, `AdbLocator`/`AdbRunner`/`PortForwarder`/`ServerLauncher` | Shared by app + MCP |
| **MCP** (separate binary) | `DroidMateMCPServer` | adb tools only — **no Data Channel** (ADR-0004) |

### Composition graph (runtime)

```
DroidMateApp
  ├─ ConnectionManager  (@StateObject)
  │    └─ engines: [DeviceSession]
  │         ├─ transport: TransportClient
  │         ├─ files: FileClient
  │         │    └─ transferEngine: TransferEngine  ──bind──► TransportClient
  │         ├─ clipboard: ClipboardBridge           ──bind──► TransportClient
  │         └─ notifications: NotificationBridge    ──bind──► TransportClient
  ├─ ScrcpyController   (@StateObject)  ──process──► scrcpy (+ adb for args)
  └─ MenuBarController
RootView
  ├─ ConnectionView(connMgr)            when no session
  └─ FileBrowserView(connMgr, engine, client, scrcpy)  when activeEngine ≠ nil
```

`DeviceSession.start` (`Capture/DeviceSession.swift:66`) wires handlers, binds files/clipboard/notifications, and mirrors `TransportClient` `@Published` state into the session.

### Thickest coupling edges

Ordered by redesign risk (UI/shell work will trip these first):

1. **UI ⟷ FileClient ⟷ TransferEngine ⟷ TransportClient**  
   - `FileClient.bind` → `TransferEngine.bind` (`Files/FileClient.swift:131`, `TransferEngine.bind`).  
   - Directory list and all FS/transfer ops go through TransferEngine on the same socket.  
   - Browser views take `FileClient` as `@ObservedObject`; status/queue also take `TransferEngine`.

2. **FileBrowserView observation fan-in**  
   - `FileBrowserView` observes **four** objects: `connMgr`, `engine`, `client`, `scrcpy` (`UI/FileBrowserView.swift:8–12`).  
   - Child chrome (sidebar, toolbar, banners, path bar, list/grid) re-observes overlapping subsets.  
   - Any shell rewrite that keeps this fan-in inherits full re-render risk.

3. **ConnectionManager ⟷ DeviceSession ⟷ adb Wire stack**  
   - Connect / recover / disconnect: `ConnectionManager.performRecovery` shells via `AdbBridge` + `ServerLauncher` (`Capture/ConnectionManager.swift:259+`).  
   - Soft reconnect is socket-only (`reconnect` → `TransportClient.reconnect`); hard recover reasserts wireless adb + jar + forward.

4. **ThumbnailCache ⟷ FileClient/TransferEngine (shared pipe)**  
   - Thumbs call `client.downloadBackground` → `TransferEngine.download(..., background: true)` (`Files/ThumbnailCache.swift:159`, `FileClient.downloadBackground`).  
   - Same Data Channel and pending-download maps as user transfers; isolation is **logical** (background flag), not a second transport.

5. **ScrcpyController ⟷ UI (state) / OS process (I/O)**  
   - Loose process boundary (ADR-0001); thick **state** coupling via many `@Published` sets and mirror panel polling. Mirror window is **external SDL**, not SwiftUI content.

6. **MCP ⟂ App** (intentionally thin)  
   - Shares Wire adb helpers only; no `DeviceSession` / `TransferEngine` (ADR-0004). Shell overhaul does not touch MCP unless packaging layout changes shared binaries.

---

## 2. MainActor / observation surface

### Rule from architecture

`docs/ARCHITECTURE.md` §线程与并发:

- Main thread: SwiftUI / `@MainActor` models (`FileClient`, `TransferEngine`, `DeviceSession`, …).
- Data Channel I/O: `NWConnection` callback queues + async send/receive.
- scrcpy: separate OS process.

### `@MainActor` + `ObservableObject` publishers (inventory)

| Type | File | High-churn `@Published` / notes |
|------|------|----------------------------------|
| **TransferEngine** | `Files/TransferEngine.swift` | `transfers`, `transferBytesDone/Total`, `transferSpeedMBps`, `isTransferring`, `lastCompletedTransfer`, `transferHistory` |
| **FileClient** | `Files/FileClient.swift` | `entries` → `visibleEntries`, `currentPath`, `isLoading`/`isNavigating`, sort/filter/search, `isTransferring` (coarse), clipboard |
| **TransportClient** | `Transport/TransportClient.swift` | `connectionState`, `lastHelloAck`, `roundTripNs` (ping) |
| **DeviceSession** | `Capture/DeviceSession.swift` | mirrors transport + `recoveryPhase`, `rttMs`, `ack` |
| **ConnectionManager** | `Capture/ConnectionManager.swift` | `engines`, `activeDeviceId`, `pendingDisconnectSerials` |
| **ScrcpyController** | `Capture/ScrcpyController.swift` | `runningSerials`, `launchingSerials`, recording maps, path/availability |
| **ConnectionWifiState** | `UI/ConnectionWifiActions.swift` | wizard/busy/status (connection workspace only) |
| **MirrorControlPanel** | `UI/MirrorControlPanel.swift` | follow/record elapsed (floating panel) |
| **PreviewController** | `UI/PreviewController.swift` | preparing preview download |
| **MenuBarController** | `App/MenuBarController.swift` | status item rebuild triggers |
| Clipboard/Notification bridges | respective | lower frequency; clipboard outbound debounced 200ms |

App-level ownership (`App/DroidMateApp.swift:9–11`): `@StateObject` for `ConnectionManager`, `MenuBarController`, `ScrcpyController`.

### Highest-churn paths

1. **Transfer progress** — every download/upload chunk can call `recomputeProgress` (`TransferEngine.recomputeProgress`, ~L1134).  
2. **Directory listing** — `entries` assignment → `recomputeVisible` → list/grid identity refresh.  
3. **Connection / recovery** — transport state machine + recovery banners (`DeviceSession.scheduleRecovery`, soft fail every ~800ms noted in comments).  
4. **Thumbnails** — grid/inspector async image arrival (local `@State` in tiles, not global `ObservableObject`, but still MainActor work + transport contention).  
5. **RTT / mirror sets** — ping-driven `roundTripNs` and scrcpy serial-set churn.

### Thrash mitigations already shipped (0.2.x UX fluency)

Documented in `docs/superpowers/specs/2026-07-31-ux-fluency-initiative.md` and present in code:

| Mitigation | Evidence |
|------------|----------|
| **Do not forward TransferEngine → FileClient objectWillChange** | `FileClient.init` comment: progress must not rebuild FileBrowser/List (`Files/FileClient.swift:101–107`); only `isTransferring` is forwarded |
| **~15 Hz progress publish + 0.5% delta** | `recomputeProgress`: `stale >= 1/15`, `abs(p - last) >= 0.005` (`TransferEngine.swift:1165–1174`) |
| **Separate observation of transfers** | `StatusBarView` + `TransferQueueView` take `@ObservedObject transfers: TransferEngine` explicitly so ticks skip the file list |
| **Background transfers excluded from UI progress** | `background` flag; filtered from counts, queue, dock badge, completion (`TransferEngine.activeTransferCount`, `recomputeProgress`) |
| **Nav: keep prior listing + chip only** | `performList` keeps entries; `isNavigating` overlay “Opening…” — no full-list dim (`FileClient.performList`, `FileBrowserView` contentColumn) |
| **Search / filter debounce** | search 200ms, filter 100ms (`FileClient` didSets) |
| **Large-folder async sort** | `<256` sync; else off-main `computeVisible` with generation guard |
| **Large-folder skip remote thumbs** | `ThumbnailCache.getThumbnail` no-fetch when `entries.count >= largeFolderThreshold` (1500) unfiltered |
| **Thumb concurrency + yield to foreground** | max 1–2 concurrent; wait while `hasForegroundTransfer`; `cancelInflight` on path change |
| **Fixed-width status slots** | `%` / speed / ETA fixed frames (`StatusBarView.transferIndicator`) |
| **Progress bar un-springed** | `.animation(nil, value: transfers.transferProgress)` |
| **Reduce Motion** | many UI chrome animations gated on `accessibilityReduceMotion` |
| **Selection / list chrome** | list not `Color.clear` row bg; grid Button selection; type-ahead unit-tested |

**Implication for 3.0 shell work:** observation isolation around `TransferEngine` is a **shipped invariant**, not optional polish. A new shell that re-binds the whole tree to one mega-`ObservableObject` or re-forwards transfer progress would regress 0.2.x fluency.

---

## 3. I/O and process boundaries

### Data Channel — `TransportClient`

- **Where:** `mac/Sources/DroidMate/Transport/TransportClient.swift`  
- **What:** One `NWConnection` to `127.0.0.1:localPort` (forwarded to device `:28042`). Framed protocol; handlers for control / files / clipboard / notifications.  
- **Lifecycle:** connect → handshaking (HELLO) → ready; soft reconnect on failure; intentional `disconnect` cancels without auto-reconnect fighting the user.  
- **Thread bridge:** NW callbacks → `DispatchQueue.main` / `MainActor.assumeIsolated` for state; async read loop for frames.  
- **Cost / failure:** USB/adb drop → failed state; server crash → files/clipboard down while mirror may live (`docs/ARCHITECTURE.md` failure table). Handshake/send timeouts configurable (defaults 5s / 10s).  
- **Constraint:** Single client session model today; MCP deliberately does not share this pipe (ADR-0004).

### adb — `AdbBridge` / Wire runners

- **App-facing:** `Transport/AdbBridge.swift` — list devices, battery/storage, Wi‑Fi connect/pair helpers; uses `AdbLocator` + `AdbRunner` from Wire.  
- **Bootstrap:** `ServerLauncher` push jar + `app_process`; `PortForwarder` for local port → 28042.  
- **MCP:** own `AdbSupport` + same Wire locator/runner; path safety in MCP only.  
- **Cost / failure:** process spawn + timeouts (e.g. list devices 5s); hard recovery serializes adb off UI via `ConnectionManager.runAdbOperation`. Model/battery caches avoid shell-on-main for sidebar grouping.  
- **Product constraint:** wireless is **wireless adb**, not mDNS protocol direct connect (`docs/ARCHITECTURE.md`).

### scrcpy — `ScrcpyController`

- **Where:** `Capture/ScrcpyController.swift`  
- **What:** Locates bundled or Homebrew scrcpy; spawns process with keyboard args; tracks PIDs, recording, launch errors.  
- **Boundary:** Independent of Data Channel (ADR-0001, ARCHITECTURE topology).  
- **UI surface:** `MirrorControlPanel` (floating, ~12 Hz snap while following), toolbar/sidebar start-stop, menu bar.  
- **Failure:** missing binary → mirror unavailable; files still work.  
- **3.0 fog note (not a decision):** embedded mirror would reopen ADR-0001; baseline is external SDL window.

### Thumbnail pipeline

```
FileGridTile / FileInspectorView
  → ThumbnailCache.getThumbnail(entry, client)
      → cache hit (thumb JPEG / original) → ThumbnailLoader (ImageIO ≤512px, video 1s, PDF page)
      → else acquireThumbnailSlot (yield if foreground transfer)
      → client.downloadBackground → TransferEngine.download(background: true)
      → decode + persist thumb (+ 24h original, 7d thumb TTL, ~200MB cap)
```

- **Where:** `Files/ThumbnailCache.swift`, `UI/FileIconStyle.swift` (`ThumbnailLoader`)  
- **Cost:** competes for Data Channel bandwidth and TransferEngine pending maps; mitigated by concurrency cap, foreground yield, large-folder skip, cancel-on-navigate.  
- **Not a separate process** — pure in-app + same TCP session.

### Secondary I/O

| Path | Notes |
|------|--------|
| Preview | `PreviewController` downloads via FileClient then Quick Look |
| Drag-out | temp under `NSTemporaryDirectory()/DroidMateDrag`; terminate path cancels promises (`AppDelegate` / tests) |
| Transfer history | `TransferHistoryStore` per-serial disk files |
| Notifications | `TransferNotificationCenter` only when real `.app` bundle |

---

## 4. Test & packaging constraints

### Tests — what they protect today

**DroidMateTests** (21 files under `mac/Tests/DroidMateTests/`):

| Cluster | Files (examples) | Protects |
|---------|------------------|----------|
| Transfer / FS protocol | `TransferEngineDownloadTests`, `TransferEngineFSTests`, `TransferSchedulingTests`, `TransferHistory*` | download resume, FS ops, concurrency, history persistence, cancel vs fail |
| Paths / listing | `FileClientPathTests`, `DirListResultTests`, `NameConflictTests` | path normalize, list results, conflicts |
| Session / connection | `DeviceSessionRecoveryTests`, `ConnectionUXTests`, `WifiPasteTests`, `AppTerminationCoordinatorTests` | recovery, Wi‑Fi paste/UX helpers, quit barrier |
| Transport / protocol | `ProtocolXCTests`, `TCPSyncTests`, `SmokeTests` | wire framing / smoke |
| adb / scrcpy helpers | `AdbRunnerTests`, `AdbAppManagerTests`, `ScrcpyKeyboardArgsTests`, `ScrcpyRecordingTimerTests` | pure logic around process args/timers |
| UI-adjacent pure | `TypeaheadJumpTests`, `ThumbnailLoaderTests` | type-ahead algorithm; ImageIO path (not full SwiftUI) |

**Not covered (relevant to shell overhaul):** no SwiftUI snapshot/UI tests; no Instruments budgets in CI (UX spec marks 2k-folder Instruments as optional local QA); layout/chrome of `NavigationSplitView` is unprotected.

**MCP / Wire:** `PathSafetyTests`, `WireFrameTests` — keep agent path rules and frame codec stable.

### Packaging / bundle assumptions a shell rewrite must not break

From `mac/scripts/build-dmg.sh`, `App/ResourceBundle.swift`, `Package.swift`, ADR-0003:

1. **Default version string 0.2.6** in `build-dmg.sh`; product is `DroidMate.app` + `DroidMate-<version>.dmg`.  
2. **Vendored** `mac/Resources/droidmate-server.jar` is **required** at package time (script exits if missing).  
3. **Binaries** under `Sources/DroidMate/Bin/` (`adb`, `scrcpy`, `scrcpy-server`) copied into `Contents/Resources/Bin/`.  
4. **SPM resource flattening:** packaged app does **not** ship nested `DroidMate_DroidMate.bundle` the same way `swift run` does. **`Bundle.module` fatalErrors** if used at launch in DMG layout — all resource lookup must go through `ResourceBundle` (`App/ResourceBundle.swift` header comment).  
5. **Localizations:** `zh-Hans.lproj` (and empty en placeholder) copied into Resources.  
6. **Brand icon** preferred from `Sources/DroidMate/Resources/Brand/AppIcon.png`; `AppIcon.handleCLIIfNeeded` used by packaging.  
7. **Codesign / notarize** path documented in `mac/RELEASE.md` / `scripts/notarize.sh` — shell work does not change this, but any new resource must survive strip + ad-hoc/Developer ID signing.  
8. **MCP is a separate product binary** — not inside the `.app` by default packaging steps shown; app-only DMG remains the user deliverable (ADR-0003).  
9. **Entitlements:** `mac/entitlements.plist` present for hardened runtime expectations.

### Design token surface today

`UI/DesignSystem.swift` — `DM.Space`, `DM.Radius`, `DM.Brand`, `DM.Chrome` (path bar 40 / status 28 / sidebar row min 28). Shell redesign can evolve tokens, but many views hard-reference `DM.*` and AppKit system materials.

### Shell topology today (factual)

- Single `WindowGroup` default **900×600**, unified toolbar (`DroidMateApp`).  
- `RootView`: splash / onboarding / whats-new overlays; **session pool non-empty ⇒ FileBrowser**, else **ConnectionView**.  
- Connected: `NavigationSplitView` sidebar | content | inspector (`FileBrowserView`).  
- Device switch: `.id(engine.deviceSerial)` forces view identity reset (and `.task(id:)` re-lists).

---

## 5. Top 5 risks for a visual / shell overhaul

1. **Observation fan-out reintroduces 15 Hz full-tree thrash**  
   `FileBrowserView` already observes four models; progress isolation depends on **not** folding `TransferEngine` updates into `FileClient`/split-view parents. A “cleaner” single store or environment object that republishes transfer ticks will regress status-bar and list fluency (Wave 1–3 of UX fluency).

2. **MainActor density + shared Data Channel under load**  
   Listing, transfers, thumbs, clipboard, recovery UI all hop to `@MainActor`. Shell animations that bind to high-churn publishers (path, selection, recovery, RTT) without the existing debounce/generation guards will drop frames on large folders (≥1500 entries special-cased today).

3. **Thumbnail and user transfers share one TransportClient**  
   Visual work that makes grid thumbnails more aggressive (larger cells, auto-prefetch, multi-column density) stresses the same TCP session and pending-download machinery. Existing caps (2 concurrent, yield to foreground, cancel on navigate, large-folder skip) are load-bearing; removing them for “prettier grids” risks transfer latency and progress UI correctness.

4. **Packaging / `ResourceBundle` / Bin / jar contract**  
   New assets, fonts, or SPM resource layouts that call `Bundle.module` or assume dev-layout paths **crash packaged apps**. Mirror/adb still require `Contents/Resources/Bin/*` and vendored jar. Shell-only PRs that “just add assets” can break DMG smoke without failing unit tests.

5. **Session / disconnect / multi-device lifecycle woven into chrome**  
   Sidebar devices, pending-disconnect confirmations, recovery banners (`FileBrowserSessionBanner`), menu bar, command palette, and `RootView` connection-vs-browser switch are one system. A shell IA change (tabs, multi-window, different sidebar) that severs `ConnectionManager`/`DeviceSession` wiring will break: auto-list on ready, transfer-safe disconnect, recovery copy, and `.id(serial)` listing. Tests cover recovery/termination helpers more than chrome composition — regressions would be manual-smoke-first.

**Honorable mentions (not top 5):** external scrcpy window vs any “embedded mirror” ambition (ADR-0001); MCP path safety remains separate; protocol continuity preference is a map-level charting decision, not a baseline fact to change here.

---

## Citation index (quick)

| Concern | Primary path |
|---------|----------------|
| Topology / dual channel | `docs/ARCHITECTURE.md` |
| Domain language | `CONTEXT.md` |
| scrcpy boundary | `docs/adr/0001-scrcpy-mirroring.md` |
| Protocol scope | `docs/adr/0002-protocol-scope.md` |
| Mac-only + vendored jar | `docs/adr/0003-mac-only-product.md` |
| MCP ≠ Data Channel | `docs/adr/0004-mcp-uses-adb-not-data-channel.md` |
| Fluency mitigations | `docs/superpowers/specs/2026-07-31-ux-fluency-initiative.md` |
| Session composition | `Capture/DeviceSession.swift` |
| Pool / recover | `Capture/ConnectionManager.swift` |
| Progress rate limit | `Files/TransferEngine.swift` `recomputeProgress` |
| List / transfer isolation | `Files/FileClient.swift` |
| Thumbs | `Files/ThumbnailCache.swift` |
| Transport | `Transport/TransportClient.swift` |
| Shell entry | `App/DroidMateApp.swift`, `UI/FileBrowserView.swift` |
| Bundle safety | `App/ResourceBundle.swift` |
| DMG | `mac/scripts/build-dmg.sh` |
| SPM | `mac/Package.swift` |
| Version baseline | `CHANGELOG.md` `## 0.2.6` |

---

## Unblocks

- **07 performance budgets** — use §2 thrash rates and §3 I/O costs as evidence floors.  
- **08 architecture evolution bounds** — use §1 coupling + ADR constraints; prefer continuous Data Channel/session shape unless an explicit ticket reopens wire multi-client.
