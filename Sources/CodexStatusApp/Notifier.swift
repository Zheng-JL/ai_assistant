import AppKit
import CodexStatusCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let enabledKey = "notificationsEnabled"
    private static let mutedUntilKey = "notificationsMutedUntil"
    private static let minimumKey = "notificationMinimumSeconds"
    private static let quietStartKey = "quietStartHour"
    private static let quietEndKey = "quietEndHour"
    private static let stuckKey = "stuckAfterMinutes"
    private static let contextKey = "contextAlertPercent"
    private static let budgetKey = "dailyTokenBudget"
    private static let budgetDayKey = "budgetAlertedDay"
    private static let keepAwakeKey = "keepAwakeWhileRunning"
    nonisolated static let categoryID = "buddy.status"
    nonisolated static let openAction = "buddy.open"
    nonisolated static let muteAction = "buddy.mute"
    static let contextChoices: [(label: String, percent: Int)] = [("关闭", 0), ("70%", 70), ("80%", 80), ("90%", 90)]
    static let budgetChoices: [(label: String, tokens: Int)] = [
        ("不设置", 0), ("50 万", 500_000), ("100 万", 1_000_000), ("200 万", 2_000_000),
        ("500 万", 5_000_000), ("1000 万", 10_000_000)
    ]
    static let quietChoices: [(label: String, hours: QuietHours?)] = [
        ("不设置", nil), ("夜间 22:00–08:00", QuietHours(startHour: 22, endHour: 8)),
        ("午休 12:00–14:00", QuietHours(startHour: 12, endHour: 14))
    ]
    static let stuckChoices: [(label: String, minutes: Int)] = [("关闭", 0), ("30 分钟", 30), ("60 分钟", 60), ("120 分钟", 120)]
    static let thresholdChoices: [(label: String, seconds: TimeInterval)] = [
        ("所有完成都通知", 0), ("运行超过 30 秒", 30), ("运行超过 2 分钟", 120), ("运行超过 5 分钟", 300)
    ]

    /// Called with (provider, session ID) when the user clicks a notification.
    var onActivate: ((String, String) -> Void)?
    // UNUserNotificationCenter traps outside an app bundle (e.g. `swift run`, tests).
    private let available = Bundle.main.bundleURL.pathExtension == "app"
    private let defaults = UserDefaults.standard

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Finished tasks shorter than this are not announced (default 30 s); waiting events always are.
    var minimumDuration: TimeInterval {
        get { defaults.object(forKey: Self.minimumKey) as? Double ?? 30 }
        set { defaults.set(newValue, forKey: Self.minimumKey) }
    }

    var quietHours: QuietHours? {
        get {
            guard let start = defaults.object(forKey: Self.quietStartKey) as? Int,
                  let end = defaults.object(forKey: Self.quietEndKey) as? Int else { return nil }
            return QuietHours(startHour: start, endHour: end)
        }
        set {
            if let newValue {
                defaults.set(newValue.startHour, forKey: Self.quietStartKey)
                defaults.set(newValue.endHour, forKey: Self.quietEndKey)
            } else {
                defaults.removeObject(forKey: Self.quietStartKey)
                defaults.removeObject(forKey: Self.quietEndKey)
            }
        }
    }

    /// Minutes of continuous running before a one-time "running long" alert; 0 turns it off.
    var stuckMinutes: Int {
        get { defaults.object(forKey: Self.stuckKey) as? Int ?? 30 }
        set { defaults.set(newValue, forKey: Self.stuckKey) }
    }

    /// Warn when a session in use has filled this percent of its context window; 0 turns it off.
    var contextPercent: Int {
        get { defaults.object(forKey: Self.contextKey) as? Int ?? 80 }
        set { defaults.set(newValue, forKey: Self.contextKey) }
    }

    var contextThreshold: Double? { contextPercent > 0 ? Double(contextPercent) / 100 : nil }

    /// Daily limit on new-input plus output tokens across both tools; 0 means none.
    var dailyBudget: Int {
        get { defaults.object(forKey: Self.budgetKey) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: Self.budgetKey) }
    }

    var budgetAlertedDay: String? {
        get { defaults.string(forKey: Self.budgetDayKey) }
        set { defaults.set(newValue, forKey: Self.budgetDayKey) }
    }

    /// Keep the Mac from idle-sleeping while a task runs. Off unless the user turns it on.
    var keepAwakeEnabled: Bool {
        get { defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.keepAwakeKey) }
    }

    func mute(for interval: TimeInterval) {
        defaults.set(Date().addingTimeInterval(interval), forKey: Self.mutedUntilKey)
    }

    var stuckAfter: TimeInterval? { stuckMinutes > 0 ? TimeInterval(stuckMinutes * 60) : nil }

    var mutedUntil: Date? {
        guard let date = defaults.object(forKey: Self.mutedUntilKey) as? Date, date > Date() else { return nil }
        return date
    }

    func toggleMute(for interval: TimeInterval = 3600) {
        if mutedUntil != nil { defaults.removeObject(forKey: Self.mutedUntilKey) }
        else { defaults.set(Date().addingTimeInterval(interval), forKey: Self.mutedUntilKey) }
    }

    /// `--notify-test`: prints the authorization state and posts a sample in the real notification style.
    @MainActor
    static func selfTest() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { print("not running from an .app bundle"); return }
        let center = UNUserNotificationCenter.current()
        registerCategories(center)
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let (authorization, alert, sound) = await withCheckedContinuation { (continuation: CheckedContinuation<(Int, Int, Int), Never>) in
            center.getNotificationSettings { settings in
                continuation.resume(returning: (settings.authorizationStatus.rawValue, settings.alertSetting.rawValue,
                                                settings.soundSetting.rawValue))
            }
        }
        print("authorization(0=未决定,1=拒绝,2=允许):", authorization, "alert:", alert, "sound:", sound)
        let sample = StatusEvent(kind: .finished, sessionID: "00000000-0000-0000-0000-000000000000",
                                 title: "示例：修复登录失败的问题", project: "my-app",
                                 occurredAt: Date(), duration: 245)
        let content = makeContent(notificationCopy(for: sample, provider: "Claude"), style: .finished,
                                  userInfo: [:], thread: nil)
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            print("已提交通知")
        } catch { print("提交失败:", error) }
        try? await Task.sleep(for: .seconds(3))
    }

    /// Look of each kind of notification: a coloured badge shown on the right of the banner.
    enum Style {
        case finished, waiting, longRunning, context, budget

        var symbol: String {
            switch self {
            case .finished: return "checkmark"
            case .waiting: return "hand.raised.fill"
            case .longRunning: return "clock.fill"
            case .context: return "exclamationmark.bubble.fill"
            case .budget: return "chart.bar.fill"
            }
        }

        var color: NSColor {
            switch self {
            case .finished: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
            case .waiting: return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)
            case .longRunning: return NSColor(srgbRed: 0.55, green: 0.40, blue: 0.95, alpha: 1)
            case .context: return NSColor(srgbRed: 0.95, green: 0.32, blue: 0.30, alpha: 1)
            case .budget: return NSColor(srgbRed: 0.20, green: 0.55, blue: 1.00, alpha: 1)
            }
        }
    }

    @MainActor
    static func makeContent(_ copy: NotificationCopy, style: Style, userInfo: [String: String],
                            thread: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.subtitle = copy.subtitle
        content.body = copy.body
        content.sound = .default
        content.userInfo = userInfo
        content.categoryIdentifier = categoryID
        if let thread { content.threadIdentifier = thread }
        // The system copies the attachment file, so each notification gets a fresh temporary one.
        if let png = IconArt.badgePNG(symbol: style.symbol, color: style.color) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("badge-\(UUID().uuidString).png")
            if (try? png.write(to: file)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "badge", url: file) {
                content.attachments = [attachment]
            }
        }
        return content
    }

    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Self.registerCategories(center)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Buttons shown on every notification: open the session, or silence notifications for an hour.
    static func registerCategories(_ center: UNUserNotificationCenter) {
        let open = UNNotificationAction(identifier: openAction, title: "打开", options: [.foreground])
        let mute = UNNotificationAction(identifier: muteAction, title: "静音 1 小时", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [open, mute], intentIdentifiers: [], options: [])
        ])
    }

    private var canNotify: Bool {
        available && isEnabled && mutedUntil == nil && quietHours?.contains(Date()) != true
    }

    func postContextWarning(_ alerts: [ContextAlert], provider: String, key: String) {
        guard canNotify else { return }
        for alert in alerts {
            let content = Self.makeContent(notificationCopy(for: alert, provider: provider), style: .context,
                                           userInfo: ["provider": key, "session": alert.openID ?? alert.sessionID], thread: nil)
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func postBudgetWarning(total: Int, budget: Int, codex: Int, claude: Int) {
        guard canNotify else { return }
        let content = Self.makeContent(
            budgetNotificationCopy(total: total, budget: budget, codex: codex, claude: claude),
            style: .budget, userInfo: [:], thread: nil)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func post(_ events: [StatusEvent], provider: String, key: String) {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        for event in events where event.shouldNotify(minimumDuration: minimumDuration) {
            let style: Style = event.kind == .finished ? .finished : event.kind == .needsInput ? .waiting : .longRunning
            let content = Self.makeContent(notificationCopy(for: event, provider: provider), style: style,
                                           userInfo: ["provider": key, "session": event.openID ?? event.sessionID],
                                           thread: "\(key)-\(event.sessionID)")
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == Notifier.muteAction {
            await MainActor.run { mute(for: 3600) }
            return
        }
        let info = response.notification.request.content.userInfo
        guard let provider = info["provider"] as? String, let id = info["session"] as? String else { return }
        await MainActor.run { onActivate?(provider, id) }
    }
}
