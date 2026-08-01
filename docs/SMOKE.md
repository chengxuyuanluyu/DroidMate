# DroidMate 手动冒烟清单

发布或合并 **foundation-consolidation** 相关改动后，在真机上过一遍。目标：Data Channel + Mirroring 主路径可用。

## 前置

- [ ] macOS 构建可运行；adb 可用（bundled 或 PATH）
- [ ] Android 设备 USB 调试已授权（可选：wireless adb 已配对）
- [ ] 设备可被 `adb devices` 看到

## 连接与会话

- [ ] 打开 App，设备出现在列表
- [ ] 连接后 Device Session 进入 ready（可 list 目录）
- [ ] 断开/重插后能恢复或明确提示重连

## 文件（Data Channel）

- [ ] 浏览 `/sdcard` 或常用目录，列表非空且可刷新
- [ ] **mkdir** 新建文件夹，列表出现新项
- [ ] **rename** 文件或文件夹，名称更新
- [ ] **duplicate** 右键 → `photo copy.jpg`；再 duplicate → `photo copy 2.jpg`
- [ ] **delete** 单文件；删除文件夹（递归语义与当前产品一致）
- [ ] **Recent** 右键 Remove / Clear；Copy Path 复制 `/sdcard/...`
- [ ] **upload** 小文件成功
- [ ] **upload 多文件** 并行上传可完成
- [ ] **upload 空文件夹** → 设备上出现同名空目录（含子空目录）
- [ ] **拖入 hover** 显示 “Drop N items” 与目标路径
- [ ] **冲突 Keep Both**：同名已存在时选 Keep Both → 出现 `name (1).ext`，原文件保留
- [ ] **download** 单文件成功
- [ ] **download 文件夹**（多个小文件）能完成；可取消传输
- [ ] **download 取消** 后不自动重启，设备端传输流量也停止；中断续传后文件内容与远端一致
- [ ] 续传前替换远端同名文件 → 旧分片被丢弃或明确失败，最终文件不混合新旧内容
- [ ] **多选拖到 Finder**：选中 ≥2 项后拖出，桌面得到含全部项的文件夹
- [ ] **传输历史**：双击行 Reveal；Clear Completed 保留失败/暂停
- [ ] **多文件传输**（默认开）：选 2+ 项下载/上传后自动弹出 Transfer Queue；Settings 可关
- [ ] **download 不存在的远程路径** 应失败（非空目录成功）— DIR_ENTRY `exists`/`is_dir`
- [ ] **Go to Path** 输入不存在路径 → 错误横幅 “Folder not found”，不静默空列表
- [ ] 上次浏览路径已删除 → 连接后回退到根目录

## 前台 vs 缩略图（ticket 04 后加强）

- [ ] 大文件/目录下载进行中时，网格滚动触发的缩略图不长期饿死前台进度

## 剪贴板与通知

- [ ] Mac → Android 文本剪贴板（开关开时）
- [ ] Android → Mac 文本剪贴板（开关开时）
- [ ] 通知镜像 opt-in 后，设备通知能在 Mac 弹出（dumpsys 延迟可接受）

## Mirroring（scrcpy）

- [ ] 启动镜像，SDL/窗口出画
- [ ] **点击/滑动注入有效**（窗口需获得焦点）
- [ ] **小米/HyperOS**：若无法点控，开启开发者选项 → **USB 调试（安全设置）**；DroidMate 会探测失败并自动改用 HID（uhid）
- [ ] 侧栏功能键（Home/Back）在开启安全 USB 调试后可用；未开启时横幅提示
- [ ] 停止镜像后 Data Channel 文件功能仍可用
- [ ] scrcpy 不可用时有明确提示，且不影响纯文件会话

## 无线（可选）

- [ ] USB 开启无线调试后 `adb connect`，文件与镜像仍可用
- [ ] 无线掉线后的重连或错误文案可理解
- [ ] Recent Wi‑Fi：Clear / 单条 × 移除后列表更新

## MCP（可选，`DroidMateMCP` 0.4）

```bash
cd mac && swift build --product DroidMateMCP -c release
```

- [ ] `list_devices` / `device_info` 有输出
- [ ] `path_exists` 对存在目录 `is_dir=true`；对缺失路径 `exists=false`
- [ ] `list_files` 对缺失路径返回 error（非空列表冒充）
- [ ] `mkdir` / `delete_path` 成功；根路径、允许区外路径及指向区外的中间符号链接均被拒绝

## 发布包 0.2.5

- [ ] 安装 `mac/build/DroidMate-0.2.5.dmg`，About 版本为 0.2.5
- [ ] Settings → What's New 有 0.2 要点

## 记录

| 日期 | 构建/分支 | 设备型号 | 结果 | 备注 |
|------|-----------|----------|------|------|
|  |  |  |  |  |
