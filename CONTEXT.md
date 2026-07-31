# DroidMate 领域词汇

> Ubiquitous language for the DroidMate project. Architecture reviews and code
> should use these terms consistently.

## 设备交互

- **Device Session** — 一台已连接 Android 设备的 Mac 端会话。持有 Data Channel（连 DroidMate Server）与 feature bridges（files / clipboard / notifications）。每设备一个实例，由 `ConnectionManager` 持有池。
- **Mirroring** — 屏幕镜像 + 输入注入。由外部 **scrcpy** 进程承担（独立窗口），**不经** DroidMate 线缆协议。
- **Data Channel** — DroidMate 自研 TCP 协议（经 adb forward），承载 control（握手/ping）+ files + clipboard + notifications。与 scrcpy 通道并行。
- **DroidMateWire** — Foundation-only 共享库（`Sources/DroidMateWire`）：帧编解码与协议 DTO + adb 定位/启动（`AdbLocator` / `AdbRunner` / `PortForwarder` / `ServerLauncher`）。Mac App 与 MCP 共用；MCP 工具仍走 adb，不建 Data Channel 会话（ADR-0004）。
- **Transfer Engine** — 文件传输与（目标态）FS 变更的调度核心：协议编解码、pending、进度、历史。`FileClient` 负责导航与列表呈现，并编排 Transfer Engine。

## 传输与目录

- **DirEntry** — 一个目录项（文件或文件夹），含预格式化的 sizeText / dateText。
- **Completed Transfer** — 一次完成的批量传输摘要（名称/字节数/方向），用于状态栏一次性提示。
- **FS mutation** — 对设备文件系统的变更操作：delete / rename / mkdir / copy。经 Data Channel（Transfer Engine）；设备侧递归 delete/copy、`mkdir -p`、rename/move。

## Android 端（无 App）

> 不开发 Android 应用 / APK。产品只交付 Mac 软件。见 ADR-0003。

- **DroidMate Server** — Mac push 的 jar，经 `app_process` 启动（Shell UID 2000），监听 28042。处理 Data Channel：files / clipboard / notifications。不是可安装 App。
- **scrcpy server** — scrcpy 自带的设备端进程，处理 capture / encode / inject。

## adb 工具

- **AdbLocator** — 定位 adb 二进制（系统路径 + bundle 内拷贝）。
- **AdbBridge** — 通用 adb 命令 + 设备列举 + 设备信息（电量/存储/Wi-Fi）+ 无线连接辅助。
- **PortForwarder** — adb forward 端口转发。
- **ServerLauncher** — push server JAR + `app_process` 启动 DroidMate Server。
- **AdbAppManager** — adb 包管理（list / launch / force-stop / uninstall 等）。
