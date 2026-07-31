# DroidMate 工程计划

Mac 原生 Android 文件管理 + 投屏。MVP 优先级：投屏 + 文件传输。

## 开发范围

- **只开发 Mac 软件**（`mac/`）。产品形态 = 单一 macOS 应用。
- **不开发 Android App / APK。** 设备侧为 vendored `droidmate-server.jar`（`mac/Resources/`）+ 捆绑 scrcpy。
- 决策见 [ADR-0003](adr/0003-mac-only-product.md)。

## 产品目标（按重要性）

1. **精细 UX** — 命令面板、多设备、统计浮窗、快捷键映射、窗口管理
2. **低延迟投屏** — 依托 scrcpy 硬编硬解与成熟管线

## 里程碑

| 阶段 | 目标 | 工时估算 | 状态 |
|---|---|---|---|
| **M0** | 项目骨架 + 协议规范 + 双工程脚手架 | 0.5 天 | ✅ 完成 |
| **M1** | 线缆协议 E2E（adb forward + 握手 + ping） | 0.5 天 | ✅ 完成 |
| **M2** | 投屏（scrcpy 集成） | 2-3 天 | ✅ 完成 |
| **M3** | 输入注入（scrcpy SDL 原生处理） | 1-2 天 | ✅ 完成 |
| **M4** | 文件传输（双向 + 拖拽 + 断点续传） | 2-3 天 | ✅ 完成 |
| **M5** | UX 打磨（连接 UI + 命令面板 + 多设备 + 设置） | 3-5 天 | ✅ 完成 |
| **M6** | 剪贴板 + 通知同步 | 1-2 天 | ✅ 完成 |
| **M2′** | 架构收敛：移除自研视频管线（H265Decoder/MetalVideoView/InputForwarder），纯 scrcpy；CaptureEngine→DeviceSession | — | ✅ 完成 |
| **M7+** | 差异化超越：per-app windowing / Spotlight / Handoff / MCP | TBD | ⏳ 远期 |

**MVP 目标**：M0-M5 完成 = 可日常使用的投屏+输入+文件工具。约 2-3 周。

## 各阶段验证标准

### M0 - 项目骨架
- ✅ `mac/` 目录有可编译运行的工程（空窗口）
- ✅ `mac/Resources/droidmate-server.jar` vendored（连接时 push，非 APK）
- ✅ `docs/PROTOCOL.md` 完成线缆协议规范
- ✅ ADB 端口转发可工作：`adb forward tcp:28042 tcp:28042`

### M1 - 线缆协议
- ✅ Mac 端能通过 `localhost:28042` 连上 Android
- ✅ Android 端能接受连接并回应握手包
- ✅ 双向 `ping/pong` 往返延迟 <5ms

### M2 - 投屏（scrcpy）
- ✅ Mac 端 `ScrcpyController` 启动 scrcpy 二进制（独立 SDL 窗口）
- ✅ scrcpy 自带 capture → H.265 硬编 → 传输 → 硬解 → 渲染全链路
- ✅ 端到端延迟 <50ms（USB），流畅度由 scrcpy 成熟管线保证
- ✅ 自研 H265/Metal 管线已移除（见 M2′）

### M3 - 输入注入（scrcpy）
- ✅ scrcpy SDL 窗口原生处理鼠标 → 触摸、键盘 → keyevent、滚轮
- ✅ 自研 InputForwarder 已移除（scrcpy 覆盖）
- ⚠️ 已知损失：Mac 端 ⌘→Ctrl 键位重映射（copy/paste 肌肉记忆）随 InputForwarder 移除，后续可通过 scrcpy `--keyboard` 模式或 SDL 端宏补回

### M4 - 文件传输
- ✅ 列出 Android 目录（SAF + MediaStore）
- ✅ 上传/下载，带进度条
- ✅ 拖拽进/拖拽出
- ✅ 大文件分块传输 + 断点续传

### M5 - UX 打磨
- ✅ 连接窗口：自动发现已连接设备
- ✅ 实时统计浮窗：FPS / 延迟 / 码率 / CPU
- ✅ 多设备：同时连多台手机
- ✅ 设置面板：分辨率 / 码率 / 编码器选择
- ✅ 自适应码率（基于延迟动态调整）

## 技术决策

### 为什么是原生？

| 维度 | 原生 | Rust 核心 | Electron |
|---|---|---|---|
| 延迟下限 | 最低 | 最低 | 高 |
| UI 集成度（Finder/Spotlight/通知） | 完美 | 需要桥 | 受限 |
| 开发效率 | 中 | 低 | 高 |
| 维护成本 | 两套代码 | 中 | 一套 |

延迟是核心卖点，原生是唯一选择。

### 为什么 H.265 不是 AV1？

- Android 14+ 设备 H.265 硬编覆盖率 ~95%，AV1 ~30%
- Mac（Apple Silicon）H.265 硬解 100%
- Phase 2 可以加 AV1 选项（更新设备）

### 为什么协议是 TCP 而不是 UDP？

- MVP 先用 TCP，简单可靠
- USB 场景下 TCP 也足够低延迟（<10ms 单程）
- Phase 2 Wi-Fi 场景考虑 UDP + 自定义可靠性层（参考 scrcpy 的方案）

## 参考实现

- **scrcpy** (Genymobile) — 投屏与输入；本产品捆绑并集成。
- **sndcpy** — 配套音频转发（远期参考）。
- **gnirehtet** — Reverse tethering（远期参考）。
- **Apple Sidecar / Universal Control** — Mac 原生级 UX 参考。

## 已知风险

1. **scrcpy 依赖**：投屏与输入依赖 scrcpy（bundled 优先，否则 Homebrew/PATH）。启动失败时镜像不可用，文件 Data Channel 仍可独立工作。
2. **双 server 资源**：设备上同时跑 scrcpy server（视频+输入）和 DroidMate Server（Data Channel）。
3. **文件 FS 操作**：list/transfer/delete/rename/mkdir/**copy** 均走 Data Channel（粘贴复制不再依赖 adb shell）。
4. **Finder 集成**：需要 `NSFileProvider` 扩展，沙盒限制较多。MVP 先做应用内文件浏览器，Finder 集成放 Phase 2。
5. **macOS 新版本** 系统级权限变化频繁，需要持续跟进。
6. **⌘→Ctrl 键位重映射**：随 InputForwarder 移除，scrcpy 窗口内 Cmd+C/V 不再映射为 Ctrl+C/V。后续可通过 scrcpy keyboard 模式补回。

架构真源：[ARCHITECTURE.md](ARCHITECTURE.md)、[PROTOCOL.md](PROTOCOL.md)、[adr/](adr/)。手动冒烟：[SMOKE.md](SMOKE.md)。
