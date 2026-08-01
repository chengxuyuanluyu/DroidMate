# Changelog

## Unreleased

- 上传在协议能绑定完整源 revision 前始终从头写入唯一 staging 文件；提交前重查本地文件身份，设备端核对最终字节数并原子替换且不会占用同名用户文件；Mac/Server 双端独占目标路径，取消会显式 `UPLOAD_ABORT` 并释放设备文件句柄；批量与目录上传锁定初始目标目录。
- ADB 连接、恢复与断开移出主线程并设置硬超时；重复传输失败不再重置硬恢复计时；下载取消保证 `START` / `CANCEL` 线序，设备端同时识别提前到达的取消。
- 退出屏障覆盖预会话 Wi‑Fi：`adb connect` 成功但 DeviceSession 尚未创建时，Quit / 取消连接会登记并清理 orphan 无线 adb 会话；录屏收尾后再断开连接。

## 0.2.5 — 2026-07-31

### UX
- 设置菜单恢复为系统单一入口；投屏输入选项与控制说明补齐简体中文
- **断开统一确认**：传输进行中时，连接页 / 侧栏 / ⌘D / 菜单栏 / 命令面板均先确认再断；双链路 USB+Wi‑Fi 一并断开
- **Retry 真重试**：连接失败后 Retry 重跑上次 serial，而不仅刷新列表
- **Auto-connect 偏好**：优先上次设备 → USB → 无线
- **设备友好名 + 合并**：`ro.product.model` 展示；USB 与同 IP 无线合并为一行
- **My phones 去重**：已在线无线只在左侧 Devices；右栏仅 Recent / mDNS
- **空网扫描**：mDNS 扫完后改为明确「未发现」文案，不再无限转圈
- **连接阶段文案**：推送服务 → 打开通道 → 握手；连接中断开会取消 in-flight 会话
- **传输完成态** 延长至 3.5s；菜单栏增加传输 / 断开 / 开始镜像
- **预览缓存身份** 纳入完整远端路径与文件元数据，跨目录同名同大小文件不再串预览

### Privacy & reliability
- MCP 文件路径在校验与执行前统一规范化；删除与重命名仅允许共享存储和 `/data/local/tmp` 子路径，并在设备端解析真实路径以阻止符号链接越界
- 下载数据校验 offset / length 与本地写入结果；Mac 与设备服务共同验证远端版本、续传目标独占且有无活动超时，完成文件原子替换且提交失败不删除原文件
- Data Channel 握手校验协议版本与 `files` 能力；业务帧只在 ready 后收发，发送失败、等待、超时和服务端断开均进入可恢复失败状态
- 用户取消下载会同步停止设备端读取且不会被自动重试；剪贴板仅在发送成功后进入去重状态
- 剪贴板双向同步改为默认关闭；剪贴板与通知日志不再记录正文、标题或通知键
- 文件请求先登记回包等待器再发送；断线立即结束等待并保留可续传分片
- Transport 拒绝超大协议帧，上传发送失败与 ACK 超时会正确收尾

### Packaging
- 默认发布版本 **0.2.5**
- 发布校验从实际 App 读取版本号，不再查找过期的 0.2.1 DMG
- 内置设备服务升级到 Data Channel 协议 v1，下载流前后验证源文件版本
- DMG Python 依赖改用隔离环境，兼容 GitHub macOS runner 的 PEP 668
- 打包移除会在无界面 CI 卡死的 Finder AppleScript；签名、镜像校验不再吞错

## 0.2.4 — 2026-07-31

### Fixes
- **退出卡死（全路径）**：⌘Q / Dock / AEQuit 与菜单栏退出统一在 `applicationShouldTerminate` 取消进行中的拖拽文件 promise，并清空 drag pasteboard，避免 `CFPasteboardResolveAllPromisedData` 嵌套 runloop 导致 Spinning Wait
- **Wi‑Fi 无法断开**：断开时 `adb disconnect` + 按主机抑制 auto-connect；transport 取消后不再自动 soft-reconnect；进行中的 recover 在用户断开后立即退出

### Packaging
- 默认发布版本 **0.2.4**

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
