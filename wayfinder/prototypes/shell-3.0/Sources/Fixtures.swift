import Foundation

struct ProtoDevice: Identifiable, Hashable {
    let id: String
    var name: String
    var detail: String
    var online: Bool
}

struct ProtoEntry: Identifiable, Hashable {
    let id: String
    var name: String
    var isDir: Bool
    var sizeText: String
    var dateText: String
}

enum Fixtures {
    static let devices: [ProtoDevice] = [
        .init(id: "usb-pixel", name: "Pixel 8", detail: "USB · ready", online: true),
        .init(id: "wifi-s24", name: "Galaxy S24", detail: "Wi‑Fi · failed", online: false),
    ]

    static let locations = ["Download", "DCIM", "Pictures", "Documents", "Music"]

    static func entries(for path: String) -> [ProtoEntry] {
        switch path {
        case "/Download":
            return [
                .init(id: "1", name: "Camera", isDir: true, sizeText: "—", dateText: "Today"),
                .init(id: "2", name: "report.pdf", isDir: false, sizeText: "1.2 MB", dateText: "Yesterday"),
                .init(id: "3", name: "notes.txt", isDir: false, sizeText: "4 KB", dateText: "Mon"),
                .init(id: "4", name: "backup", isDir: true, sizeText: "—", dateText: "Jul 30"),
                .init(id: "5", name: "IMG_1001.HEIC", isDir: false, sizeText: "3.4 MB", dateText: "Jul 29"),
            ]
        case "/Download/Camera":
            return [
                .init(id: "c1", name: "IMG_2001.HEIC", isDir: false, sizeText: "2.1 MB", dateText: "Today"),
                .init(id: "c2", name: "IMG_2002.HEIC", isDir: false, sizeText: "2.0 MB", dateText: "Today"),
                .init(id: "c3", name: "VID_01.mp4", isDir: false, sizeText: "48 MB", dateText: "Sun"),
            ]
        default:
            return [
                .init(id: "r1", name: "Download", isDir: true, sizeText: "—", dateText: "—"),
                .init(id: "r2", name: "DCIM", isDir: true, sizeText: "—", dateText: "—"),
                .init(id: "r3", name: "Pictures", isDir: true, sizeText: "—", dateText: "—"),
            ]
        }
    }

    static let fakeTransfers: [(String, String, Double)] = [
        ("report.pdf", "Downloading", 0.62),
        ("notes.txt", "Completed", 1.0),
        ("IMG_1001.HEIC", "Queued", 0.0),
    ]
}
