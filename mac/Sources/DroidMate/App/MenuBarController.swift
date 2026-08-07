import AppKit

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private weak var connMgr: ConnectionManager?
    weak var scrcpy: ScrcpyController?
    func setup(connMgr: ConnectionManager) {
        self.connMgr = connMgr
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "iphone.gen3.radiowaves.left.and.right",
            accessibilityDescription: "DroidMate"
        )
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        // ── Device list ──
        if let connMgr, !connMgr.engines.isEmpty {
            for engine in connMgr.engines {
                let title = engine.displayName
                let item = NSMenuItem(title: title, action: #selector(switchDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = engine.deviceSerial
                item.state = engine.deviceSerial == connMgr.activeDeviceId ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // ── Mirror controls (shown when scrcpy is running) ──
        if let scrcpy, !scrcpy.runningSerials.isEmpty {
            let mirrorHeader = NSMenuItem(title: NSLocalizedString("Mirror", comment: "Menu Bar"),
                                          action: nil, keyEquivalent: "")
            mirrorHeader.isEnabled = false
            menu.addItem(mirrorHeader)

            // Function keys
            addKeyItem(menu, title: NSLocalizedString("Back", comment: ""),
                       keycode: "KEYCODE_BACK", symbol: "arrow.left")
            addKeyItem(menu, title: NSLocalizedString("Home", comment: ""),
                       keycode: "KEYCODE_HOME", symbol: "house.fill")
            addKeyItem(menu, title: NSLocalizedString("Recents", comment: ""),
                       keycode: "KEYCODE_APP_SWITCH", symbol: "square.fill")
            addKeyItem(menu, title: NSLocalizedString("Power", comment: ""),
                       keycode: "KEYCODE_POWER", symbol: "power")
            addKeyItem(menu, title: NSLocalizedString("Volume Up", comment: ""),
                       keycode: "KEYCODE_VOLUME_UP", symbol: "speaker.wave.2.fill")
            addKeyItem(menu, title: NSLocalizedString("Volume Down", comment: ""),
                       keycode: "KEYCODE_VOLUME_DOWN", symbol: "speaker.wave.1.fill")

            // Stop
            let stopItem = NSMenuItem(title: NSLocalizedString("Stop Mirror", comment: ""),
                                      action: #selector(stopMirror(_:)), keyEquivalent: "")
            stopItem.target = self
            stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
            menu.addItem(stopItem)

            menu.addItem(.separator())
        }

        // ── Session actions ──
        if let connMgr, let engine = connMgr.activeEngine {
            let transferCount = engine.files.transferEngine.activeTransferCount
            if transferCount > 0 {
                let transfersItem = NSMenuItem(
                    title: String(format: NSLocalizedString("Transfers (%lld)", comment: "Menu Bar"), transferCount),
                    action: #selector(openTransfers),
                    keyEquivalent: ""
                )
                transfersItem.target = self
                transfersItem.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
                menu.addItem(transfersItem)
            } else {
                let transfersItem = NSMenuItem(
                    title: NSLocalizedString("Transfers", comment: "Menu Bar"),
                    action: #selector(openTransfers),
                    keyEquivalent: ""
                )
                transfersItem.target = self
                transfersItem.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
                menu.addItem(transfersItem)
            }

            if let scrcpy, !scrcpy.runningSerials.contains(engine.deviceSerial),
               engine.isSessionReady, scrcpy.isScrcpyAvailable {
                let mirrorItem = NSMenuItem(
                    title: NSLocalizedString("Start Mirror", comment: "Menu Bar"),
                    action: #selector(startMirror),
                    keyEquivalent: ""
                )
                mirrorItem.target = self
                mirrorItem.image = NSImage(systemSymbolName: "airplayvideo", accessibilityDescription: nil)
                menu.addItem(mirrorItem)

                let recordItem = NSMenuItem(
                    title: NSLocalizedString("Start Mirror & Record", comment: "Menu Bar"),
                    action: #selector(startMirrorAndRecord),
                    keyEquivalent: ""
                )
                recordItem.target = self
                recordItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
                menu.addItem(recordItem)
            }

            let disconnectItem = NSMenuItem(
                title: NSLocalizedString("Disconnect", comment: "Menu Bar"),
                action: #selector(disconnectActive),
                keyEquivalent: ""
            )
            disconnectItem.target = self
            disconnectItem.image = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                accessibilityDescription: nil
            )
            menu.addItem(disconnectItem)

            menu.addItem(.separator())
        }

        // ── App actions ──
        let openItem = NSMenuItem(
            title: NSLocalizedString("Open DroidMate", comment: "Menu Bar"),
            action: #selector(openApp), keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("Quit", comment: "Menu Bar"),
            action: #selector(quit), keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func addKeyItem(_ menu: NSMenu, title: String, keycode: String, symbol: String) {
        let item = NSMenuItem(title: title, action: #selector(sendKey(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = keycode
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func switchDevice(_ sender: NSMenuItem) {
        guard let serial = sender.representedObject as? String else { return }
        connMgr?.switchTo(serial)
        rebuildMenu()
    }

    @objc private func sendKey(_ sender: NSMenuItem) {
        guard let keycode = sender.representedObject as? String else { return }
        // Prefer the active device if it has a live mirror; else first mirrored serial.
        let serial = mirrorSerialForMenuActions()
        guard let serial else { return }
        scrcpy?.sendKey(serial: serial, keycode: keycode)
    }

    @objc private func stopMirror(_ sender: NSMenuItem) {
        guard let scrcpy else { return }
        if let serial = mirrorSerialForMenuActions() {
            scrcpy.stop(serial: serial)
        } else {
            // No active match — stop every live mirror so the menu never strands one.
            for serial in scrcpy.runningSerials {
                scrcpy.stop(serial: serial)
            }
        }
    }

    /// Serial for menu-bar mirror actions: active device if mirroring, else any running.
    private func mirrorSerialForMenuActions() -> String? {
        guard let scrcpy, !scrcpy.runningSerials.isEmpty else { return nil }
        if let active = connMgr?.activeEngine?.deviceSerial,
           scrcpy.runningSerials.contains(active) {
            return active
        }
        return scrcpy.runningSerials.sorted().first
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !window.title.isEmpty {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    @objc private func openTransfers() {
        openApp()
        NotificationCenter.default.post(name: .openTransfers, object: nil)
    }

    @objc private func startMirror() {
        guard let engine = connMgr?.activeEngine else { return }
        openApp()
        _ = scrcpy?.startMirror(
            serial: engine.deviceSerial,
            deviceModel: engine.ack?.deviceModel,
            recordSession: false
        )
        rebuildMenu()
    }

    @objc private func startMirrorAndRecord() {
        guard let engine = connMgr?.activeEngine else { return }
        openApp()
        _ = scrcpy?.startMirror(
            serial: engine.deviceSerial,
            deviceModel: engine.ack?.deviceModel,
            recordSession: true
        )
        rebuildMenu()
    }

    @objc private func disconnectActive() {
        guard let serial = connMgr?.activeEngine?.deviceSerial else { return }
        // Stages confirmation on RootView when transfers are active.
        connMgr?.requestDisconnect(serial)
        openApp()
        rebuildMenu()
    }

    @objc private func quit() {
        // Status-item menus run a *nested* AppKit event loop. Calling
        // `NSApp.terminate` synchronously from the menu action keeps that
        // tracker live while AppKit tries to resolve pasteboard promises
        // (`CFPasteboardResolveAllPromisedData`) on another nested runloop —
        // Spinning Wait / hang for many seconds (reported as “闪退” after Quit).
        // Defer until the menu has fully dismissed, then clean up and quit.
        // AEQuit / Cmd+Q / Dock use AppDelegate.applicationShouldTerminate
        // for the same pasteboard prep (this path alone is not enough).
        DispatchQueue.main.async { [weak self] in
            self?.prepareAndTerminate()
        }
    }

    private func prepareAndTerminate() {
        // Resolve drag promises before entering AppKit's termination path. The
        // delegate owns the asynchronous recording + connection shutdown.
        AppQuitPrep.cancelImmediateWork()
        NSApp.terminate(nil)
    }
}
