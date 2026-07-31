import AppKit
import SwiftUI
import Combine
import ApplicationServices

@MainActor
final class MirrorControlPanel: ObservableObject {
    static let shared = MirrorControlPanel()

    @Published var isFollowing = true {
        didSet {
            guard oldValue != isFollowing else { return }
            if isFollowing {
                snapToMirrorWindow()
                ensureTracking()
            } else {
                stopTracking()
            }
        }
    }

    private var panel: NSPanel?
    private weak var scrcpy: ScrcpyController?
    private var serial: String?
    private var bag: Set<AnyCancellable> = []
    private var trackedPid: Int32 = 0

    private var axObserver: AXObserver?
    private var axWindow: AXUIElement?
    private var pollTimer: Timer?
    /// 1 Hz tick while recording so the elapsed label updates.
    private var recordingTickTimer: Timer?
    /// Prevents stacking adb screencap while one is already in flight.
    private var isCapturingScreenshot = false
    @Published private(set) var lastScreenshotMessage: String?
    /// Live `m:ss` (or `h:mm:ss`) while recording; empty when idle.
    @Published private(set) var recordingElapsedLabel: String = ""
    /// Last screenshot or recording path for “reveal in Finder”.
    private var lastMediaURL: URL?

    func show(for serial: String, deviceModel: String?, scrcpy: ScrcpyController) {
        if let existing = panel, existing.isVisible, self.serial == serial { return }
        hide()

        self.scrcpy = scrcpy
        self.serial = serial
        self.trackedPid = scrcpy.mirrorPids[serial] ?? 0
        self.isFollowing = true

        let view = MirrorControlBar(
            panel: self,
            onKey: { [weak self] key in self?.sendKey(key) },
            onScreenshot: { [weak self] in self?.screenshot() },
            onToggleRecord: { [weak self] in self?.toggleRecording() },
            onClose: { [weak self] in self?.close() }
        )

        // Room for launching spinner + recording elapsed label.
        let contentSize = NSSize(width: 48, height: 470)
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(origin: .zero, size: contentSize)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentView = hosting.view

        panel = p
        p.alphaValue = 0
        p.orderFrontRegardless()

        snapToMirrorWindow()
        ensureTracking()

        scrcpy.$runningSerials
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self, let serial = self.serial else { return }
                if !running.contains(serial) { self.hide() }
                self.objectWillChange.send()
            }
            .store(in: &bag)

