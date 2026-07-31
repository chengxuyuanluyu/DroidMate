# ADR-0001: scrcpy 接管投屏与输入

- **状态**: Accepted
- **日期**: 2026-07-30

## 背景

DroidMate 最初自研完整视频管线：Android MediaProjection + MediaCodec H.265 编码 → Mac VideoToolbox 解码 + Metal 渲染 + 自研输入注入（InputForwarder）。

实测在多款设备（尤其 HyperOS/MIUI）上 VirtualDisplay 黑屏、PNG fallback 仅 ~8fps、输入注入双路径（InputManager 反射 + adb shell）复杂且不稳定。

## 决策

投屏与输入改为由外部 [scrcpy](https://github.com/Genymobile/scrcpy) 二进制承担。Mac 端 `ScrcpyController` 启动 scrcpy 进程（独立 SDL 窗口），删除自研 `H265Decoder` / `MetalVideoView` / `FrameRenderer` / `InputForwarder`。

## 后果

- **正面**: 投屏延迟 <50ms（USB），流畅度由 scrcpy 成熟管线保证；Mac 端删除 ~680 行视频/输入代码；Swift 6 并发简化（`nonisolated(unsafe)` / `@unchecked Sendable` 全部消失）。
- **负面**: 依赖 scrcpy 二进制（现已 prefer bundle）；完整「⌘ 当作 Ctrl 键码注入」并非 scrcpy 原生能力。
- **键盘补回（2026-07-31）**: 默认 `--keyboard=sdk` + `--shortcut-mod lalt,lsuper`，使 Mac ⌘ 作为 scrcpy MOD，⌘C/⌘V/⌘X 走设备剪贴板快捷键；设置中可选 uhid / 关闭 ⌘-as-MOD。见 `ScrcpyController.keyboardArgs`。
- 设备上双 server 并存（scrcpy server + DroidMate server），见 ADR-0002。
