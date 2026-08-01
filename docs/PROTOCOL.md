# DroidMate 线缆协议 v1

Mac 客户端 ↔ **DroidMate Server** 的 Data Channel 通信契约。两端必须独立实现。

**范围（ADR-0002）：** control（握手/ping/错误）+ files + clipboard + notifications。  
**不在本协议内：** 屏幕镜像与输入注入由 **scrcpy** 承载（ADR-0001），不经本帧格式。

## 1. 传输层

### 1.1 TCP over adb forward（当前主路径）

```
Mac (127.0.0.1:<forwarded>)  ←adb forward←  Android (127.0.0.1:28042)
```

- Android：DroidMate Server 监听 `127.0.0.1:28042`（Shell UID `app_process`）。
- Mac：对设备 serial 执行 forward 后，用 `NWConnection` 连本机映射端口。
- USB 与 **wireless adb** 均走 adb forward；不是设备局域网直连。

### 1.2 真 Wi-Fi 直连（未实现 / 远期）

计划：Server 听 `0.0.0.0:28042`，mDNS `_droidmate._tcp`，配对码 + TLS。当前产品不依赖此路径。

### 1.3 多路复用

单 TCP 连接，所有 Data Channel 消息通过 **Frame** 多路复用。不同 Stream ID 区分控制与业务。

## 2. 帧格式

多字节整数均为 **小端序**。

```
┌──────────────────────────────────────────────────────────┐
│  Stream ID   │  Message Type  │   Payload Length          │
│   uint16     │    uint16      │      uint32              │
│   2 bytes    │    2 bytes     │      4 bytes             │
├──────────────────────────────────────────────────────────┤
│                      Payload (N bytes)                    │
└──────────────────────────────────────────────────────────┘
```

| Stream ID | 名称 | 用途 |
|-----------|------|------|
| `0x0000` | control | HELLO / PING / ERROR |
| `0x0003` | files | 列目录、上传、下载（及后续 FS 变更） |
| `0x0004` | clipboard | 剪贴板同步 |
| `0x0005` | notifications | 通知镜像 |

- **Payload Length** 上限：16 MB（单帧；文件分块传输时单块远小于此）。
- 接收方先读 8 字节头，再读 payload。

JSON 类消息：payload 为 UTF-8 JSON 对象（**无**额外 length 前缀包一层——与实现一致时以两端代码为准；控制面 Hello 等使用整段 JSON body）。字段名 **snake_case**。

## 3. 控制通道（Stream ID = `0x0000`）

### 3.1 握手

Mac 连上后立即发 `HELLO`；Server 回 `HELLO_ACK`。未完成握手前其他业务消息应丢弃或忽略。

#### `0x0001` HELLO（Mac → Android）

```json
{
  "protocol_version": 1,
  "client_name": "DroidMate Mac 0.1",
  "os_version": "macOS …",
  "capabilities": ["files"]
}
```

#### `0x0002` HELLO_ACK（Android → Mac）

```json
{
  "protocol_version": 1,
  "server_name": "DroidMate Android 0.1",
  "device_model": "…",
  "android_version": "…",
  "screen_width": 1080,
  "screen_height": 2400,
  "screen_dpi": 480,
  "capabilities": ["files", "clipboard", "notifications"],
  "is_rooted": false
}
```

**capabilities 语义：** 仅声明 Data Channel 真实能力。不在此声明 `h265` / scrcpy 输入能力（镜像不经本协议）。

### 3.2 Ping / Pong

保活与 RTT。建议约每 5 秒一次。

#### `0x0010` PING

```
Payload: uint64 timestamp_ns   // 8 字节，发送方单调时钟
```

#### `0x0011` PONG

Payload 原样回传 `timestamp_ns`。

### 3.3 错误

#### `0x00FF` ERROR

```json
{ "code": "string", "message": "string" }
```

## 4. 文件（Stream ID = `0x0003`）

### 4.1 列目录

#### `0x0300` LIST_DIR

```json
{ "req_id": 1, "path": "/sdcard/Download" }
```

#### `0x0301` DIR_ENTRY

```json
{
  "req_id": 1,
  "exists": true,
  "is_dir": true,
  "entries": [
    {
      "name": "file.txt",
      "size": 1024,
      "modified": 1234567890,
      "is_dir": false,
      "mime": "text/plain"
    }
  ]
}
```

