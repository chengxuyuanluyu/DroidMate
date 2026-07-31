import AppKit
import Combine
import os

private let log = Logger(subsystem: "com.droidmate", category: "ClipboardBridge")

/// Mac-side NSPasteboard ↔ Android clipboard bridge.
///
/// Polls `NSPasteboard.changeCount` at 500ms intervals (NSPasteboard has no
/// native KVO). On local change → sends CLIPBOARD_SYNC to Android. On inbound
/// CLIPBOARD_SYNC from Android → writes to NSPasteboard with echo suppression
/// so the next poll doesn't re-send the same text back.
///
/// See docs/PROTOCOL.md §7 for the wire format and echo-suppression contract.
@MainActor
final class ClipboardBridge: ObservableObject {

    /// Last direction: text we sent or received, for client-side dedup.
    private var lastSyncedText: String?

    /// Echo flag: set BEFORE we write to NSPasteboard from an inbound sync.
    /// Cleared by the next poll that observes the resulting changeCount bump.
    private var suppressNextLocalPoll: Bool = false
    private var echoFlagSetAt: Date = .distantPast

    private var lastChangeCount: Int = 0
    private var pollTask: Task<Void, Never>?
    private var transport: TransportClient?

    /// Outbound debounce per PROTOCOL.md §7.2 (200ms). When the user does
    /// rapid consecutive copies, only the last text within a 200ms window ships.
    private var pendingSendText: String?
    private var sendDebounceTask: Task<Void, Never>?

    /// Direction toggles (bound to @AppStorage in SettingsView).
    var macToAndroid: Bool {
        UserDefaults.standard.object(forKey: "clipboard.mac_to_android") as? Bool ?? true
    }
    var androidToMac: Bool {
        UserDefaults.standard.object(forKey: "clipboard.android_to_mac") as? Bool ?? true
    }

    func bind(transport: TransportClient) {
        self.transport = transport
        transport.setClipboardHandler { [weak self] frame in
            await self?.handleInbound(frame)
        }
        log.info("bound to transport")
    }

    func start() {
        guard pollTask == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        log.info("polling started, macToAndroid=\(self.macToAndroid) androidToMac=\(self.androidToMac)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.pollOnce()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        sendDebounceTask?.cancel()
        sendDebounceTask = nil
        pendingSendText = nil
        suppressNextLocalPoll = false
        log.info("polling stopped")
    }

    // MARK: - Outbound (Mac → Android)

    private func pollOnce() async {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if suppressNextLocalPoll,
           Date().timeIntervalSince(echoFlagSetAt) < 1.0 {
            suppressNextLocalPoll = false
            log.debug("echo suppressed (post-inbound)")
            return
        }
        suppressNextLocalPoll = false

        guard macToAndroid else {
            log.debug("skip outbound: macToAndroid=false")
            return
        }

        let text = (pb.string(forType: .string) ?? "")
        if text == lastSyncedText {
            log.debug("skip outbound: dedup (text == lastSyncedText)")
            return
        }

        let capped = String(text.prefix(1_000_000))
        scheduleSend(capped)
    }

    private func scheduleSend(_ text: String) {
        pendingSendText = text
        sendDebounceTask?.cancel()
        sendDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            guard let toSend = self.pendingSendText else { return }
            self.pendingSendText = nil

            let preview = String(toSend.prefix(40))
            log.info("local copy → android (len=\(toSend.count) preview=\"\(preview, privacy: .public))")
            self.lastSyncedText = toSend
            let payload = ClipboardPayload(
                ts: Int64(Date().timeIntervalSince1970 * 1000),
                source: "mac",
                mime: "text/plain",
                text: toSend
            )
            await self.transport?.sendClipboardSync(payload)
        }
    }

    // MARK: - Inbound (Android → Mac)

    private func handleInbound(_ frame: Frame) async {
        guard frame.msgType == MsgType.clipboardSync else { return }
        guard androidToMac else {
            log.debug("skip inbound: androidToMac=false")
            return
        }
        guard let payload = try? WireJSON.decoder.decode(ClipboardPayload.self,
                                                         from: frame.payload)
        else {
            log.warning("inbound decode failed, len=\(frame.payload.count)")
            return
        }

        if payload.text == lastSyncedText {
            log.debug("skip inbound: dedup")
            return
        }
        lastSyncedText = payload.text

        let preview = String(payload.text.prefix(40))
        log.info("← android copy (len=\(payload.text.count) preview=\"\(preview, privacy: .public)\")")

        suppressNextLocalPoll = true
        echoFlagSetAt = Date()

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload.text, forType: .string)
        lastChangeCount = pb.changeCount
    }
}
