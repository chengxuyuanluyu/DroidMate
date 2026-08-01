import Foundation

/// One physical phone as shown on the connection workspace left list.
/// USB + wireless adb of the same handset are merged when the USB IP matches
/// a `host:port` serial.
struct ConnectionDeviceGroup: Identifiable, Equatable, Hashable {
    /// Stable id — primary serial (USB preferred when both present).
    let id: String
    /// Friendly title (model) when known; otherwise primary serial.
    let title: String
    /// Secondary line under the title (serial / endpoint detail).
    let detail: String
    /// All adb serials in this group (USB and/or Wi-Fi).
    let serials: [String]
    /// Preferred serial to open a DroidMate session (USB first, else Wi-Fi).
    let connectSerial: String
    let hasUSB: Bool
    let hasWireless: Bool
    /// True when every serial in the group is adb-ready (`device`).
    let isReady: Bool
    /// Raw state for unauthorized/offline single-serial groups.
    let state: String

    var isWirelessOnly: Bool { hasWireless && !hasUSB }

    /// Icon: wifi-only → wifi; else phone (USB or dual).
    var systemImage: String {
        isWirelessOnly ? "wifi" : "iphone"
    }

    /// e.g. "USB · Wi-Fi", "USB", "Wi-Fi".
    var linkLabel: String {
        switch (hasUSB, hasWireless) {
        case (true, true):
            return String(localized: "USB · Wi-Fi")
        case (true, false):
            return String(localized: "USB")
        case (false, true):
            return String(localized: "Wi-Fi")
        default:
            return String(localized: "Device")
        }
    }
}

enum ConnectionDeviceGrouping {
    /// Merge USB + wireless rows that share a LAN IP.
    ///
    /// - `modelBySerial`: `ro.product.model` (or similar) cache
    /// - `usbIpBySerial`: LAN IP read while USB adb is available
    static func groups(
        devices: [AdbBridge.DeviceInfo],
        modelBySerial: [String: String] = [:],
        usbIpBySerial: [String: String] = [:]
    ) -> [ConnectionDeviceGroup] {
        let ready = devices // include unauthorized as single-row groups
        var usb: [AdbBridge.DeviceInfo] = []
        var wifi: [AdbBridge.DeviceInfo] = []
        for d in ready {
            if d.serial.contains(":") {
                wifi.append(d)
            } else {
                usb.append(d)
            }
        }

        var usedWifi = Set<String>()
        var result: [ConnectionDeviceGroup] = []

        for u in usb {
            let ip = usbIpBySerial[u.serial]?.lowercased()
            let matches = wifi.filter { w in
                guard !usedWifi.contains(w.serial) else { return false }
                guard let host = AdbBridge.WifiEndpoint.parse(w.serial)?.host.lowercased() else {
                    return false
                }
                return ip != nil && host == ip
            }
            for m in matches { usedWifi.insert(m.serial) }

            let serials = [u.serial] + matches.map(\.serial)
            let model = firstModel(serials: serials, models: modelBySerial)
            let title = model ?? u.serial
            let detail: String = {
                if matches.isEmpty {
                    return model != nil ? u.serial : u.state
                }
                let wifiSerial = matches[0].serial
                if model != nil {
                    return "\(u.serial) · \(wifiSerial)"
                }
                return wifiSerial
            }()
            // Any ready link is enough to offer Connect (Wi-Fi may be offline
            // while USB is fine, or the reverse after unplug).
            let anyReady = ([u] + matches).contains(where: \.isReady)
            let primaryState = u.isReady ? u.state : (matches.first(where: \.isReady)?.state ?? u.state)
            result.append(ConnectionDeviceGroup(
                id: u.serial,
                title: title,
                detail: detail,
                serials: serials,
                connectSerial: u.isReady ? u.serial : (matches.first(where: \.isReady)?.serial ?? u.serial),
                hasUSB: true,
                hasWireless: !matches.isEmpty,
                isReady: anyReady,
                state: primaryState
            ))
        }

        for w in wifi where !usedWifi.contains(w.serial) {
            let model = modelBySerial[w.serial]
            let title = model ?? w.serial
            result.append(ConnectionDeviceGroup(
                id: w.serial,
                title: title,
                detail: model != nil ? w.serial : w.state,
                serials: [w.serial],
                connectSerial: w.serial,
                hasUSB: false,
                hasWireless: true,
                isReady: w.isReady,
                state: w.state
            ))
        }

        // Stable-ish order: USB groups first (already), then Wi-Fi by serial.
        return result
    }

    private static func firstModel(serials: [String], models: [String: String]) -> String? {
        for s in serials {
            if let m = models[s], !m.isEmpty { return m }
        }
        return nil
    }
}