- `exists` / `is_dir` describe the **listed path** (not each entry): empty folder → `exists=true`, `is_dir=true`, `entries=[]`; missing path → `exists=false`, `is_dir=false`, `entries=[]`; path is a file → `exists=true`, `is_dir=false`, `entries=[]`.
- Older servers may omit `exists`/`is_dir`; Mac treats them as present directory for compatibility.

### 4.2 上传（Mac → Android）

#### `0x0310` UPLOAD_START

```json
{
  "req_id": 2,
  "dest_path": "/sdcard/Download/x.txt",
  "size": 1024,
  "modified": 1234567890,
  "mime": "text/plain",
  "offset": 0
}
```

- `offset`（可选，默认 0）：当前只接受 `0`。Server 为每次上传创建同目录唯一临时文件；`>0` 会以 `upload resume unsupported` 拒绝。
- DroidMate Mac 始终从 `0` 上传（省略 `offset`）。只有当协议能校验本地源文件 revision 与临时文件归属后才会重新启用自动续传。
- Mac 与 Server 都按规范化后的 `dest_path` 独占目标；同一路径的第二个活动上传会失败，不得共享 partial。

#### `0x0311` UPLOAD_DATA

```
Payload:
  uint32 req_id
  uint64 offset
  uint32 length
  bytes  data
```

#### `0x0312` UPLOAD_COMPLETE

Mac 提交请求会再次声明本地源文件大小：

```json
{ "req_id": 2, "size": 1024, "modified": 1234567890, "dest_path": "/sdcard/Download/x.txt" }
```

Mac 在发送前重查本地文件 revision；大小、修改时间或文件身份变化时改发 `UPLOAD_ABORT`。Server 使用不会覆盖用户文件的同目录唯一 staging 文件；只有在 START 声明大小、已接收字节数、COMPLETE 声明大小与 staging 实际大小全部相等时，才以原子 rename 替换正式目标；rename 失败不得先删除原文件。

Server 回应：

```json
{ "req_id": 2, "success": true, "error": null }
```

#### `0x0313` UPLOAD_ABORT

```json
{ "req_id": 2 }
```

Server 关闭该请求的文件句柄、删除未提交 partial、释放目标独占，并以 `UPLOAD_COMPLETE success=false` 回应。Mac 只在 `UPLOAD_COMPLETE` 尚未入队时提供取消；进入不可逆提交阶段后，传输行显示“正在完成”且不再允许取消。

### 4.3 下载（Android → Mac）

`0x0320` 请求带当前目录条目的版本身份：

```json
{
  "req_id": 3,
  "path": "Download/video.mp4",
  "offset": 1048576,
  "expected_size": 8388608,
  "expected_modified": 1785580800000
}
```

Server 只在大小和修改时间仍匹配时开流，并返回同一版本身份：

```json
{
  "req_id": 3,
  "size": 8388608,
  "modified": 1785580800000,
  "offset": 1048576,
  "mime": "video/mp4"
}
```

`0x0321` 的二进制布局与 `UPLOAD_DATA` 相同。Server 在读完后再次校验源文件版本；任一端发现版本、offset、length 或总字节数不一致，均以 `0x0322 success=false` 收尾且不得提交本地目标文件。

Mac 用 `0x0323` 取消仍在发送的下载，Server 按 `req_id` 停止设备端读取与后续数据帧：

```json
{ "req_id": 3 }
```

### 4.4 FS 变更（delete / rename / mkdir）

与 list/transfer 同通道。路径为设备绝对路径风格（与 list 的 `path` 相同解析规则，相对 `/sdcard`）。

#### `0x0330` FS_DELETE（Mac → Android）

```json
{ "req_id": 1, "paths": ["/sdcard/Download/a.txt", "/sdcard/Download/folder"] }
```

目录 **递归删除**（等同 `rm -rf` 语义）。

#### `0x0331` FS_DELETE_RESULT（Android → Mac）

```json
{
  "req_id": 1,
  "results": [
    { "path": "/sdcard/Download/a.txt", "success": true, "error": null },
    { "path": "/sdcard/Download/folder", "success": false, "error": "FILE_NOT_FOUND" }
  ]
}
```

部分失败时仍返回全部 `results`；客户端可刷新列表并展示失败项。

#### `0x0332` FS_RENAME（Mac → Android）

