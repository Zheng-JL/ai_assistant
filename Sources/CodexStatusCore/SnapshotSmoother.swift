import Foundation

/// Hides one-off "unknown" samples (for example Claude briefly starting a second helper process).
/// A short run of unknown samples keeps showing the last known state; a longer one is shown as it is.
public struct SnapshotSmoother: Sendable {
    private var lastKnown: StatusSnapshot?
    private var unknownStreak = 0
    public let tolerance: Int

    public init(tolerance: Int = 1) { self.tolerance = tolerance }

    public mutating func smooth(_ snapshot: StatusSnapshot) -> StatusSnapshot {
        guard snapshot.appIsRunning else {
            lastKnown = nil
            unknownStreak = 0
            return snapshot
        }
        if snapshot.runningCount != nil {
            lastKnown = snapshot
            unknownStreak = 0
            return snapshot
        }
        unknownStreak += 1
        if unknownStreak <= tolerance, let lastKnown { return lastKnown }
        return snapshot
    }
}

/// Keep the Mac awake only when the user asked for it and some task is actually running.
public func shouldKeepAwake(enabled: Bool, running: [Int?]) -> Bool {
    enabled && running.contains { ($0 ?? 0) > 0 }
}
