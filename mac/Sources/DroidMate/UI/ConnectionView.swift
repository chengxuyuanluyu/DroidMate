import SwiftUI

/// Connection / add-device workspace.
///
/// Layout: short top bar + two-column main stage (devices | connection method).
/// Left column is width-capped; right column takes remaining space and scrolls
/// so the Wi-Fi form never requires resizing the window. The single auto-connect
/// trigger lives here and is guarded by `isConnecting` — this is the ONLY place
/// that calls `ConnectionManager.addDevice(serial:)`.
struct ConnectionView: View {
    @ObservedObject var connMgr: ConnectionManager

    @State private var devices: [String] = []
    @State private var allDevices: [AdbBridge.DeviceInfo] = []
    @State private var adbPath: String?
    @State private var errorMessage: String?
    /// Last failed connect target so Retry re-runs the same action.
    @State private var lastFailedConnectSerial: String?
    @State private var isConnecting = false
    @State private var connectingSerial: String?
    @State private var connectingStage: String?
    @StateObject private var wifi = ConnectionWifiState()
    @State private var isInstallingAdb = false
    @State private var hasBrew = false
    @State private var showSetupGuide = false
    /// LAN wireless-debug connect ports from `adb mdns services`.
    @State private var mdnsWifi: [AdbBridge.WifiEndpoint] = []
    /// At least one mDNS poll finished (for empty-state copy).
    @State private var mdnsDidScan = false
    /// Cached `ro.product.model` by serial.
    @State private var modelBySerial: [String: String] = [:]
    /// Cached USB LAN IP for merging USB + Wi-Fi rows.
    @State private var usbIpBySerial: [String: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Divider()
                    if let errorMessage {
                        inlineError(errorMessage)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                    if wide {
                        wideLayout
                    } else {
                        narrowLayout
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            refreshAdb()
            refreshDevices()
            wifi.recent = AdbBridge.shared.recentWifiEndpoints()
            refreshMdns()
        }
        .onChange(of: wifi.pairAddr) { _, new in
            // Wizard: seed connect host only (port left for main-screen value).
            syncWifiHost(from: new, into: &wifi.connectAddr, hostOnly: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshDevices)) { _ in
            refreshDevices()
            refreshMdns()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !isConnecting else { continue }
                let found = await Task.detached(priority: .utility) { () -> [AdbBridge.DeviceInfo] in
                    (try? AdbBridge.shared.listAllDevicesWithState()) ?? []
                }.value
                let serials = found.filter(\.isReady).map(\.serial)
                if serials != devices { devices = serials }
                if found != allDevices {
                    allDevices = found
                    enrichDeviceMetadata(for: found)
                }
            }
        }
        .task {
            // mDNS is slower / flaky under load — poll a bit less often than adb devices.
            while !Task.isCancelled {
                refreshMdns()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: devices) { _, newDevices in
            tryAutoConnect(from: newDevices)
        }
        .onChange(of: allDevices) { _, new in
            enrichDeviceMetadata(for: new)
        }
        // After user confirms transfer-blocking disconnect, refresh left list / status.
        .onChange(of: connMgr.pendingDisconnectSerials) { old, new in
            if !old.isEmpty && new.isEmpty {
                refreshDevices()
            }
        }
        .onChange(of: connMgr.engines.count) { old, new in
            if new < old {
                refreshDevices()
            }
        }
    }

    /// Grouped left-list rows (USB + matching Wi-Fi collapsed).
    private var deviceGroups: [ConnectionDeviceGroup] {
        ConnectionDeviceGrouping.groups(
            devices: allDevices,
            modelBySerial: modelBySerial,
            usbIpBySerial: usbIpBySerial
        )
    }

    // MARK: - Top bar (replaces large hero)

    private var topBar: some View {
        HStack(spacing: DM.Space.md) {
            BrandMark(size: 36, systemImage: "iphone.gen3.radiowaves.left.and.right")

            VStack(alignment: .leading, spacing: 2) {
                Text("DroidMate")
                    .font(.headline.weight(.semibold))
                Text("Plug in your phone — no app install needed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DM.Space.md)

            adbStatusPill
        }
        .padding(.horizontal, DM.Space.xl)
        .padding(.vertical, DM.Space.md)
        .background(.ultraThinMaterial)
    }

    /// Compact ADB status — expands actions only when missing.
    private var adbStatusPill: some View {
        HStack(spacing: 8) {
            Image(systemName: adbPath != nil
                  ? "checkmark.circle.fill"
                  : "exclamationmark.triangle.fill")
                .foregroundStyle(adbPath != nil ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text("ADB")
                    .font(.caption.weight(.semibold))
                if let adbPath {
                    Text(adbPath.contains("Application Support") ? "Built-in" : adbPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .leading)
                } else if isInstallingAdb {
                    Text("Installing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not found")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if adbPath == nil && !isInstallingAdb && hasBrew {
                Button("Install") { installAdb() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if isInstallingAdb {
                ProgressView().controlSize(.small)
            }
            Button {
                refreshAdb()
                refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh ADB and devices")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                .fill(DM.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                .strokeBorder(DM.cardStroke, lineWidth: 0.5)
        )
    }

    // MARK: - Wide (≥700): devices (capped) | method (flex + scroll)

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: device list — width-capped so empty space goes to the form.
            ScrollView {
                devicesPaneContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 340)
            .frame(maxHeight: .infinity)

            Divider()

            // Right: connection method — takes remaining width; scrolls when tall.
            ScrollView {
                methodPaneContent
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Narrow: stacked, single scroll

    private var narrowLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                devicesPaneContent
                methodPaneContent
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Devices pane

    private var devicesPaneContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Devices")
                    .font(.title3.weight(.semibold))
                Spacer()
                if allDevices.isEmpty {
                    Text("None detected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(deviceGroups.count) found")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if allDevices.isEmpty {
                emptyDevices
            } else {
                VStack(spacing: 8) {
                    ForEach(deviceGroups) { group in
                        if group.isReady {
                            let inSession = group.serials.contains { s in
                                connMgr.engines.contains { $0.deviceSerial == s }
                            }
                            let rowConnecting = isConnecting
                                && group.serials.contains(where: { $0 == connectingSerial })
                            ConnectionDeviceRow(
                                title: group.title,
                                detail: group.detail,
                                systemImage: group.systemImage,
                                linkLabel: group.linkLabel,
                                isSelected: connectingSerial.map { group.serials.contains($0) } ?? false
                                    || group.serials.contains { $0 == connMgr.activeDeviceId },
                                isRowConnecting: rowConnecting,
                                isConnected: inSession,
                                isDisabled: isConnecting || wifi.isBusy,
                                connectingStage: rowConnecting ? connectingStage : nil,
                                onConnect: {
                                    if let existing = group.serials.first(where: { s in
                                        connMgr.engines.contains { $0.deviceSerial == s }
                                    }) {
                                        connMgr.switchTo(existing)
                                    } else {
                                        connectingSerial = group.connectSerial
                                        connect(to: group.connectSerial)
                                    }
                                },
                                onDisconnect: {
                                    disconnectDeviceGroup(group)
                                },
                                alwaysShowDisconnect: group.hasWireless || inSession
                            )
                        } else if let first = allDevices.first(where: { group.serials.contains($0.serial) }) {
                            ConnectionUnauthorizedRow(
                                device: first,
                                title: group.title == first.serial ? nil : group.title,
                                showSetupGuide: $showSetupGuide
                            )
                        }
                    }
                }
            }

            if isConnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(connectingStage ?? String(localized: "Connecting to device…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 2)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? AppSpring.crossfade : AppSpring.standard, value: isConnecting)
        .animation(reduceMotion ? AppSpring.crossfade : AppSpring.standard, value: allDevices.count)
    }

    private var emptyDevices: some View {
        VStack(spacing: DM.Space.md) {
            ZStack {
                Circle()
                    .fill(DM.Brand.softFill)
                    .frame(width: 64, height: 64)
                Image(systemName: "cable.connector")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(DM.Brand.iconOnDark)
            }
            Text("No devices detected")
                .font(.subheadline.weight(.semibold))
            Text("Plug in your phone over USB and enable USB debugging in Developer Options.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DM.Space.lg)
        .padding(.vertical, DM.Space.xl)
        .background(
            RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                .fill(DM.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                .strokeBorder(DM.cardStroke, lineWidth: 0.5)
        )
    }

    // MARK: - Method pane (situational Wi-Fi / USB home)

    private var methodPaneContent: some View {
        ConnectionWifiPane(
            usbReadySerials: usbReadySerials,
            onlineWirelessSerials: onlineWirelessSerials,
            pairAddr: $wifi.pairAddr,
            pairCode: $wifi.pairCode,
            connectAddr: $wifi.connectAddr,
            recentWifi: wifi.recent,
            mdnsWifi: mdnsWifi,
            mdnsDidScan: mdnsDidScan,
            isWifiBusy: wifi.isBusy,
            isConnecting: isConnecting,
            wifiStatus: wifi.status,
            wifiStatusOK: wifi.statusOK,
            onEnableWirelessFromUSB: { enableWirelessFromUSB(serial: $0) },
            onPairOnly: { pairOnly() },
            onConnectOnly: { connectOnly() },
            onReconnect: { reconnectWifi($0) },
            onOpenOnline: { serial in
                connectingSerial = serial
                connect(to: serial)
            },
            onRemoveRecent: { ep in
                AdbBridge.shared.removeRecentWifiEndpoint(ep)
                wifi.recent = AdbBridge.shared.recentWifiEndpoints()
            },
            onClearRecent: {
                AdbBridge.shared.clearRecentWifiEndpoints()
                wifi.recent = []
            },
            wizardPairSucceeded: wifi.wizardPairSucceeded,
            wizardSessionReady: wifi.wizardSessionReady,
            onConsumeWizardPair: { wifi.wizardPairSucceeded = false },
            onConsumeWizardSession: { wifi.wizardSessionReady = false }
        )
    }

    /// USB-connected ready devices not already `host:port` serials.
    private var usbReadySerials: [String] {
        allDevices.filter(\.isReady).map(\.serial).filter { !$0.contains(":") }
    }

    /// Wireless serials currently visible to adb (`host:port`).
    private var onlineWirelessSerials: [String] {
        allDevices.filter(\.isReady).map(\.serial).filter { $0.contains(":") }
    }

    private func refreshMdns() {
        Task {
            let found = await Task.detached(priority: .utility) { () -> [AdbBridge.WifiEndpoint] in
                AdbBridge.shared.listMdnsConnectEndpoints()
            }.value
            // Stable order for SwiftUI diff
            let sorted = found.sorted { $0.display < $1.display }
            if sorted != mdnsWifi { mdnsWifi = sorted }
            if !mdnsDidScan { mdnsDidScan = true }
        }
    }

    /// Best-effort model + USB IP for friendly names and USB↔Wi-Fi merge.
    private func enrichDeviceMetadata(for devices: [AdbBridge.DeviceInfo]) {
        let ready = devices.filter(\.isReady).map(\.serial)
        Task.detached(priority: .utility) {
            var models: [String: String] = [:]
            var ips: [String: String] = [:]
            for serial in ready {
                if let model = AdbBridge.shared.getDeviceModel(serial: serial) {
                    models[serial] = model
                }
                if !serial.contains(":"), let ip = AdbBridge.shared.getDeviceIp(serial: serial) {
                    ips[serial] = ip
                }
            }
            await MainActor.run {
                if !models.isEmpty {
                    modelBySerial.merge(models) { _, new in new }
                }
                if !ips.isEmpty {
                    usbIpBySerial.merge(ips) { _, new in new }
                }
            }
        }
    }

    // MARK: - Error

    private func inlineError(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Button("Retry") {
                errorMessage = nil
                if let serial = lastFailedConnectSerial {
                    connect(to: serial)
                } else {
                    refreshDevices()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(lastFailedConnectSerial != nil
                  ? String(localized: "Retry the last failed connection")
                  : String(localized: "Refresh ADB and devices"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5)
                )
        )
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Actions

    private func installAdb() {
        isInstallingAdb = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try AdbLocator.shared.installAdb()
                }.value
                refreshAdb()
            } catch {
                errorMessage = String(localized: "Failed to install ADB: \(error.localizedDescription)")
            }
            isInstallingAdb = false
        }
    }

    private func refreshAdb() {
        adbPath = AdbLocator.shared.findAdb()
        hasBrew = AdbLocator.shared.findBrew() != nil
    }

    private func refreshDevices() {
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> (list: [String]?, all: [AdbBridge.DeviceInfo]?, error: String?) in
                do {
                    let all = try AdbBridge.shared.listAllDevicesWithState()
                    let list = all.filter(\.isReady).map(\.serial)
                    return (list, all, nil)
                } catch {
                    return (nil, nil, error.localizedDescription)
                }
            }.value
            if let list = outcome.list {
                devices = list
                if let all = outcome.all {
                    allDevices = all
                    enrichDeviceMetadata(for: all)
                }
                tryAutoConnect(from: list)
            } else if let err = outcome.error {
                devices = []
                errorMessage = err
            }
        }
    }

    private func tryAutoConnect(from list: [String]) {
        // Keep suppression in sync: if a serial left adb (unplug / adb disconnect),
        // allow auto-connect the next time it shows up.
        connMgr.syncAutoConnectSuppression(withPresentSerials: list)

        guard !isConnecting, connMgr.engines.isEmpty else { return }
        // Prefer last-used, then USB, then first wireless (never a suppressed row).
        guard let pick = connMgr.preferredAutoConnectSerial(from: list) else {
            return
        }
        connectingSerial = pick
        connect(to: pick)
    }

    private func connect(to serial: String) {
        guard !isConnecting else { return }
        isConnecting = true
        connectingSerial = serial
        connectingStage = String(localized: "Starting…")
        Task {
            do {
                try await connMgr.addDevice(serial: serial) { stage in
                    connectingStage = stage
                }
                // If user disconnected during connect, addDevice throws CancellationError
                // and we should not clear last-failed as success.
                lastFailedConnectSerial = nil
                errorMessage = nil
            } catch is CancellationError {
                // Intentional disconnect / cancel mid-connect — silent.
                errorMessage = nil
            } catch {
                lastFailedConnectSerial = serial
                errorMessage = error.localizedDescription
            }
            isConnecting = false
            if connectingSerial == serial {
                connectingSerial = nil
                connectingStage = nil
            }
        }
    }

    /// Left-list Disconnect for a merged group: all related serials + transfer confirm.
    private func disconnectDeviceGroup(_ group: ConnectionDeviceGroup) {
        if let connectingSerial, group.serials.contains(connectingSerial) {
            self.connectingSerial = nil
            isConnecting = false
            connectingStage = nil
        }
        let hadWireless = group.hasWireless
        connMgr.requestDisconnect(serials: group.serials)
        // If confirmation is pending, status updates after the user confirms.
        if connMgr.pendingDisconnectSerials.isEmpty {
            refreshDevices()
            if hadWireless {
                wifi.setStatus(true, String(localized: "Disconnected \(group.title)"))
            } else {
                wifi.setStatus(true, String(localized: "Session ended"))
            }
        }
    }

    private func pairOnly() {
        ConnectionWifiActions.pairOnly(state: wifi)
    }

    private func connectOnly() {
        ConnectionWifiActions.connectOnly(state: wifi, connMgr: connMgr) {
            errorMessage = $0
        }
    }

    private func reconnectWifi(_ endpoint: AdbBridge.WifiEndpoint) {
        ConnectionWifiActions.reconnect(endpoint, connMgr: connMgr, state: wifi)
    }

    private func enableWirelessFromUSB(serial: String) {
        ConnectionWifiActions.enableWirelessFromUSB(
            serial: serial,
            connMgr: connMgr,
            state: wifi,
            refreshDevices: { refreshDevices() }
        )
    }

    /// When pair field gets `host:port`, seed connect host (port left blank if `hostOnly`).
    private func syncWifiHost(from source: String, into target: inout String, hostOnly: Bool = false) {
        let host: String? = {
            if let ep = AdbBridge.WifiEndpoint.parse(source) { return ep.host }
            let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.contains(":"), let colon = s.lastIndex(of: ":") {
                let h = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
                return h.isEmpty ? nil : h
            }
            if !s.isEmpty, s.rangeOfCharacter(from: .whitespaces) == nil, s.contains(".") {
                return s
            }
            return nil
        }()
        guard let host else { return }
        if target.isEmpty {
            target = hostOnly ? "\(host):" : "\(host):"
            return
        }
        if let existing = AdbBridge.WifiEndpoint.parse(target) {
            if existing.host != host { return }
            return
        }
        if target.hasSuffix(":") || target == host || target.hasPrefix(host + ":") {
            if !target.contains(":") || target == "\(host):" {
                target = "\(host):"
            }
        }
    }
}
