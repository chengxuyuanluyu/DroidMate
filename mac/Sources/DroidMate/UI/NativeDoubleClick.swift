import AppKit
import SwiftUI

/// Transparent AppKit view that detects native double-clicks **inside its bounds**
/// without stealing hit-testing from SwiftUI (so List selection still works).
///
/// Why this exists:
/// SwiftUI `onTapGesture(count: 2)` fails when List selection rebuilds the row
/// between the two clicks. AppKit tracks `NSEvent.clickCount` at window level,
/// so the second click still reports `clickCount == 2` even after the SwiftUI
/// tree is recreated. The first click selects; the second activates selection.
struct NativeDoubleClickCatcher: NSViewRepresentable {
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickCatcherNSView {
        let v = DoubleClickCatcherNSView()
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: DoubleClickCatcherNSView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    final class DoubleClickCatcherNSView: NSView {
        var onDoubleClick: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reinstallMonitor()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil { removeMonitor() }
        }

        private func reinstallMonitor() {
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return event }
                guard event.clickCount >= 2 else { return event }
                guard event.window === self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                // Defer so List finishes applying the selection from click 1 / click 2.
                DispatchQueue.main.async {
                    self.onDoubleClick?()
                }
                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        /// Pass all hits through so SwiftUI List/Grid keep selection & drag.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Activate selected item on AppKit double-click inside this view.
    func onNativeDoubleClick(perform action: @escaping () -> Void) -> some View {
        background(
            NativeDoubleClickCatcher(onDoubleClick: action)
        )
    }
}
