import AppKit
import SwiftUI

// MARK: - Context-aware Wi-Fi method pane (P0 UX)

/// Right-hand connection method content: situational home + add-phone wizard.
///
/// Primary surface is chosen by what's easiest right now (USB → My phones → Add).
/// Pairing fields only appear inside the multi-step wizard.
struct ConnectionWifiPane: View {
    let usbReadySerials: [String]
    /// Wireless `host:port` serials currently listed by adb.
    let onlineWirelessSerials: [String]
    @Binding var pairAddr: String
    @Binding var pairCode: String
    @Binding var connectAddr: String
    let recentWifi: [AdbBridge.WifiEndpoint]
    /// mDNS `_adb-tls-connect` endpoints currently advertised on the LAN.
    let mdnsWifi: [AdbBridge.WifiEndpoint]
    let isWifiBusy: Bool
    let isConnecting: Bool
    let wifiStatus: String?
    let wifiStatusOK: Bool
    let onEnableWirelessFromUSB: (String) -> Void
    let onPairOnly: () -> Void
    let onConnectOnly: () -> Void
    let onReconnect: (AdbBridge.WifiEndpoint) -> Void
    /// Already-online wireless serial — open DroidMate without adb connect.
    let onOpenOnline: (String) -> Void
    var onRemoveRecent: ((AdbBridge.WifiEndpoint) -> Void)? = nil
    var onClearRecent: (() -> Void)? = nil
    /// Language-agnostic wizard signals from `ConnectionWifiActions` (not status text).
    var wizardPairSucceeded: Bool = false
    var wizardSessionReady: Bool = false
    var onConsumeWizardPair: (() -> Void)? = nil
    var onConsumeWizardSession: (() -> Void)? = nil

    @State private var showWizard = false
    @State private var wizardStep: WizardStep = .prepare
    @State private var pairSucceeded = false

    enum WizardStep: Int, CaseIterable {
        case prepare = 0
        case pair = 1
        case connect = 2
    }

    private var phones: [WifiPhoneRowModel] {
        WifiPhoneRowModel.build(
            onlineSerials: onlineWirelessSerials,
            recent: recentWifi,
            mdns: mdnsWifi
        )
    }

    private var hasUSB: Bool { !usbReadySerials.isEmpty }
    private var hasPhones: Bool { !phones.isEmpty }

    var body: some View {
        Group {
            if showWizard {
                addPhoneWizard
            } else {
                homeContent
            }
        }
        .onChange(of: wizardPairSucceeded) { _, ok in
            guard ok, showWizard, wizardStep == .pair else { return }
            pairSucceeded = true
            prefillConnectHostFromPair()
            withAnimation(AppSpring.standard) { wizardStep = .connect }
            onConsumeWizardPair?()
        }
        .onChange(of: wizardSessionReady) { _, ok in
            guard ok, showWizard else { return }
            withAnimation(AppSpring.standard) {
                showWizard = false
                pairSucceeded = false
                wizardStep = .prepare
            }
            onConsumeWizardSession?()
        }
    }

