# Changelog

## Unreleased

### Wi‑Fi 连接 UX
- **P0 情境首页**：有 USB → 主推「切换到无线」；有 Recent/在线无线 →「我的手机」一点连接；否则「添加手机」
- **移除 USB | Wi‑Fi 分段**作为主信息架构
- **添加手机向导**三步（准备 → 配对 → 连接），双端口不再同屏
- 智能粘贴 `IP:port` / 6 位码；连接失败文案指向无线调试主界面端口
- **P1 mDNS**：Recent 端口失效时用 `adb mdns services`（`_adb-tls-connect`）自动刷新同 host 连接口
- **局域网发现**：连接页轮询 mDNS，在「我的手机」展示「On this Wi-Fi」可一点连接（优先于过期 Recent）

### 中英文 / i18n
- 源码统一 `Wi-Fi`（ASCII），避免与 `zh-Hans` 词条键不一致
- 连接/向导新文案补齐简体中文；向导步进改用 `onPairSucceeded` / `onSessionReady`，**不再依赖英文字符串判断**

### UX 流畅度专项 · Wave 1
- 列表/网格**选中高亮**可靠、同帧绘制（去掉清掉 List 选中底的 bug）
- 进文件夹不再整表半透明变暗；顶部轻量「打开中…」
- 传输进度去掉重复 `objectWillChange`（减 UI 双刷）
- 列表行 hover；选中无 spring 拖影
- 规格：`docs/superpowers/specs/2026-07-31-ux-fluency-initiative.md`

### Repo
- **Mac-only tree**：移除 `android/`、`archive/`；设备 Server jar 以 `mac/Resources/droidmate-server.jar` 形式 vendored
- **CI/CD**：GitHub Actions — `CI`（push/PR 测试）与 `Release`（`v*` tag / 手动发版打 DMG）

## 0.2.2 — 2026-07-31

### Fixes
- **启动闪退**：打包 App 不再访问 SPM `Bundle.module`（缺资源包时会 trap），改为安全的 `ResourceBundle`
- **状态栏退出卡死**：菜单嵌套 runloop 下 defer `terminate`，避免 `CFPasteboardResolveAllPromisedData` 挂起

### Wi‑Fi 配对 UX
- 字段顺序对齐手机：连接端口（主界面）在上，配对端口 + 码在下
- 文案强调「同 IP、两端口，勿混用」

### Packaging
- 默认发布版本 **0.2.2**；GitHub Releases 分发 DMG

## 0.2.1 — 2026-07-31

Ship polish for 0.2.x：画质预设、录屏计时、中文、What's New / onboarding 等。

## 0.2.0 — 2026-07-31

Cumulative product slice after foundation consolidation (Sprints G–U).

### Architecture
- **DroidMateWire** library: shared protocol codec + adb bootstrap (`AdbLocator` / `PortForwarder` / `ServerLauncher`); App + MCP depend on it.

### Protocol & files
- DIR_ENTRY top-level `exists` / `is_dir` (empty folder ≠ missing)
- Missing-path UX: error banner; restore last path falls back to `/`
- Empty folder upload (mkdir tree)
- Multi-select drag-out to Finder
- Conflict **Keep Both** (`name (1).ext`)
- Parallel multi-file upload
- **Duplicate** via FS_COPY (`name copy.ext`)

### Connection & mirror
- Wi‑Fi recent list: clear / remove endpoint
- Connection recovery banners; session restore polish

### UI structure
- FileBrowser: path bar, banners, toolbar, transfers, drop helpers extracted
- Sidebar: devices / locations / chrome modules
- Connection: Wi‑Fi form, device rows, wifi actions extracted

### Transfer queue
- Clear Completed vs Clear All; double-click reveal
- Status bar completion → Show in Finder

### MCP (v0.4.0, 20 tools)
- `launch_app` / `force_stop_app`
- `mkdir` / `delete_path` / `rename_path` (root-safe)
- `path_exists` / `device_info`
- `list_files` fails clearly when path missing / not a directory

### Packaging
- Default app version **0.2.0**
- Ad-hoc DMG; Developer ID path unchanged (see `mac/RELEASE.md`)

## 0.1.0

Initial ad-hoc shippable Mac app (scrcpy mirror + Data Channel files + MCP scaffold).
