<p align="center">
  <img src="docs/assets/app-icon.png" width="96" height="96" alt="DroidMate" />
</p>

<h1 align="center">DroidMate</h1>

<p align="center">
  <strong>Your phone. On your Mac.</strong><br/>
  原生 SwiftUI · 文件管理 + 投屏 · USB / Wi‑Fi · 手机零安装 · MIT
</p>

<p align="center">
  <a href="https://github.com/chengxuyuanluyu/DroidMate/releases/latest"><img src="https://img.shields.io/github/v/release/chengxuyuanluyu/DroidMate?style=flat-square&label=Release&color=0A84FF" alt="Release" /></a>
  <a href="https://github.com/chengxuyuanluyu/DroidMate/releases"><img src="https://img.shields.io/github/downloads/chengxuyuanluyu/DroidMate/total?style=flat-square&label=Downloads&color=34C759" alt="Downloads" /></a>
  <a href="https://github.com/chengxuyuanluyu/DroidMate/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/chengxuyuanluyu/DroidMate/ci.yml?branch=main&style=flat-square&label=CI" alt="CI" /></a>
  <img src="https://img.shields.io/badge/macOS-15%2B%20Apple%20Silicon-black?style=flat-square" alt="macOS 15+" />
  <img src="https://img.shields.io/badge/Android-11%2B%20wireless-3DDC84?style=flat-square" alt="Android" />
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=flat-square" alt="MIT" />
</p>

<p align="center">
  <a href="https://github.com/chengxuyuanluyu/DroidMate/releases/latest"><b>⬇ 下载 DMG</b></a>
  &nbsp;·&nbsp;
  <a href="#快速开始">快速开始</a>
  &nbsp;·&nbsp;
  <a href="#功能">功能</a>
  &nbsp;·&nbsp;
  <a href="#开发">开发</a>
  &nbsp;·&nbsp;
  <a href="CHANGELOG.md">更新日志</a>
</p>

<p align="center">
  <img src="docs/assets/promo-wide.png" width="100%" alt="DroidMate — Your phone. On your Mac." />
</p>

<p align="center">
  <img src="docs/assets/screenshot-app.png" width="100%" alt="DroidMate 主界面：侧栏设备、文件浏览与检查器" />
</p>

---

## 为什么选 DroidMate

| | |
|---|---|
| **手机零安装** | 打开 USB 调试即可；服务端 jar 由 Mac 自动推送，**不用装任何第三方 App** |
| **文件 + 投屏一体** | Finder 级浏览 / 传输，捆绑 scrcpy 镜像与薄控制条 |
| **USB 与 Wi‑Fi** | 线连最稳；Android 11+ 无线调试配对后可无线用 |
| **本地直连** | 无云、无账号；数据只在你的 Mac 和手机之间 |
| **原生体验** | SwiftUI · 系统外观 · 键盘优先 · 命令面板 ⌘K |
| **开源可审计** | MIT；协议、ADR、构建脚本都在仓库里 |

---

## 快速开始

### 1. 安装