        scrcpy.$launchingSerials
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        scrcpy.$launchStatusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self else { return }
                if self.isLaunching, let text, !text.isEmpty {
                    self.lastScreenshotMessage = text
                }
                self.objectWillChange.send()
            }
            .store(in: &bag)

        scrcpy.$mirrorPids
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pids in
                guard let self, let serial = self.serial, let pid = pids[serial] else { return }
                if pid != self.trackedPid {
                    self.trackedPid = pid
                    if self.isFollowing {
                        self.stopTracking()
                        self.ensureTracking()
                    }
                }
                // Mirror just became ready — clear “Starting…” status on the bar.
                if self.scrcpy?.isMirrorReady(serial: serial) == true {
                    let msg = self.lastScreenshotMessage ?? ""
                    if msg.hasPrefix("Starting") || msg.hasPrefix("Checking")
                        || msg == (self.scrcpy?.launchStatusText ?? "\u{0}") {
                        self.lastScreenshotMessage = nil
                    }
                }
                self.objectWillChange.send()
            }
            .store(in: &bag)

        scrcpy.$recordingSerials
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncRecordingTimer()
                self?.objectWillChange.send()
            }
            .store(in: &bag)

        if scrcpy.isLaunching(serial: serial) {
            lastScreenshotMessage = scrcpy.launchStatusText
                ?? String(localized: "Starting mirror…")
        }

        scrcpy.$lastRecordingURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, let url else { return }
                self.lastMediaURL = url
                self.lastScreenshotMessage = String(localized: "Recording saved — click to reveal")
                self.objectWillChange.send()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if self.lastScreenshotMessage == String(localized: "Recording saved — click to reveal") {
                        self.lastScreenshotMessage = nil
                    }
                }
            }
            .store(in: &bag)

        scrcpy.$recordingError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] msg in
                self?.lastScreenshotMessage = msg
                self?.objectWillChange.send()
            }
            .store(in: &bag)

        syncRecordingTimer()
    }

    var isRecording: Bool {
        guard let serial else { return false }
        return scrcpy?.recordingSerials.contains(serial) ?? false
    }

    /// True while inject probe / openApplication is still running.
    var isLaunching: Bool {
        guard let serial else { return false }
        return scrcpy?.isLaunching(serial: serial) ?? false
    }

    /// Keys / screenshot / record only once scrcpy process is up.
    var isMirrorReady: Bool {
        guard let serial else { return false }
        return scrcpy?.isMirrorReady(serial: serial) ?? false
    }

    /// Exposed for the control bar (busy camera icon).
    var isCapturingUI: Bool { isCapturingScreenshot }

    private func toggleRecording() {
        guard let serial else { return }
        if isRecording {
            let sessionRec = scrcpy?.isSessionRecording(serial: serial) == true
            scrcpy?.stopRecording(serial: serial)
            stopRecordingTick()
            recordingElapsedLabel = ""
            lastScreenshotMessage = sessionRec
                ? String(localized: "Stopping mirror to save…")
                : String(localized: "Saving recording…")
            objectWillChange.send()
            return
        }
        guard isMirrorReady else { return }
        guard scrcpy?.startRecording(serial: serial) == true else {
            lastScreenshotMessage = String(localized: "Could not start recording")
            objectWillChange.send()
            return
        }
        syncRecordingTimer()
        let cap = ScrcpyController.adbScreenRecordTimeLimitLabel
        lastScreenshotMessage = String(localized: "Live clip… max \(cap) — tap to stop")
        objectWillChange.send()
    }

    private func syncRecordingTimer() {
        if isRecording {
            tickRecordingElapsed()
            startRecordingTick()
        } else {
            stopRecordingTick()
            recordingElapsedLabel = ""
        }
    }

    private func startRecordingTick() {
        guard recordingTickTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRecordingElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTickTimer = timer
    }

    private func stopRecordingTick() {
        recordingTickTimer?.invalidate()
        recordingTickTimer = nil
    }

    private func tickRecordingElapsed() {
        guard let serial, let scrcpy else {
            recordingElapsedLabel = ""
            return
        }
        // Auto-stop at adb screenrecord hard limit (3 minutes).
        if scrcpy.stopRecordingIfTimeLimitReached(serial: serial) {
            stopRecordingTick()
            recordingElapsedLabel = ""
            lastScreenshotMessage = String(localized: "3-minute limit — saving…")
            objectWillChange.send()
            return
        }
        if let label = scrcpy.recordingElapsedString(for: serial) {
            recordingElapsedLabel = label
            if scrcpy.isSessionRecording(serial: serial) {
                lastScreenshotMessage = String(localized: "Session rec \(label) — stop mirror to save")
            } else if let left = scrcpy.recordingRemainingSeconds(for: serial), left <= 30 {
                lastScreenshotMessage = String(localized: "Live clip \(label) — \(left)s left")
            } else if scrcpy.isAdbCappedRecording(serial: serial) {
                let cap = ScrcpyController.adbScreenRecordTimeLimitLabel
                lastScreenshotMessage = String(localized: "Live clip \(label) / \(cap)")
            } else {
                lastScreenshotMessage = String(localized: "Recording \(label) — tap to stop")
            }
        } else {
            recordingElapsedLabel = ""
        }
        objectWillChange.send()
    }

    func hide() {
        stopTracking()
        stopRecordingTick()
        panel?.orderOut(nil)
        panel = nil
        bag.removeAll()
        serial = nil
        trackedPid = 0
        recordingElapsedLabel = ""
    }

    // MARK: - Tracking (CGWindowList only — no Accessibility permission)

    /// Follow the scrcpy window using public CGWindowList APIs only.
    /// We intentionally **do not** use AXObserver / Accessibility: that triggers
    /// the “control your computer” system prompt on first mirror open.
    private func ensureTracking() {
        if pollTimer != nil { return }
        startPollTimer()
    }

    private func stopTracking() {
        // Tear down any legacy AX observer from older builds.
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
            self.axObserver = nil
        }
        axWindow = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPollTimer() {
        pollTimer?.invalidate()
        // 12 Hz is smooth enough for the floating bar and cheap on CPU.
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.snapToMirrorWindow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Positioning

    private func snapToMirrorWindow() {
        guard isFollowing, let panel else { return }
        guard let mirrorFrame = currentMirrorFrame() else {
            // Keep bar visible near mouse-less default if window not found yet.
            if panel.alphaValue == 0, let screen = NSScreen.main {
                let p = NSPoint(
                    x: screen.visibleFrame.maxX - panel.frame.width - 24,
                    y: screen.visibleFrame.midY - panel.frame.height / 2
                )
                panel.setFrameOrigin(p)
                panel.alphaValue = 1
            }
            return
        }
        let gap: CGFloat = 6
        let x = mirrorFrame.maxX + gap
        let y = mirrorFrame.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if panel.alphaValue == 0 { panel.alphaValue = 1 }
    }

    private func currentMirrorFrame() -> NSRect? {
        // Prefer tracked scrcpy pid; also match by window title prefix.
        if trackedPid != 0, let f = windowFrame(forPid: trackedPid) { return f }
        return windowFrameMatchingMirrorTitle()
    }

    private func windowFrame(forPid pid: Int32) -> NSRect? {
        guard let array = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for info in array {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32, ownerPid == pid else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            if let rect = Self.cocoaRect(fromCGWindowBounds: bounds), rect.width > 100, rect.height > 100 {
                return rect
            }
        }
        return nil
    }

    /// Fallback when pid is stale: find a window titled "DroidMate · …".
    private func windowFrameMatchingMirrorTitle() -> NSRect? {
        guard let array = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for info in array {
            let name = info[kCGWindowName as String] as? String ?? ""
            guard name.hasPrefix("DroidMate") || name.localizedCaseInsensitiveContains("scrcpy") else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            if let rect = Self.cocoaRect(fromCGWindowBounds: bounds), rect.width > 100, rect.height > 100 {
                return rect
            }
        }
        return nil
    }

    /// Convert CGWindow bounds (global, top-left origin at primary display)
    /// to Cocoa screen coordinates (global, bottom-left origin). Uses the
    /// primary screen (`frame.origin == .zero`), not `NSScreen.main`, so the
    /// floating control bar tracks correctly on secondary displays.
    private static func cocoaRect(fromCGWindowBounds bounds: [String: CGFloat]) -> NSRect? {
        let w = bounds["Width"] ?? 0
        let h = bounds["Height"] ?? 0
        guard w > 0, h > 0 else { return nil }
        let x = bounds["X"] ?? 0
        let yTop = bounds["Y"] ?? 0
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        guard let primary else { return nil }
        let cocoaY = primary.frame.maxY - yTop - h
        return NSRect(x: x, y: cocoaY, width: w, height: h)
    }

    private func sendKey(_ keycode: String) {
        guard let serial, isMirrorReady else { return }
        scrcpy?.sendKey(serial: serial, keycode: keycode)
    }

    private func close() {
        guard let serial else { return }
        scrcpy?.stop(serial: serial)
        hide()
    }

    private func screenshot() {
        guard let serial, isMirrorReady, !isCapturingScreenshot else { return }
        isCapturingScreenshot = true
        lastScreenshotMessage = String(localized: "Capturing…")
        objectWillChange.send()

        AdbBridge.shared.screenshotAsync(serial: serial, saveToDownloads: true) { [weak self] result in
            guard let self else { return }
            self.isCapturingScreenshot = false
            switch result {
            case .success(let url):
                if let url {
                    self.lastScreenshotMessage = String(localized: "Saved — click to reveal")
                    self.lastMediaURL = url
                    NSSound(named: "Glass")?.play()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.5))
                        if self.lastScreenshotMessage == String(localized: "Saved — click to reveal") {
                            self.lastScreenshotMessage = nil
                        }
                    }
                } else {
                    self.lastScreenshotMessage = nil
                }
            case .failure:
                self.lastScreenshotMessage = String(localized: "Screenshot failed")
                NSSound.beep()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    if self.lastScreenshotMessage == String(localized: "Screenshot failed") {
                        self.lastScreenshotMessage = nil
                    }
                }
            }
            self.objectWillChange.send()
        }
    }
}

    private struct MirrorControlBar: View {
        @ObservedObject var panel: MirrorControlPanel
        let onKey: (String) -> Void
        let onScreenshot: () -> Void
        let onToggleRecord: () -> Void
        let onClose: () -> Void
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var recPulse = false

        var body: some View {
            VStack(spacing: DM.Space.sm) {
                if panel.isLaunching {
                    VStack(spacing: 2) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                        Text(String(localized: "…"))
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .help(panel.lastScreenshotMessage ?? String(localized: "Starting mirror…"))
                    .accessibilityLabel(String(localized: "Starting mirror…"))
                    barDivider
                }

                keyBtn("arrow.left", "KEYCODE_BACK", String(localized: "Back"))
                keyBtn("house.fill", "KEYCODE_HOME", String(localized: "Home"))
                keyBtn("square.fill", "KEYCODE_APP_SWITCH", String(localized: "Recents"))
                keyBtn("power", "KEYCODE_POWER", String(localized: "Power"))
                barDivider
                keyBtn("speaker.wave.2.fill", "KEYCODE_VOLUME_UP", String(localized: "Volume Up"))
                keyBtn("speaker.wave.1.fill", "KEYCODE_VOLUME_DOWN", String(localized: "Volume Down"))

                Button(action: onScreenshot) {
                    Image(systemName: panel.isCapturingUI ? "camera.fill" : "camera")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .opacity(panel.isCapturingUI || !panel.isMirrorReady ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(panel.isCapturingUI || !panel.isMirrorReady)
                .help(panel.lastScreenshotMessage
                      ?? String(localized: "Screenshot → Downloads (Finder opens)"))
                .accessibilityLabel(String(localized: "Screenshot"))

                Button(action: onToggleRecord) {
                    VStack(spacing: 1) {
                        Image(systemName: panel.isRecording ? "record.circle.fill" : "record.circle")
                            .frame(width: 28, height: 28)
                            .foregroundStyle(panel.isRecording ? Color.red : Color.primary)
                            .opacity(panel.isMirrorReady || panel.isRecording ? 1 : 0.45)
                            .scaleEffect(panel.isRecording && recPulse && !reduceMotion ? 1.08 : 1.0)
                        if panel.isRecording {
                            Text(panel.recordingElapsedLabel.isEmpty ? "0:00" : panel.recordingElapsedLabel)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(width: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!panel.isMirrorReady && !panel.isRecording)
                .help(recordHelp)
                .accessibilityLabel(panel.isRecording
                                    ? String(localized: "Stop recording")
                                    : String(localized: "Start recording"))
                .onChange(of: panel.isRecording) { _, on in
                    if on, !reduceMotion {
                        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                            recPulse = true
                        }
                    } else {
                        recPulse = false
                    }
                }

                barDivider

                Button(action: { panel.isFollowing.toggle() }) {
                    Image(systemName: panel.isFollowing ? "pin.fill" : "pin.slash")
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                                .fill(panel.isFollowing ? Color.primary.opacity(0.12) : Color.clear)
                        )
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .help(panel.isFollowing
                      ? String(localized: "Following mirror — click to unpin")
                      : String(localized: "Free float — click to pin to mirror"))
                .accessibilityLabel(panel.isFollowing
                                    ? String(localized: "Unpin from mirror")
                                    : String(localized: "Pin to mirror"))

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .help(panel.isLaunching
                      ? String(localized: "Cancel starting mirror")
                      : String(localized: "Stop mirror"))
                .accessibilityLabel(panel.isLaunching
                                    ? String(localized: "Cancel")
                                    : String(localized: "Stop mirror"))
            }
            .padding(.vertical, DM.Space.md)
            .padding(.horizontal, DM.Space.sm)
            .frame(width: 48)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .strokeBorder(DM.cardStroke, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }

        private var barDivider: some View {
            Divider().frame(width: 22)
        }

        private var recordHelp: String {
            if panel.isRecording {
                let t = panel.recordingElapsedLabel.isEmpty ? "0:00" : panel.recordingElapsedLabel
                return String(localized: "Stop recording (\(t)) → save & reveal")
            }
            if !panel.isMirrorReady {
                return String(localized: "Wait for mirror to start")
            }
            let cap = ScrcpyController.adbScreenRecordTimeLimitLabel
            return String(localized: "Live clip while mirroring (Android max \(cap)). For longer video: Start Mirror & Record.")
        }

        private func keyBtn(_ symbol: String, _ keycode: String, _ help: String) -> some View {
            Button(action: { onKey(keycode) }) {
                Image(systemName: symbol)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .opacity(panel.isMirrorReady ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!panel.isMirrorReady)
            .help(panel.isMirrorReady ? help : String(localized: "Wait for mirror to start"))
            .accessibilityLabel(help)
        }
    }
