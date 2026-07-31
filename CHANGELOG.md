# Changelog

## Unreleased

## 0.2.3 — 2026-07-31

### Wi‑Fi 连接 UX
- **情境首页**：有 USB → 主推「切换到无线」；有 Recent/在线无线 →「我的手机」一点连接；否则「添加手机」
- 移除 USB | Wi‑Fi 分段作为主信息架构
- **添加手机向导**三步（准备 → 配对 → 连接），双端口不再同屏
- 智能粘贴 `IP:port` / 6 位码；连接失败文案指向无线调试主界面端口
- **mDNS**：端口失效时自动刷新；连接页展示「本网发现」一点连接

### UX 流畅度
- 列表/网格选中高亮可靠；**统一淡蓝圆角**选中样式（去掉系统实心蓝）
- 进文件夹不再整表半透明；字母跳转；传输进度更稳
- 详见 `docs/superpowers/specs/2026-07-31-ux-fluency-initiative.md`

### 中英文
- 欢迎页/连接/错误文案补齐简体中文；`Wi-Fi` 词条键统一

### Packaging
- 默认发布版本 **0.2.3**

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
