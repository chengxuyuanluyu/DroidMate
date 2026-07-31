import MCP
import Foundation
import DroidMateWire

/// DroidMate MCP server — device control via adb (no APK).
/// Build: `swift build --product DroidMateMCP`
/// Configure your agent to run the binary with stdio transport.
@main
struct DroidMateMCPServer {
    static func main() async throws {
        let server = Server(
            name: "DroidMate",
            version: "0.4.1",
            capabilities: Server.Capabilities(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try Self.dispatch(params)
            } catch {
                return fail("error: \(error.localizedDescription)")
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tools

    private static let tools: [Tool] = [
        Tool(
            name: "list_devices",
            description: "List adb devices (serial, state, and optional model).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "device_state",
            description: "Return adb connection state for a device (device / offline / unauthorized / …).",
            inputSchema: toolSchema(properties: [
                "serial": stringProp("Optional device serial; defaults to sole device if only one is connected."),
            ])
        ),
        Tool(
            name: "screenshot",
            description: "Capture the device screen as a PNG (via adb exec-out screencap).",
            inputSchema: toolSchema(properties: [
                "serial": stringProp("Device serial from list_devices. Optional if only one device."),
            ])
        ),
        Tool(
            name: "tap",
            description: "Tap screen coordinates (pixels).",
            inputSchema: toolSchema(
                properties: [
                    "x": numberProp("X in device pixels"),
                    "y": numberProp("Y in device pixels"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["x", "y"]
            )
        ),
        Tool(
            name: "swipe",
            description: "Swipe from (x1,y1) to (x2,y2) over duration_ms.",
            inputSchema: toolSchema(
                properties: [
                    "x1": numberProp("Start X"),
                    "y1": numberProp("Start Y"),
                    "x2": numberProp("End X"),
                    "y2": numberProp("End Y"),
                    "duration_ms": numberProp("Duration in ms (default 300)"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["x1", "y1", "x2", "y2"]
            )
        ),
        Tool(
            name: "type_text",
            description: "Type text via adb (spaces become %s; limited Unicode support).",
            inputSchema: toolSchema(
                properties: [
                    "text": stringProp("Text to type"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["text"]
            )
        ),
        Tool(
            name: "keyevent",
            description: "Send an Android keyevent code or name (e.g. 4, KEYCODE_BACK, KEYCODE_HOME).",
            inputSchema: toolSchema(
                properties: [
                    "key": stringProp("Key code number or KEYCODE_* name"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["key"]
            )
        ),
        Tool(
            name: "list_apps",
            description: "List third-party package names (pm list packages -3).",
            inputSchema: toolSchema(properties: [
                "serial": stringProp("Optional device serial"),
            ])
        ),
        Tool(
            name: "list_files",
            description: "List a directory on the device (ls -la via adb shell). Errors if path is missing.",
            inputSchema: toolSchema(
                properties: [
                    "path": stringProp("Absolute path, e.g. /sdcard/Download"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["path"]
            )
        ),
        Tool(
            name: "path_exists",
            description: "Check whether a path exists and whether it is a directory (test -e / -d).",
            inputSchema: toolSchema(
                properties: [
                    "path": stringProp("Absolute path on the device"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["path"]
            )
        ),
        Tool(
            name: "device_info",
            description: "Read model, Android version, SDK, serial, and battery level via getprop/dumpsys.",
            inputSchema: toolSchema(properties: [
                "serial": stringProp("Optional device serial"),
            ])
        ),
        Tool(
            name: "pull_file",
            description: "Pull a remote file to a local path on this Mac.",
            inputSchema: toolSchema(
                properties: [
                    "remote_path": stringProp("Device path"),
                    "local_path": stringProp("Mac destination path"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["remote_path", "local_path"]
            )
        ),
        Tool(
            name: "push_file",
            description: "Push a local Mac file to a path on the device.",
            inputSchema: toolSchema(
                properties: [
                    "local_path": stringProp("Mac source path"),
                    "remote_path": stringProp("Device destination path"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["local_path", "remote_path"]
            )
        ),
        Tool(
            name: "install_apk",
            description: "Install an APK from a local Mac path (adb install -r).",
            inputSchema: toolSchema(
                properties: [
                    "local_path": stringProp("Path to .apk on Mac"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["local_path"]
            )
        ),
        Tool(
            name: "uninstall_app",
            description: "Uninstall a package by name.",
            inputSchema: toolSchema(
                properties: [
                    "package": stringProp("Package name"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["package"]
            )
        ),
        Tool(
            name: "launch_app",
            description: "Launch an app via monkey LAUNCHER (package name).",
            inputSchema: toolSchema(
                properties: [
                    "package": stringProp("Package name, e.g. com.android.settings"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["package"]
            )
        ),
        Tool(
            name: "force_stop_app",
            description: "Force-stop a running package (am force-stop).",
            inputSchema: toolSchema(
                properties: [
                    "package": stringProp("Package name"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["package"]
            )
        ),
        Tool(
            name: "mkdir",
            description: "Create a directory on the device (mkdir -p). Absolute path required.",
            inputSchema: toolSchema(
                properties: [
                    "path": stringProp("Absolute path, e.g. /sdcard/Download/MyFolder"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["path"]
            )
        ),
        Tool(
            name: "delete_path",
            description: "Delete a file or directory on the device (rm -rf). Refuses storage roots.",
            inputSchema: toolSchema(
                properties: [
                    "path": stringProp("Absolute path to delete (not / or /sdcard)"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["path"]
            )
        ),
        Tool(
            name: "rename_path",
            description: "Rename or move a file/directory on the device (mv).",
            inputSchema: toolSchema(
                properties: [
                    "from": stringProp("Source absolute path"),
                    "to": stringProp("Destination absolute path"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["from", "to"]
            )
        ),
        Tool(
            name: "shell",
            description: "Run a single adb shell command (no interactive shell). Prefer dedicated tools when available.",
            inputSchema: toolSchema(
                properties: [
                    "command": stringProp("Shell command string"),
                    "serial": stringProp("Optional device serial"),
                ],
                required: ["command"]
            )
        ),
    ]

    private static func toolSchema(
        properties: [String: Value],
        required: [String] = []
    ) -> Value {
        var obj: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            obj["required"] = .array(required.map { .string($0) })
        }
        return .object(obj)
    }

    private static func stringProp(_ description: String) -> Value {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }

    private static func numberProp(_ description: String) -> Value {
        .object([
            "type": .string("number"),
            "description": .string(description),
        ])
    }

    // MARK: - Dispatch

    private static func dispatch(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let args = params.arguments ?? [:]
        let serial = args["serial"]?.stringValue

        switch params.name {
        case "list_devices":
            return textOK(Adb.listDevicesFormatted())

        case "device_state":
            // `adb get-state` → device | offline | bootloader | …
            do {
                let state = try Adb.execString(["get-state"], serial: serial)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return textOK(state.isEmpty ? "unknown" : state)
            } catch {
                return fail(error.localizedDescription)
            }

        case "screenshot":
            let data = try Adb.execData(["exec-out", "screencap", "-p"], serial: serial)
            guard !data.isEmpty else {
                return fail("screenshot failed — empty output; is a device connected?")
            }
            let b64 = data.base64EncodedString()
            return CallTool.Result(
                content: [.image(data: b64, mimeType: "image/png", annotations: nil, _meta: nil)],
                isError: false
            )

        case "tap":
            let x = args["x"]?.intValue ?? Int(args["x"]?.doubleValue ?? 0)
            let y = args["y"]?.intValue ?? Int(args["y"]?.doubleValue ?? 0)
            _ = try Adb.execString(["shell", "input", "tap", "\(x)", "\(y)"], serial: serial)
            return textOK("tapped (\(x), \(y))")

        case "swipe":
            let x1 = args["x1"]?.intValue ?? Int(args["x1"]?.doubleValue ?? 0)
            let y1 = args["y1"]?.intValue ?? Int(args["y1"]?.doubleValue ?? 0)
            let x2 = args["x2"]?.intValue ?? Int(args["x2"]?.doubleValue ?? 0)
            let y2 = args["y2"]?.intValue ?? Int(args["y2"]?.doubleValue ?? 0)
            let dur = args["duration_ms"]?.intValue ?? Int(args["duration_ms"]?.doubleValue ?? 300)
            _ = try Adb.execString(
                ["shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(dur)"],
                serial: serial
            )
            return textOK("swiped (\(x1),\(y1)) → (\(x2),\(y2)) in \(dur)ms")

        case "type_text":
            guard let text = args["text"]?.stringValue else { return fail("text required") }
            let escaped = text
                .replacingOccurrences(of: " ", with: "%s")
                .replacingOccurrences(of: "'", with: "\\'")
            _ = try Adb.execString(["shell", "input", "text", escaped], serial: serial)
            return textOK("typed \(text.count) characters")

        case "keyevent":
            guard let key = args["key"]?.stringValue else { return fail("key required") }
            _ = try Adb.execString(["shell", "input", "keyevent", key], serial: serial)
            return textOK("keyevent \(key)")

        case "list_apps":
            let out = try Adb.execString(["shell", "pm", "list", "packages", "-3"], serial: serial)
            let pkgs = out.split(separator: "\n")
                .compactMap { line -> String? in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    return l.hasPrefix("package:") ? String(l.dropFirst("package:".count)) : nil
                }
                .joined(separator: "\n")
            return textOK(pkgs.isEmpty ? "no apps" : pkgs)

        case "list_files":
            guard let path = args["path"]?.stringValue else { return fail("path required") }
            if let err = PathSafety.validateDevicePath(path, allowRoots: true) { return fail(err) }
            let probe = try Adb.execString(
                ["shell", "if [ ! -e \(PathSafety.shellQuote(path)) ]; then echo __MISSING__; elif [ ! -d \(PathSafety.shellQuote(path)) ]; then echo __NOTDIR__; else echo __OK__; fi"],
                serial: serial
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if probe.contains("__MISSING__") {
                return fail("path not found: \(path)")
            }
            if probe.contains("__NOTDIR__") {
                return fail("not a directory: \(path)")
            }
            // Single shell string so quoting applies; array form would pass quotes literally.
            let out = try Adb.execString(["shell", "ls -la \(PathSafety.shellQuote(path))"], serial: serial)
            return textOK(out.isEmpty ? "(empty)" : out)

        case "path_exists":
            guard let path = args["path"]?.stringValue else { return fail("path required") }
            if let err = PathSafety.validateDevicePath(path, allowRoots: true) { return fail(err) }
            let probe = try Adb.execString(
                ["shell", "if [ ! -e \(PathSafety.shellQuote(path)) ]; then echo MISSING; elif [ -d \(PathSafety.shellQuote(path)) ]; then echo DIR; else echo FILE; fi"],
                serial: serial
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if probe.contains("MISSING") {
                return textOK("exists=false\nis_dir=false\npath=\(path)")
            }
            if probe.contains("DIR") {
                return textOK("exists=true\nis_dir=true\npath=\(path)")
            }
            return textOK("exists=true\nis_dir=false\npath=\(path)")

        case "device_info":
            let model = try Adb.execString(["shell", "getprop", "ro.product.model"], serial: serial)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let manufacturer = try Adb.execString(["shell", "getprop", "ro.product.manufacturer"], serial: serial)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let release = try Adb.execString(["shell", "getprop", "ro.build.version.release"], serial: serial)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sdk = try Adb.execString(["shell", "getprop", "ro.build.version.sdk"], serial: serial)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let serialProp = try Adb.execString(["shell", "getprop", "ro.serialno"], serial: serial)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let batteryRaw = try Adb.execString(["shell", "dumpsys", "battery"], serial: serial)
            let level = batteryRaw
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { $0.hasPrefix("level:") })
                .map { $0.replacingOccurrences(of: "level:", with: "").trimmingCharacters(in: .whitespaces) }
                ?? "?"
            let lines = [
                "manufacturer: \(manufacturer.isEmpty ? "?" : manufacturer)",
                "model: \(model.isEmpty ? "?" : model)",
                "android: \(release.isEmpty ? "?" : release)",
                "sdk: \(sdk.isEmpty ? "?" : sdk)",
                "serial: \(serialProp.isEmpty ? (serial ?? "?") : serialProp)",
                "battery: \(level)%",
            ]
            return textOK(lines.joined(separator: "\n"))

        case "pull_file":
            guard let remote = args["remote_path"]?.stringValue,
                  let local = args["local_path"]?.stringValue else {
                return fail("remote_path and local_path required")
            }
            let parent = URL(fileURLWithPath: local).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let out = try Adb.execString(["pull", remote, local], serial: serial)
            return textOK(out.isEmpty ? "pulled \(remote) → \(local)" : out)

        case "push_file":
            guard let local = args["local_path"]?.stringValue,
                  let remote = args["remote_path"]?.stringValue else {
                return fail("local_path and remote_path required")
            }
            guard FileManager.default.fileExists(atPath: local) else {
                return fail("local file not found: \(local)")
            }
            let out = try Adb.execString(["push", local, remote], serial: serial)
            return textOK(out.isEmpty ? "pushed \(local) → \(remote)" : out)

        case "install_apk":
            guard let local = args["local_path"]?.stringValue else { return fail("local_path required") }
            guard FileManager.default.fileExists(atPath: local) else {
                return fail("apk not found: \(local)")
            }
            let out = try Adb.execString(["install", "-r", local], serial: serial)
            return textOK(out.isEmpty ? "install finished" : out)

        case "uninstall_app":
            guard let pkg = args["package"]?.stringValue else { return fail("package required") }
            let out = try Adb.execString(["uninstall", pkg], serial: serial)
            return textOK(out.isEmpty ? "uninstalled \(pkg)" : out)

        case "launch_app":
            guard let pkg = args["package"]?.stringValue, !pkg.isEmpty else {
                return fail("package required")
            }
            guard PathSafety.isSafePackage(pkg) else { return fail("invalid package name") }
            // monkey is the reliable one-liner for “open app” without resolving activity.
            let cmd = "monkey -p \(PathSafety.shellQuote(pkg)) -c android.intent.category.LAUNCHER 1"
            let out = try Adb.execString(["shell", cmd], serial: serial)
            return textOK(out.isEmpty ? "launched \(pkg)" : out)

        case "force_stop_app":
            guard let pkg = args["package"]?.stringValue, !pkg.isEmpty else {
                return fail("package required")
            }
            guard PathSafety.isSafePackage(pkg) else { return fail("invalid package name") }
            _ = try Adb.execString(["shell", "am", "force-stop", pkg], serial: serial)
            return textOK("force-stopped \(pkg)")

        case "mkdir":
            guard let path = args["path"]?.stringValue else { return fail("path required") }
            if let err = PathSafety.validateDevicePath(path, allowRoots: true) { return fail(err) }
            _ = try Adb.execString(["shell", "mkdir -p \(PathSafety.shellQuote(path))"], serial: serial)
            return textOK("mkdir \(path)")

        case "delete_path":
            guard let path = args["path"]?.stringValue else { return fail("path required") }
            if let err = PathSafety.validateDevicePath(path, allowRoots: false) { return fail(err) }
            _ = try Adb.execString(["shell", "rm -rf \(PathSafety.shellQuote(path))"], serial: serial)
            return textOK("deleted \(path)")

        case "rename_path":
            guard let from = args["from"]?.stringValue,
                  let to = args["to"]?.stringValue else {
                return fail("from and to required")
            }
            if let err = PathSafety.validateDevicePath(from, allowRoots: false) { return fail("from: \(err)") }
            if let err = PathSafety.validateDevicePath(to, allowRoots: true) { return fail("to: \(err)") }
            _ = try Adb.execString(
                ["shell", "mv \(PathSafety.shellQuote(from)) \(PathSafety.shellQuote(to))"],
                serial: serial
            )
            return textOK("moved \(from) → \(to)")

        case "shell":
            guard let cmd = args["command"]?.stringValue else { return fail("command required") }
            let out = try Adb.execString(["shell", cmd], serial: serial)
            return textOK(out.isEmpty ? "(no output)" : out)

        default:
            return fail("unknown tool: \(params.name)")
        }
    }

    private static func textOK(_ s: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: s, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    private static func fail(_ s: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: s, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
