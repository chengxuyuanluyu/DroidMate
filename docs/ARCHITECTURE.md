# DroidMate 系统架构

> 与 [ADR-0001](adr/0001-scrcpy-mirroring.md)（scrcpy 投屏/输入）、[ADR-0002](adr/0002-protocol-scope.md)（Data Channel 范围）一致。  
> 领域词汇见根目录 [CONTEXT.md](../CONTEXT.md)。

## 拓扑

两条并行通道，互不混用：

```
┌─────────────────────────────┐              ┌──────────────────────────────┐
│           macOS             │   USB /      │           Android            │
│                             │ wireless adb │                              │
│  ┌───────────────────────┐  │              │  ┌────────────────────────┐  │
│  │    DroidMate.app      │  │              │  │  scrcpy server         │  │
│  │                       │  │   scrcpy     │  │  (capture / encode /   │  │
│  │  ScrcpyController ────┼──┼── process ───┼──┤   inject)              │  │
│  │       │               │  │   + SDL      │  └────────────────────────┘  │
│  │       ▼               │  │   window     │                              │
│  │  Mirroring UI panel   │  │              │  ┌────────────────────────┐  │
│  │                       │  │              │  │  DroidMate Server      │  │
│  │  ConnectionManager    │  │  Data Channel│  │  app_process, :28042   │  │
│  │    └─ Device Session ─┼──┼── TCP ───────┼──┤  control / files /     │  │
│  │         │             │  │  adb forward │  │  clipboard / notifs    │  │
│  │         ├─ Transport  │  │  127.0.0.1   │  └────────────────────────┘  │
│  │         ├─ Transfer   │  │              │                              │
│  │         │   Engine    │  │              │                              │
│  │         ├─ Clipboard  │  │              │                              │
│  │         └─ Notifs     │  │              │                              │
│  │  Files UI (SwiftUI)   │  │              │                              │
│  └───────────────────────┘  │              │                              │
└─────────────────────────────┘              └──────────────────────────────┘
```

| 通道 | 职责 | 实现 |
|------|------|------|
| **Mirroring** | 屏幕镜像 + 键鼠注入 | 外部 **scrcpy** 进程 + 设备端 scrcpy server |
| **Data Channel** | 握手/ping、文件 list/transfer、剪贴板、通知 | 自研帧协议，Mac `TransportClient` ↔ DroidMate Server |

无线场景当前走 **wireless adb**（`adb connect` / 配对）再 `adb forward`，不是协议层 mDNS 直连（直连属远期）。

## 模块职责

### Mac 端（Swift / SwiftUI）

| 模块 | 职责 |
|------|------|
| `App` | 入口、菜单栏、onboarding、诊断导出 |
| `Capture` | `ConnectionManager` 设备池、`DeviceSession`、`ScrcpyController`（启动/停止 scrcpy） |
| `Transport` | adb 定位/命令/端口转发/`ServerLauncher`、Data Channel `TransportClient` |
| `Files` | `FileClient`（导航与列表）、`TransferEngine`（传输与进度）、缩略图缓存 |
| `Clipboard` | NSPasteboard ↔ Data Channel |
| `Notifications` | Android 通知镜像（opt-in） |
| `Protocol` | 帧编解码与消息类型（与 Android / PROTOCOL.md 契约） |
| `UI` | 连接、文件浏览器、命令面板、设置、镜像控制面板等 |

### Android 端

| 组件 | 职责 |
|------|------|
| **DroidMate Server** | Shell UID `app_process` 进程，监听 `127.0.0.1:28042`；control + files + clipboard + notifications |
| **scrcpy server** | 由 scrcpy 客户端拉起；视频编码与输入注入（与 DroidMate Server 独立） |

> **产品与开发只面向 Mac 应用**（[ADR-0003](adr/0003-mac-only-product.md)）。用户不安装 Android APK；无 Android 客户端路线图。  
> DroidMate Server jar 由 Mac 在连接时 push 到 `/data/local/tmp/` 后 `app_process` 启动——这是**配套后端**，不是独立 App。

**Stage B（已完成）：** Server 内视频/输入死代码已删除；jar 与 ADR-0002 一致。

## 设备会话生命周期

1. `AdbBridge` 发现设备 serial（USB 或 `host:port` 无线）。
2. `PortForwarder` 建立 `tcp:28042`；`ServerLauncher` push/start DroidMate Server（若需要）。
3. `ConnectionManager` 创建 **Device Session**：绑定 `TransportClient` + File/Clipboard/Notification bridges。
4. HELLO → HELLO_ACK；session **ready** 后文件与剪贴板可用。
5. 用户可选启动 **Mirroring**（`ScrcpyController`），与 Data Channel 并行、互不依赖。
6. 传输失败时 soft reconnect → 必要时 hard recover（重 assert forward / 重启 server）。

## 线程与并发（Mac）

- 主线程：SwiftUI / `@MainActor` 模型（`FileClient`、`TransferEngine`、`DeviceSession` 等）。
- Data Channel IO：`NWConnection` 回调队列 + async send/receive loop。
- scrcpy：独立 OS 进程；不进入 DroidMate 协议线程。

## 安全

- Data Channel 默认只绑 `127.0.0.1`；隔离依赖 adb forward。
- 零云、无账号。
- 通知镜像默认 opt-in（敏感数据）。
- 远期：真 Wi-Fi 直连需配对码 + TLS（未实现）。

## 延迟预期

| 路径 | 预期（USB） |
|------|-------------|
| Mirroring 端到端 | scrcpy 成熟管线，目标 &lt;50–80ms 量级 |
| Data Channel ping RTT | 数 ms 级（本机 loopback + USB） |
| 文件 list / 小文件 | 受 USB 与 server 磁盘 IO 主导 |

## 与单独使用 scrcpy 的关系

- **DroidMate**：原生 Mac 文件 / 剪贴板 / 通知 / 多设备 / 命令面板，并捆绑 scrcpy 做镜像。
- **仅 scrcpy**：CLI + SDL 窗口，无本应用级文件浏览器与 Data Channel。

## 失败模式

| 失败 | 表现 | 处理 |
|------|------|------|
| USB / adb 断开 | Data Channel failed；镜像可能退出 | Device Session recovery；提示重插或无线重连 |
| DroidMate Server 崩溃 | 文件/剪贴板不可用；镜像可能仍在 | 重启 server + reconnect |
| scrcpy 缺失或启动失败 | 无法镜像 | 设置中提示 bundled/Homebrew 路径；文件功能仍可用 |
| 文件权限不足 | 操作失败 | Data Channel 错误码 / 文案；不拖垮会话 |
| 无线 adb 掉线 | serial 消失 | 重连 endpoint；必要时 USB 恢复 |

## 手动冒烟清单（发布门）

见 [SMOKE.md](SMOKE.md)。
