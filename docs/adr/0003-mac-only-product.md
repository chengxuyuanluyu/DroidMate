# ADR-0003: 产品与仓库仅限 Mac 应用

- **状态**: Accepted（2026-07-31 更新：仓库去掉 Android / archive 树）
- **日期**: 2026-07-31

## 背景

早期曾有 Android APK 实验与独立 `android/server` Gradle 工程。产品收敛为「用户只装 Mac 软件」后，维护多棵树会分散贡献与发版路径。

## 决策

1. **唯一产品交付物**：`DroidMate.app` / GitHub Releases 上的 DMG。
2. **仓库只保留 `mac/` + `docs/` + CI**；不包含 Android 应用或 Server 源码树。
3. **设备侧 Server jar** 以 **vendored 二进制** 放在 `mac/Resources/droidmate-server.jar`，由 Mac 在连接时 push 并以 `app_process` 拉起。
4. 若未来必须改协议 / Server：在独立分支或外部仓库恢复源码，再把产物拷回 `mac/Resources/`，而不是在本仓库长开 Android 模块。

## 后果

- **正面**：贡献面清晰、CI 只跑 Swift、发版流水线简单。
- **负面**：改 Data Channel 协议需额外取回 Server 源码；jar 以二进制进 git（体积可接受）。
