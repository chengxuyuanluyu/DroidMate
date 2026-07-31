import SwiftUI

/// Shared stat-color thresholds. Single source of truth for warn/bad levels.
enum StatThresholds {
    static func rttColor(_ rttMs: Double) -> Color {
        if rttMs >= 150 { return .red }
        if rttMs >= 80  { return .yellow }
        return .white.opacity(0.85)
    }

    @MainActor
    static func statusColor(for engine: DeviceSession) -> Color {
        if case .failed = engine.transportState { return .red }
        if engine.ack == nil { return .orange }
        return engine.transportState == .ready ? .green : .gray
    }
}
