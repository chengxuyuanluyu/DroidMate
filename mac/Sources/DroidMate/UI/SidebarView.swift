import AppKit
import SwiftUI
import UserNotifications

/// Left column of the NavigationSplitView: device list, locations, disconnect.
/// Custom rows instead of List — a Button inside a List row only gets hits on
/// its label's width, so clicks on the row's empty right side were swallowed
/// (the old "taps sometimes do nothing" bug). These rows fill the full width.
struct SidebarView: View {
    @ObservedObject var connMgr: ConnectionManager
    @ObservedObject var engine: DeviceSession
    @ObservedObject var client: FileClient
    var serial: String?
    @ObservedObject var scrcpy: ScrcpyController

    @State private var batteryInfo: AdbBridge.BatteryInfo?
    @State private var storageText: String?
    @State private var showAddDevice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SidebarDevicesSection(
                        connMgr: connMgr,
                        engine: engine,
                        scrcpy: scrcpy,
                        batteryInfo: batteryInfo,
                        storageText: storageText
                    )
                    SidebarLocationsSection(client: client)
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
            }
            Divider()
            disconnectFooter
        }
        .task(id: engine.deviceSerial) {
            let serial = engine.deviceSerial
            // Alert on the falling edge (≥20% → <20% while discharging) so a
            // device already low on first observation doesn't re-notify, and a
            // recovered device re-arming works naturally.
            var lastLevel: Int?
            while !Task.isCancelled {
                do {
                    let metrics = try await ConnectionManager.runAdbOperation { () -> (AdbBridge.BatteryInfo?, String?) in
                        let battery = AdbBridge.shared.getBatteryInfo(serial: serial)
                        let storage = AdbBridge.shared.getStorageInfo(serial: serial).map { info in
                            let used = ByteCountFormatter.string(fromByteCount: info.usedBytes, countStyle: .file)
                            let total = ByteCountFormatter.string(fromByteCount: info.totalBytes, countStyle: .file)
                            return "\(used) / \(total)"
                        }
                        return (battery, storage)
                    }
                    batteryInfo = metrics.0
                    storageText = metrics.1
                    if let info = metrics.0,
                       let prev = lastLevel,
                       prev >= 20, info.level < 20, !info.isCharging {
                        sendLowBatteryNotification(serial: serial, level: info.level)
                    }
                    lastLevel = metrics.0?.level
                } catch is CancellationError {
                    return
                } catch {
                    // Keep the last known values — one flaky adb call shouldn't
                    // flash the battery/storage rows empty every 30s.
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// One-shot local notification when the device battery drops below 20%
    /// while discharging. Skipped in dev (`swift run`) builds.
    private func sendLowBatteryNotification(serial: String, level: Int) {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Low battery")
        content.body = String(localized: "\(engine.displayName) is at \(level)%. Plug in soon.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "low-battery-\(serial)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Footer

    private var disconnectFooter: some View {
        VStack(spacing: 8) {
            Button {
                showAddDevice = true
            } label: {
                Label("Add Device", systemImage: "plus.circle")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                requestDisconnect()
            } label: {
                Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(connMgr.engines.isEmpty)
        }
        .padding(.horizontal, DM.Space.md)
        .padding(.vertical, DM.Space.md)
        .background(.bar)
        .sheet(isPresented: $showAddDevice) {
            NavigationStack {
                ConnectionView(connMgr: connMgr)
                    .navigationTitle("Add Device")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showAddDevice = false }
                        }
                    }
            }
            .frame(minWidth: 480, minHeight: 520)
        }
        .onChange(of: connMgr.engines.count) { old, new in
            if new > old { showAddDevice = false }
        }
    }

    private func requestDisconnect() {
        // Always go through ConnectionManager so transfer confirmation is unified
        // (including ⌘D / menu bar / connection list).
        if let serial = connMgr.activeEngine?.deviceSerial {
            connMgr.requestDisconnect(serial)
        }
    }
}
