import AppKit

/// Owns the one asynchronous terminate sequence. AppKit may ask more than once
/// while termination is deferred; every request must join the original work.
@MainActor
final class AppTerminationCoordinator {
    typealias AsyncStep = @MainActor @Sendable () async -> Void
    typealias Reply = @MainActor @Sendable () -> Void

    private var task: Task<Void, Never>?

    @discardableResult
    func begin(
        prepare: @escaping AsyncStep,
        disconnect: @escaping AsyncStep,
        reply: @escaping Reply
    ) -> Bool {
        guard task == nil else { return false }
        task = Task { @MainActor in
            await prepare()
            await disconnect()
            reply()
        }
        return true
    }

    func waitForCompletion() async {
        await task?.value
    }
}

/// AppKit delegate so *every* terminate path (Cmd+Q, Dock Quit, AEQuit, menu bar)
/// can clear drag-out file promises before AppKit resolves pasteboards.
///
/// Without this, only status-item Quit deferred + cleared the drag pasteboard;
/// hang reports still showed `_handleAEQuit` → `CFPasteboardResolveAllPromisedData`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var scrcpy: ScrcpyController?
    weak var connectionManager: ConnectionManager?
    private let terminationCoordinator = AppTerminationCoordinator()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let scrcpy = scrcpy
        let connectionManager = connectionManager
        terminationCoordinator.begin(
            prepare: {
                await AppQuitPrep.prepareForTerminate(scrcpy: scrcpy)
            },
            disconnect: {
                await connectionManager?.disconnectAll()
            },
            reply: {
                sender.reply(toApplicationShouldTerminate: true)
            }
        )
        return .terminateLater
    }
}
