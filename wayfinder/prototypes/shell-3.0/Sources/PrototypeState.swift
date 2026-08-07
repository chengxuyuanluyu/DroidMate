import SwiftUI

/// In-memory only. PROTOTYPE — wipe me.
@MainActor
@Observable
final class PrototypeState {
    enum RootMode: String {
        case connection
        case session
    }

    var mode: RootMode = .connection
    var devices = Fixtures.devices
    var activeDeviceID: String? = "usb-pixel"
    var path: String = "/Download"
    var entries: [ProtoEntry] = Fixtures.entries(for: "/Download")
    var selectedIDs: Set<String> = []
    var isNavigating = false
    var showInspector = true
    var showTransfers = false
    var showMirrorPanel = false
    var showCommandPalette = false
    var statusNote = "Prototype · fixture data · no adb"

    var activeDevice: ProtoDevice? {
        devices.first { $0.id == activeDeviceID }
    }

    var selectedEntry: ProtoEntry? {
        guard let id = selectedIDs.first else { return nil }
        return entries.first { $0.id == id }
    }

    func connect(to device: ProtoDevice) {
        activeDeviceID = device.id
        path = "/Download"
        entries = Fixtures.entries(for: path)
        selectedIDs = []
        mode = .session
        statusNote = "Connected · \(device.name) (fixture)"
    }

    func disconnectToWorkbench() {
        mode = .connection
        showTransfers = false
        showMirrorPanel = false
        statusNote = "Disconnected · back to connection workbench"
    }

    func selectDevice(_ id: String) {
        activeDeviceID = id
        path = "/Download"
        entries = Fixtures.entries(for: path)
        selectedIDs = []
        if let d = devices.first(where: { $0.id == id }) {
            statusNote = d.online ? "Active · \(d.name)" : "Failed · \(d.name) · tap reconnect"
        }
    }

    func openLocation(_ name: String) {
        navigate(to: "/\(name)")
    }

    func navigate(to newPath: String) {
        isNavigating = true
        statusNote = "Opening \(newPath)…"
        // Fake latency so the Opening chip is visible (P2 feedback, not data SLA).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            path = newPath
            entries = Fixtures.entries(for: newPath)
            selectedIDs = []
            isNavigating = false
            statusNote = path
        }
    }

    func openEntry(_ entry: ProtoEntry) {
        if entry.isDir {
            let next = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
            navigate(to: next)
        } else {
            selectedIDs = [entry.id]
        }
    }

    func toggleSelect(_ entry: ProtoEntry) {
        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
    }
}