```json
{ "req_id": 2, "from": "/sdcard/a.txt", "to": "/sdcard/b.txt" }
```

同存储上的 rename/move；目标已存在则 `FILE_EXISTS`。

#### `0x0333` FS_RENAME_RESULT / `0x0335` FS_MKDIR_RESULT

```json
{ "req_id": 2, "success": true, "error": null }
```

#### `0x0334` FS_MKDIR（Mac → Android）

```json
{ "req_id": 3, "path": "/sdcard/Download/NewFolder" }
```

**mkdir -p**：创建中间父目录；路径已是目录则 success。

#### `0x0336` FS_COPY（Mac → Android）

```json
{ "req_id": 4, "from": "Download/a.txt", "to": "Download/a copy.txt" }
```

路径与 list 相同（相对 `/sdcard`）。目录 **递归复制**；`to` 已存在 → `FILE_EXISTS`。大树在 server 后台线程执行。

#### `0x0337` FS_COPY_RESULT

与 rename/mkdir 相同：

```json
{ "req_id": 4, "success": true, "error": null }
```

## 5. 剪贴板（Stream ID = `0x0004`）

双向同步；MVP 仅 `text/plain`。

### `0x0400` CLIPBOARD_SYNC

```json
{
  "ts": 1234567890,
  "source": "mac" | "android",
  "mime": "text/plain",
  "text": "…"
}
```

- `text` 上限约 1MB（超出截断并打日志）。
- 发送方去抖约 200ms。
- **回环避免：** 接收方写入本地剪贴板前标记“下一次本地变更由我引起”，监听器见 flag 则跳过发送。
- 方向开关仅在 Mac：`clipboard.mac_to_android` / `clipboard.android_to_mac`（默认 true）。Server 收到即写。

## 6. 通知（Stream ID = `0x0005`）

单向 Android → Mac。Shell UID 下用 **dumpsys 轮询**（约 2s），非 `NotificationListenerService`。

### `0x0500` NOTIFICATION_ADDED

```json
{
  "ts": 1234567890,
  "key": "0|com.example.app|1|null|10123",
  "package": "com.example.app",
  "id": 1,
  "tag": null,
  "title": "…",
  "text": "…",
  "category": "msg"
}
```

### `0x0501` NOTIFICATION_REMOVED

```json
{
  "ts": 1234567890,
  "key": "0|com.example.app|1|null|10123",
  "reason": "unknown"
}
```

Mac：`UNUserNotificationCenter` 展示；REMOVED 通常仅日志（系统限制无法可靠编程 dismiss）。`call`/`alarm` 可静默。开关：`notifications.mirror_android`（默认 false，opt-in）。

## 7. 错误码

| Code | 含义 |
|------|------|
| `PROTOCOL_VERSION_MISMATCH` | 协议版本不兼容 |
| `UNKNOWN_MESSAGE` | 未定义消息类型 |
| `MALFORMED_PAYLOAD` | payload 无法解析 |
| `CAPABILITY_NOT_SUPPORTED` | 对端不支持所需能力 |
| `FILE_NOT_FOUND` | 文件不存在 |
| `FILE_PERMISSION_DENIED` | 文件访问权限不足 |

> `PROJECTION_REVOKED` / `INPUT_PERMISSION_DENIED` 属于已退役自研视频/输入路径；Mac 客户端不再依赖。Server Stage B 精简后不应再产生。

## 8. 版本演进

- 新增 JSON 字段放在末尾；旧版忽略未知字段。
- 删除字段：先 `deprecated`，至少保留一个版本。
- 改语义：bump `protocol_version`。
- v0 为 MVP，不保证长期向后兼容。

## 附录 A — 已退役类型（勿再实现）

下列 Stream / 消息曾用于自研镜像与输入，**Mac 已删除**；Android 若仍残留 handler，属 Stage B 待删死代码，**不是产品契约**。

| 原 Stream | 原 Msg | 说明 |
|-----------|--------|------|
| `0x0001` video | `0x0020–0x0023`, `0x0100` | VIDEO_* / FRAME → 改由 scrcpy |
| `0x0002` input | `0x0200`, `0x0210`, `0x0220` | TOUCH / KEY / SCROLL → 改由 scrcpy |

新代码不得重新启用上述 ID 承载业务，除非另开 ADR 并 bump 协议版本。
