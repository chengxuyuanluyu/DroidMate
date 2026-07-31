import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe URL accumulator for NSItemProvider load callbacks.
final class DropURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage.append(url)
    }
}

/// Tracks hover count for the drop overlay and forwards the drop payload.
struct FileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var itemCount: Int?
    let onDrop: ([NSItemProvider]) -> Void

    func dropEntered(info: DropInfo) {
        isTargeted = true
        itemCount = info.itemProviders(for: [.fileURL]).count
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        itemCount = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        itemCount = info.itemProviders(for: [.fileURL]).count
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        isTargeted = false
        itemCount = nil
        onDrop(providers)
        return true
    }
}