    // MARK: - Home

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.title3.weight(.semibold))

            if hasUSB {
                usbSwitchCard
            }

            if hasPhones {
                myPhonesCard
            }

            if !hasUSB && !hasPhones {
                emptyPrimaryCard
            }

            // Secondary entry — always available when not empty-primary-only clutter
            if hasUSB || hasPhones {
                Button {
                    openWizard()
                } label: {
                    Label("Add phone…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(isWifiBusy || isConnecting)
            }

            if let wifiStatus, !isWifiBusy || hasUSB {
                statusLine(wifiStatus, ok: wifiStatusOK)
            }
        }
    }

    private var emptyPrimaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add a phone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
            Text("No phones found yet. Keep Wireless debugging on and stay on the same Wi-Fi — or plug in USB (easiest).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Scanning this network…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                openWizard()
            } label: {
                Text("Add over Wi-Fi")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isWifiBusy || isConnecting)

            Text("Tip: With a USB cable you can switch to Wi-Fi in one tap after the phone appears on the left.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DM.Space.md)
        .methodCardChrome()
    }

    private var usbSwitchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Switch to Wi-Fi", systemImage: "cable.connector.horizontal")
                .font(.subheadline.weight(.semibold))
            Text("Phone is on USB. Keep the cable in for a few seconds — then you can unplug.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let usb = usbReadySerials.first {
                Button {
                    onEnableWirelessFromUSB(usb)
                } label: {
                    if isWifiBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(wifiStatus ?? "Working…")
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Switch to Wi-Fi")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isWifiBusy || isConnecting)

                if usbReadySerials.count > 1 {
                    Text("Uses \(usb). Other USB phones stay listed on the left.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(DM.Space.md)
        .methodCardChrome()
    }

    private var myPhonesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("My phones")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !recentWifi.isEmpty, let onClearRecent {
                    Button("Clear", action: onClearRecent)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(isWifiBusy || isConnecting)
                }
            }
            Text("Online, on this Wi-Fi, or recent — connect in one tap. No pairing code.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(phones) { phone in
                phoneRow(phone)
            }
        }
        .padding(DM.Space.md)
        .methodCardChrome()
    }

    private func phoneRow(_ phone: WifiPhoneRowModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: phone.source == .online
                  ? "wifi"
                  : (phone.source == .mdns ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath"))
                .foregroundStyle(phone.isOnline ? Color.green : (phone.source == .mdns ? Color.accentColor : Color.secondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(phone.title)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(phone.subtitle)
                    .font(.caption2)
                    .foregroundStyle(phone.isOnline ? Color.green : Color.secondary.opacity(0.8))
            }

            Spacer(minLength: 6)

            Button {
                if phone.isOnline {
                    onOpenOnline(phone.serialOrDisplay)
                } else if let ep = phone.endpoint {
                    onReconnect(ep)
                }
            } label: {
                Text(phone.isOnline ? "Open" : "Connect")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isWifiBusy || isConnecting)

            if let ep = phone.endpoint, let onRemoveRecent, !phone.isOnline || recentWifi.contains(ep) {
                Button {
                    onRemoveRecent(ep)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from recent")
                .disabled(isWifiBusy || isConnecting)
            }
        }
    }

    // MARK: - Wizard

    private func openWizard() {
        pairSucceeded = false
        wizardStep = .prepare
        showWizard = true
    }

    private var addPhoneWizard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(AppSpring.standard) {
                        showWizard = false
                        pairSucceeded = false
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(isWifiBusy)

                Spacer()
                Text("Add phone")
                    .font(.headline)
                Spacer()
                // balance trailing
                Color.clear.frame(width: 44, height: 1)
            }

            wizardProgress

            switch wizardStep {
            case .prepare:
                wizardPrepare
            case .pair:
                wizardPair
            case .connect:
                wizardConnect
            }

            if let wifiStatus {
                statusLine(wifiStatus, ok: wifiStatusOK)
            }
        }
        .padding(DM.Space.md)
        .methodCardChrome()
    }

    private var wizardProgress: some View {
        HStack(spacing: 6) {
            ForEach(WizardStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= wizardStep.rawValue ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(wizardStep.rawValue + 1) of 3")
    }

    private var wizardPrepare: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prepare the phone")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("Phone and Mac on the same Wi-Fi (turn off VPN if needed)", systemImage: "1.circle.fill")
                Label("Settings → Developer options → Wireless debugging → On", systemImage: "2.circle.fill")
                Label("Leave that screen open", systemImage: "3.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                withAnimation(AppSpring.standard) { wizardStep = .pair }
            } label: {
                Text("Next: Pair")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var wizardPair: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair (first time only)")
                .font(.subheadline.weight(.semibold))
            Text("On the phone tap “Pair device with pairing code”. Keep that sheet open until pairing finishes. The port here is not the main-screen port.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labeledField(title: "Pairing address", hint: "IP:port from the pairing sheet") {
                TextField("192.168.1.100:37123", text: $pairAddr)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }

            labeledField(title: "Pairing code", hint: "6-digit code on the same sheet") {
                TextField("123456", text: $pairCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }

            HStack(spacing: 8) {
                Button("Paste from clipboard") {
                    WifiPaste.apply(toPairAddr: &pairAddr, pairCode: &pairCode, connectAddr: &connectAddr)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWifiBusy)

                Spacer()
            }

            Button {
                pairSucceeded = false
                onPairOnly()
                // Optimistic advance is driven by status; also schedule check after action.
                Task { @MainActor in
                    // If parent sets success status quickly, onChange handles it.
                    // Fallback: user can still press Next manually is not shown — wait for status.
                }
            } label: {
                if isWifiBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(wifiStatus ?? "Pairing…")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Pair")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPair || isWifiBusy || isConnecting)

            if pairSucceeded {
                Button {
                    prefillConnectHostFromPair()
                    withAnimation(AppSpring.standard) { wizardStep = .connect }
                } label: {
                    Text("Next: Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var wizardConnect: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect")
                .font(.subheadline.weight(.semibold))
            Text("Close the pairing sheet. On the Wireless debugging main screen, copy “IP address & port” (different port from pairing).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labeledField(title: "Connection address", hint: "IP:port from the main screen — every reconnect uses this") {
                TextField("192.168.1.100:44609", text: $connectAddr)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }

            Button("Paste address") {
                WifiPaste.apply(toPairAddr: &pairAddr, pairCode: &pairCode, connectAddr: &connectAddr, preferConnect: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isWifiBusy)

            Button {
                onConnectOnly()
            } label: {
                if isWifiBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(wifiStatus ?? "Connecting…")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Connect & open")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canConnect || isWifiBusy || isConnecting)
        }
        .onAppear {
            prefillConnectHostFromPair()
        }
    }

    private var canPair: Bool {
        AdbBridge.WifiEndpoint.parse(pairAddr) != nil
            && pairCode.trimmingCharacters(in: .whitespaces).count >= 6
    }

    private var canConnect: Bool {
        AdbBridge.WifiEndpoint.parse(connectAddr) != nil
    }

    private func prefillConnectHostFromPair() {
        // Prefill host only; leave port empty so the user cannot reuse the pair port by accident.
        guard let pair = AdbBridge.WifiEndpoint.parse(pairAddr) else { return }
        if connectAddr.isEmpty {
            connectAddr = "\(pair.host):"
            return
        }
        if AdbBridge.WifiEndpoint.parse(connectAddr) == nil {
            // Incomplete field — refresh host prefix
            if connectAddr.hasSuffix(":") || !connectAddr.contains(":") {
                connectAddr = "\(pair.host):"
            }
        }
    }

    private func statusLine(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(ok ? .green : .red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labeledField<Content: View>(
        title: LocalizedStringKey,
        hint: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}

// MARK: - Row model

struct WifiPhoneRowModel: Identifiable, Hashable {
    enum Source: String, Hashable {
        case online
        case mdns
        case recent
    }

    let id: String
    let title: String
    let subtitle: String
    let isOnline: Bool
    let source: Source
    /// Serial for online open, or display string.
    let serialOrDisplay: String
    let endpoint: AdbBridge.WifiEndpoint?

    static func build(
        onlineSerials: [String],
        recent: [AdbBridge.WifiEndpoint],
        mdns: [AdbBridge.WifiEndpoint] = []
    ) -> [WifiPhoneRowModel] {
        var rows: [WifiPhoneRowModel] = []
        var seenExact = Set<String>()
        var seenHosts = Set<String>()

        for serial in onlineSerials {
            let key = serial.lowercased()
            guard seenExact.insert(key).inserted else { continue }
            let ep = AdbBridge.WifiEndpoint.parse(serial)
            if let host = ep?.host { seenHosts.insert(host.lowercased()) }
            rows.append(WifiPhoneRowModel(
                id: serial,
                title: serial,
                subtitle: String(localized: "Online · ready"),
                isOnline: true,
                source: .online,
                serialOrDisplay: serial,
                endpoint: ep
            ))
        }

        // LAN discovery (current connect port) — better than a stale Recent port.
        for ep in mdns {
            let key = ep.display.lowercased()
            let hostKey = ep.host.lowercased()
            if seenExact.contains(key) || seenHosts.contains(hostKey) { continue }
            seenExact.insert(key)
            seenHosts.insert(hostKey)
            rows.append(WifiPhoneRowModel(
                id: "mdns-\(ep.display)",
                title: ep.display,
                subtitle: String(localized: "On this Wi-Fi · tap to connect"),
                isOnline: false,
                source: .mdns,
                serialOrDisplay: ep.display,
                endpoint: ep
            ))
        }

        for ep in recent {
            let key = ep.display.lowercased()
            let hostKey = ep.host.lowercased()
            if seenExact.contains(key) || seenHosts.contains(hostKey) { continue }
            seenExact.insert(key)
            seenHosts.insert(hostKey)
            rows.append(WifiPhoneRowModel(
                id: ep.display,
                title: ep.display,
                subtitle: String(localized: "Recent · tap to connect"),
                isOnline: false,
                source: .recent,
                serialOrDisplay: ep.display,
                endpoint: ep
            ))
        }
        return rows
    }
}

// MARK: - Clipboard paste

enum WifiPaste {
    /// Parse clipboard for `IP:port` and optional 6-digit code.
    static func apply(
        toPairAddr pairAddr: inout String,
        pairCode: inout String,
        connectAddr: inout String,
        preferConnect: Bool = false
    ) {
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let ep = firstEndpoint(in: text) {
            if preferConnect {
                connectAddr = ep.display
            } else if pairAddr.isEmpty || AdbBridge.WifiEndpoint.parse(pairAddr) == nil {
                pairAddr = ep.display
            } else {
                connectAddr = ep.display
            }
        }

        if let code = firstPairCode(in: text), !preferConnect {
            pairCode = code
        }
    }

    static func firstEndpoint(in text: String) -> AdbBridge.WifiEndpoint? {
        // host:port anywhere in text
        let pattern = #"(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return AdbBridge.WifiEndpoint.parse(text)
        }
        let ns = text as NSString
        if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let host = ns.substring(with: m.range(at: 1))
            let port = ns.substring(with: m.range(at: 2))
            return AdbBridge.WifiEndpoint.parse("\(host):\(port)")
        }
        return AdbBridge.WifiEndpoint.parse(text)
    }

    static func firstPairCode(in text: String) -> String? {
        let pattern = #"\b(\d{6})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }
}

// MARK: - Chrome

private extension View {
    func methodCardChrome() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .strokeBorder(DM.cardStroke, lineWidth: 0.5)
            )
    }
}

// MARK: - USB tip (left empty / cable-first messaging on method pane when needed)

/// Compact USB guidance when user is not in the Wi-Fi wizard (shown when no situational Wi-Fi UI needs space).
struct ConnectionUSBHelp: View {
    let usbReadySerials: [String]
    let isWifiBusy: Bool
    let isConnecting: Bool
    let wifiStatus: String?
    let wifiStatusOK: Bool
    let onEnableWirelessFromUSB: (String) -> Void

    var body: some View {
        // Retained for any external reference; primary USB switch lives in ConnectionWifiPane.
        VStack(alignment: .leading, spacing: 8) {
            Label("USB", systemImage: "cable.connector")
                .font(.caption.weight(.semibold))
            Text("Plug in, unlock, accept the debugging prompt. Devices appear on the left.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let usb = usbReadySerials.first {
                Button {
                    onEnableWirelessFromUSB(usb)
                } label: {
                    if isWifiBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Switch \(usb) to Wi-Fi", systemImage: "wifi")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWifiBusy || isConnecting)
            }
            if let wifiStatus {
                Text(wifiStatus)
                    .font(.caption)
                    .foregroundStyle(wifiStatusOK ? .green : .red)
            }
        }
        .padding(DM.Space.md)
        .methodCardChrome()
    }
}
