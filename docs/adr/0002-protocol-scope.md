# ADR-0002: 自研协议范围收窄到 files/clipboard/notifications

- **状态**: Accepted
- **日期**: 2026-07-30

## 背景

scrcpy 接管视频与输入后（见 ADR-0001），原 DroidMate 协议的视频（VIDEO_START/FRAME/STOP）和输入（TOUCH/KEY/SCROLL）流不再使用。`Protocol.swift` 与 `TransportClient` 仍保留这些定义与 handler，造成「定义了但永不触发」的死接口。

## 决策

自研协议范围收窄到 **control（握手/ping）+ files + clipboard + notifications**。删除视频与输入的 `MsgType` / `StreamId` / DTO。`TransportClient` 删除 `setVideoHandler` / `setInputHandler` 及对应 dispatch 分支。HELLO capabilities 从 `["h265","input","files"]` 改为 `["files"]`。

## 后果

- **正面**: 协议边界清晰——DroidMate 协议只承载 scrcpy 不做的事；`TransportClient` 接口最小化；Mac 端死接口清除。
- **文件操作**: list/download/upload/delete/rename/mkdir/copy 经 Data Channel。MCP 工具走 adb shell/pull/push，与 GUI Data Channel 独立。
- Android `ServerMain` 的视频编码代码（H265Capture/ScreenCapture）已在 **Stage B（2026-07-31）** 删除；HELLO capabilities 仅为 `files` / `clipboard` / `notifications`。
- **文档**: 2026-07-31 起 `docs/ARCHITECTURE.md` / `docs/PROTOCOL.md` 与本 ADR 对齐；退役视频/输入类型见 PROTOCOL 附录 A。
