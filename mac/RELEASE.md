# DroidMate macOS 发布指南

外发前请按本清单完成构建、签名与验证。

## 0.2.1 外发前产品自检（交互 / UI / 功能）

| # | 检查项 | 期望 |
|---|--------|------|
| 1 | 首次启动 | Splash → 引导页（含小米安全调试提示）→ 连接页 |
| 2 | USB 连接 | 插线后自动进文件浏览器，状态条正常 |
| 3 | 开始投屏 | 工具栏菜单有「开始投屏 / 开始投屏并录制」；启动中有 spinner 与 Cancel |
| 4 | Dock | 显示 **DroidMate Mirror** 品牌图标，不是黑 exec |
| 5 | 控制条 | 贴在投屏旁；就绪前按键禁用；截图/录屏可用 |
| 6 | 即时录屏 | 计时 `x:xx / 3:00`；到点自动保存并提示 |
| 7 | 会话录制 | Start Mirror & Record → 停投屏后出 mp4 |
| 8 | 小米点击 | 未开安全调试时弹短引导；开启后窗口内点击正常 |
| 9 | Settings 画质 | 预设切换 +「应用并重启投屏」 |
| 10 | 中文系统 | 关键路径中文可读 |
| 11 | 断连 / 退出 | 投屏与录屏进程被回收 |
| 12 | Gatekeeper | **正式外发必须** Developer ID + 公证（见下文） |

---

## 产物

| 文件 | 说明 |
|------|------|
| `mac/build/DroidMate.app` | 可直接运行的应用包 |
| `mac/build/DroidMate-<version>.dmg` | 拖放安装镜像 |
| `mac/build/dmg-background.png` | DMG 窗口背景（构建时生成） |

## 为什么别人会看到「Apple 无法验证…恶意软件」？

当前默认打包是 **ad-hoc 签名**（本机测试用），**没有**经过 Apple **公证（Notarization）**。

从 macOS 10.15 起，从网上下载的未公证 App 会触发 Gatekeeper：

> Apple 无法验证 “DroidMate” 是否包含可能危害 Mac 安全或隐私的恶意软件。

| 方案 | 能否去掉警告 | 说明 |
|------|----------------|------|
| **Developer ID 签名 + 公证** | ✅ 能 | 正式外发唯一正规办法 |
| 让用户右键 → 打开 | ⚠️ 每次/每机一次 | 测试分发可用，体验差 |
| 改代码 / 换图标 | ❌ 不能 | 与软件功能无关 |
| 仅自签 / ad-hoc | ❌ 不能 | 别人机器仍会拦 |

**前提：** 加入 [Apple Developer Program](https://developer.apple.com/programs/)（年费），在钥匙串中安装 **Developer ID Application** 证书。

本机当前若 `security find-identity -v -p codesigning` 为空，说明还没有可用证书。

---

## 一键打包（本机测试 / ad-hoc）

```bash
cd mac
# 测试 + MCP + jar 检查（加 --dmg 会顺带打包）
./scripts/verify-release.sh
./scripts/build-dmg.sh
# 产物：build/DroidMate.app 与 build/DroidMate-0.2.1.dmg
```

环境变量：

| 变量 | 默认 | 说明 |
|------|------|------|
| `VERSION` | `0.2.1` | 版本号 / DMG 文件名 |
| `BUILD` | 时间戳 | `CFBundleVersion` |
| `BUNDLE_ID` | `com.droidmate.app` | Bundle ID |
| `CODESIGN_IDENTITY` | `-`（ad-hoc） | 签名身份 |

---

## 正式外发：签名 + 公证（去掉 Gatekeeper 警告）

### 0. 准备证书与公证凭据

1. Apple Developer → Certificates → 创建 **Developer ID Application**
2. 安装到本机钥匙串后确认：

```bash
security find-identity -v -p codesigning
# 应看到：Developer ID Application: Your Name (TEAMID)
```

3. 在 [appleid.apple.com](https://appleid.apple.com) 生成 **App 专用密码**
4. （推荐）把凭据存进钥匙串，以后免输密码：

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

### 1. 用 Developer ID 打包

```bash
cd mac
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
VERSION=0.2.0 ./scripts/build-dmg.sh
```

脚本会对 `adb`、`scrcpy` 与 `.app` 使用 Hardened Runtime + timestamp，并附带 `entitlements.plist`。

### 2. 提交公证并装订

```bash
# 使用已存储的 profile：
export NOTARY_PROFILE=AC_PASSWORD
./scripts/notarize.sh

# 或直接传环境变量：
export APPLE_ID=you@example.com
export TEAM_ID=TEAMID
export APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'
./scripts/notarize.sh
```

成功后把 **已 staple 的** `build/DroidMate-0.2.0.dmg` 发给用户；双击安装时不应再出现恶意软件警告。

### 3. 验证

```bash
codesign --verify --deep --strict --verbose=2 build/DroidMate.app
spctl --assess --type execute -v build/DroidMate.app
spctl --assess --type open --context context:primary-signature -v build/DroidMate-0.2.0.dmg
# 期望：accepted
```

### 4. 公证失败时

```bash
# 查看最近一次提交日志（按 notarytool 输出的 id）
xcrun notarytool log <submission-id> --keychain-profile AC_PASSWORD
```

常见原因：嵌套二进制未签、缺 timestamp、entitlements 不足。按日志补签后重新 `build-dmg.sh` + `notarize.sh`。

---

## 没有开发者账号时的临时做法（给测试用户）

1. 下载 DMG → 打开  
2. 把 App 拖到「应用程序」  
3. **不要双击**，改为：**右键 App → 打开 → 打开**  
4. 或：系统设置 → 隐私与安全性 → 仍要打开  

并在 README / 发布说明里写清楚上述步骤。

---

## 捆绑依赖

- **adb**：`Sources/DroidMate/Bin/adb`
- **scrcpy**：`Bin/scrcpy` + `Bin/scrcpy-server`（官方便携 v4.1）  
  更新：从 [scrcpy releases](https://github.com/Genymobile/scrcpy/releases) 下载 `scrcpy-macos-aarch64-*.tar.gz` 替换。

---

## 首次使用体验（已内置）

- 首次冷启动品牌动画（可设为仅一次）
- 欢迎引导；设置里可重看 / 导出诊断
- 内置 scrcpy，无需用户再 `brew install`
