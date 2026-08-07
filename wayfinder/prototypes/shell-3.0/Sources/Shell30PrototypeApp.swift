import SwiftUI

/// PROTOTYPE entry — throwaway Shell 3.0 feel check.
@main
struct Shell30PrototypeApp: App {
    @State private var state = PrototypeState()

    var body: some Scene {
        WindowGroup("DroidMate 3.0 Shell Prototype") {
            Group {
                switch state.mode {
                case .connection:
                    ConnectionWorkbench(state: state)
                case .session:
                    SessionShell(state: state)
                }
            }
            .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("About this prototype") {}
            }
        }
    }
}