1. 打开 **[Releases · 最新版](https://github.com/chengxuyuanluyu/DroidMate/releases/latest)**，下载 `DroidMate-x.y.z.dmg`
2. 将 **DroidMate** 拖进「应用程序」
3. **第一次启动**：在 App 上 **右键 → 打开**（ad-hoc / 未公证包需确认一次）
4. 手机开启 **开发者选项 → USB 调试**，插线；或按应用内引导做 **无线调试** 配对

> scrcpy 与 adb **已打进安装包**，一般不必再装 Homebrew 版。

### 2. 系统要求

| | |
|---|---|
| **Mac** | Apple Silicon · macOS 15+ |
| **手机** | USB 调试；无线需 Android 11+ 无线调试 |

### 3. 常用快捷键

| 快捷键 | 作用 |
|--------|------|
| **⌘K** | 命令面板（连接 / 浏览 / 传输 / 镜像） |
| **⌘J** | 传输队列 |
| **⌥⌘I** | 显示 / 隐藏检查器 |
| **⌘1 / ⌘2** | 列表 / 网格 |
| **⌘D** | 断开设备（传输中会确认） |

---

## 功能

### 文件

- 列表 / 网格、多选、type-ahead 跳转、拖拽进出 Finder  
- 上传 / 下载、冲突处理（替换 / 两份都保留）、断点续传  
- **传输一等入口**：工具栏徽章 · 状态栏队列 · 失败项「需要处理」  

### 投屏

- 捆绑 scrcpy（独立窗口）；画质预设、录屏、导航键  
- 浮层薄控制条（返回 / 主屏 / 截图 / 录制）  
- 可选 Wi‑Fi 软限速  

### 连接与多设备

- USB 自动发现；无线配对向导 + mDNS 本网发现  
- 侧栏多设备切换；菜单栏快捷传输 / 镜像 / 断开  

### 其它

- 剪贴板双向同步（默认关，可设置）  
- 通知镜像（opt-in）  
- 简体中文界面  
- **MCP（可选）**：Agent 走 adb 工具链 → [docs/MCP.md](docs/MCP.md)  

---

## 架构（简）

两条并行通道，互不混用：

```
┌────────────── Mac · DroidMate.app ──────────────┐
│  SwiftUI 连接台 · 文件浏览器 · 检查器 · ⌘K        │
│         │                         │              │
│   Data Channel               scrcpy 进程          │
│   文件 / 剪贴板 / 通知         镜像 + 输入          │
└─────────┬─────────────────────────┬──────────────┘
          │ adb forward             │ adb / scrcpy
          ▼                         ▼
┌────────────── Android ──────────────────────────┐
│  DroidMate Server (app_process jar) · scrcpy    │
│  手机无需安装第三方 App                           │
└─────────────────────────────────────────────────┘
```

| 文档 | 内容 |
|------|------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 系统拓扑与模块 |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | Data Channel 协议 |
| [docs/3.0/](docs/3.0/) | 3.0 体验规格（视觉 / 动效 / 壳层 / 性能…） |
| [docs/adr/](docs/adr/) | 架构决策记录 |
| [CONTEXT.md](CONTEXT.md) | 领域词汇 |

---

## 开发

```bash
cd mac
swift build
swift test
swift run DroidMate          # 有多个 executable 时必须写产品名

# 打可分发 DMG → build/DroidMate-<version>.dmg
VERSION=0.3.0 ./scripts/build-dmg.sh
```

设备侧 **Server jar** 放在 `mac/Resources/droidmate-server.jar`（连接时 push），本仓库不包含 Android 工程源码。

| 文档 | |
|------|--|
| [mac/RELEASE.md](mac/RELEASE.md) | 签名与公证 |
| [docs/SMOKE.md](docs/SMOKE.md) | 发布冒烟清单 |

### CI / 发版

| 触发 | 行为 |
|------|------|
| `push` / PR → `main` | `swift test` + release 构建检查（macOS 15） |
| tag `v*`（如 `v0.3.0`） | 打 DMG 并上传到 [Releases](https://github.com/chengxuyuanluyu/DroidMate/releases) |
| Actions → **Release** 手动运行 | 填版本号打包上传 |

```bash
git tag v0.3.0 && git push origin v0.3.0
```

### 仓库结构

```
DroidMate/
├── mac/                 # ★ 唯一产品：macOS 客户端 + scrcpy / adb / server jar
├── docs/                # 架构 · 协议 · ADR · 3.0 规格 · 配图
├── wayfinder/           # 3.0 决策地图与原型（规划过程）
├── .github/workflows/   # CI + Release
└── README · CHANGELOG · LICENSE
```

产品范围见 [ADR-0003 · Mac-only](docs/adr/0003-mac-only-product.md)。

---

## 更新与反馈

- **下载**：始终以 [Releases](https://github.com/chengxuyuanluyu/DroidMate/releases/latest) 为准  
- **问题 / 建议**：[Issues](https://github.com/chengxuyuanluyu/DroidMate/issues)  
- **变更**：[CHANGELOG.md](CHANGELOG.md)  

---

## License

[MIT](LICENSE) · 投屏基于 [scrcpy](https://github.com/Genymobile/scrcpy)（Apache-2.0）
