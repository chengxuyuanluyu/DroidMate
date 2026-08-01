# DroidMate MCP Server

Agent-facing tools over **adb** (no Android APK). Product scope: Mac-only host.

## Build

```bash
cd mac
swift build --product DroidMateMCP -c release
# Binary:
#   mac/.build/release/DroidMateMCP
```

Optional: copy next to the app or put on `PATH`.

## adb resolution

`DroidMateMCP` looks for `adb` in order:

1. `DROIDMATE_ADB` environment variable (full path)
2. Path next to the MCP binary: `../Resources/Bin/adb` (when placed inside an app bundle layout)
3. `DroidMate.app/Contents/Resources/Bin/adb` under `/Applications` or `~/Applications`
4. Dev tree: `mac/Sources/DroidMate/Bin/adb`
5. Android SDK / Homebrew / `which adb`

```bash
export DROIDMATE_ADB=/path/to/adb
```

## Claude Desktop (example)

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "droidmate": {
      "command": "/Users/YOU/Developer/DroidMate/mac/.build/release/DroidMateMCP",
      "env": {
        "DROIDMATE_ADB": "/Users/YOU/Developer/DroidMate/mac/Sources/DroidMate/Bin/adb"
      }
    }
  }
}
```

Restart Claude Desktop after editing.

## Tools

| Tool | Purpose |
|------|---------|
| `list_devices` | `adb devices -l` |
| `device_state` | `adb get-state` (device / offline / …) |
| `device_info` | Model / Android / SDK / battery |
| `screenshot` | PNG via `screencap` |
| `tap` / `swipe` / `type_text` / `keyevent` | Input |
| `list_apps` | Third-party packages |
| `launch_app` / `force_stop_app` | Open / stop package |
| `list_files` | `ls -la` (fails if missing / not a dir) |
| `path_exists` | `exists` + `is_dir` for a path |
| `pull_file` / `push_file` | Transfer |
| `mkdir` / `delete_path` / `rename_path` | Device FS (destructive paths limited to shared storage or `/data/local/tmp`) |
| `install_apk` / `uninstall_app` | Packages |
| `shell` | Raw `adb shell` (prefer dedicated tools) |

All tools accept optional **`serial`** when multiple devices are connected. Call `list_devices` first.

Version: **0.4.1** (21 tools).

## Notes

- MCP does **not** talk to the DroidMate Data Channel yet; it uses adb independently of the GUI session (ADR-0004).
- MCP **depends on `DroidMateWire`** (shared frame codec / protocol types) so a future Data Channel client can reuse the same definitions.
- Keep USB debugging authorized; wireless adb works if the serial is `host:port`.
- `delete_path` and both `rename_path` operands must be children of `/sdcard`, `/storage/emulated/0`, `/storage/self/primary`, or `/data/local/tmp`. The device-side canonical path is checked before execution so intermediate symlinks cannot escape the allowlist.
- `path_exists` / `list_files` distinguish missing paths from empty directories.
- Do not expose `shell` to untrusted agents without review.
