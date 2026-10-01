import Foundation

/// A daily window during which notifications stay silent. Wraps past midnight when start > end.
public struct QuietHours: Equatable, Sendable {
    public let startHour: Int
    public let endHour: Int

    public init(startHour: Int, endHour: Int) {
        self.startHour = startHour
        self.endHour = endHour
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if startHour == endHour { return false }
        return startHour < endHour ? (hour >= startHour && hour < endHour) : (hour >= startHour || hour < endHour)
    }
}

/// Counts of tasks finished on one calendar day.
public struct DailyStats: Codable, Equatable, Sendable {
    public private(set) var day: String
    public private(set) var count = 0
    public private(set) var totalSeconds: TimeInterval = 0
    public private(set) var longestSeconds: TimeInterval = 0

    public init(day: String) { self.day = day }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Adds a finished event, starting a fresh day when the event belongs to a different one.
    public mutating func add(_ event: StatusEvent, calendar: Calendar = .current) {
        guard event.kind == .finished else { return }
        let key = Self.dayKey(event.occurredAt, calendar: calendar)
        if key != day { self = DailyStats(day: key) }
        count += 1
        if let duration = event.duration {
            totalSeconds += duration
            longestSeconds = max(longestSeconds, duration)
        }
    }

    public func summary(now: Date, calendar: Calendar = .current) -> String? {
        guard day == Self.dayKey(now, calendar: calendar), count > 0 else { return nil }
        var text = "今日完成 \(count) 个"
        if totalSeconds >= 1 { text += " · 累计 \(formatElapsed(totalSeconds)) · 最长 \(formatElapsed(longestSeconds))" }
        return text
    }
}
