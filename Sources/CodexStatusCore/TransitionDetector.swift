import Foundation

public struct StatusEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case finished, needsInput, longRunning }
    public let kind: Kind
    public let sessionID: String
    public let title: String
    public let project: String?
    public let occurredAt: Date
    /// How long the session had been active; nil when the start time is unknown.
    public let duration: TimeInterval?
    /// Identifier the owning app needs to open this session, when it differs from `sessionID`.
    public let openID: String?

    public init(kind: Kind, sessionID: String, title: String, project: String?,
                occurredAt: Date, duration: TimeInterval?, openID: String? = nil) {
        self.kind = kind; self.sessionID = sessionID; self.title = title
        self.project = project; self.occurredAt = occurredAt; self.duration = duration
        self.openID = openID
    }

    /// Waiting-for-you events always notify; finished ones skip tasks shorter than the threshold.
    /// A finished task of unknown length still notifies, since it may have been long.
    public func shouldNotify(minimumDuration: TimeInterval) -> Bool {
        guard kind == .finished, let duration else { return true }
        return duration >= minimumDuration
    }
}

/// Turns successive snapshots into "finished" and "needs input" events.
/// Only sessions seen active are remembered, so the first sample after launch never notifies.
public struct TransitionDetector: Sendable {
    private struct Tracked {
        var phase: SessionPhase
        var since: Date?
        var alerted = false
    }
    private var tracked: [String: Tracked] = [:]
    /// Seconds of continuous running after which a one-time `longRunning` event fires; nil disables it.
    public var stuckAfter: TimeInterval?

    public init() {}

    private static func isActive(_ phase: SessionPhase) -> Bool {
        phase == .running || phase == .waitingForInput || phase == .backgroundRunning
    }

    public mutating func observe(_ sessions: [SessionStatus], now: Date) -> [StatusEvent] {
        var events: [StatusEvent] = []
        for session in sessions where session.phase != .unknown {
            let previous = tracked[session.id]
            if Self.isActive(session.phase) {
                let since = previous?.since ?? session.phaseSince
                if let previous, session.phase == .waitingForInput, previous.phase != .waitingForInput {
                    events.append(.init(kind: .needsInput, sessionID: session.id, title: session.title,
                                        project: session.project, occurredAt: now,
                                        duration: since.map { max(0, now.timeIntervalSince($0)) },
                                        openID: session.openID))
                }
                var alerted = previous?.alerted ?? false
                if let limit = stuckAfter, !alerted, session.phase == .running, let since,
                   now.timeIntervalSince(since) >= limit {
                    alerted = true
                    events.append(.init(kind: .longRunning, sessionID: session.id, title: session.title,
                                        project: session.project, occurredAt: now,
                                        duration: now.timeIntervalSince(since), openID: session.openID))
                }
                tracked[session.id] = Tracked(phase: session.phase, since: since, alerted: alerted)
            } else {
                if let previous, session.phase == .completed || session.phase == .idle {
                    let end = session.updatedAt ?? now
                    events.append(.init(kind: .finished, sessionID: session.id, title: session.title,
                                        project: session.project, occurredAt: end,
                                        duration: previous.since.map { max(0, end.timeIntervalSince($0)) },
                                        openID: session.openID))
                }
                tracked[session.id] = nil
            }
        }
        return events
    }
}

public func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total) 秒" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes) 分钟" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
}

public func formatAgo(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "刚刚" }
    if total < 3600 { return "\(total / 60) 分钟前" }
    if total < 86_400 { return "\(total / 3600) 小时前" }
    return "\(total / 86_400) 天前"
}
