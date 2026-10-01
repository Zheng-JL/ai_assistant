import Foundation

public struct HealthItem: Sendable, Equatable {
    public enum Level: String, Sendable { case ok, warning, failure, off }
    public let name: String
    public let level: Level
    public let detail: String

    public var symbol: String {
        switch level {
        case .ok: return "✓"
        case .warning: return "⚠"
        case .failure: return "✗"
        case .off: return "–"
        }
    }
}

/// Plain facts gathered by the app; `buildHealthReport` turns them into a readable verdict.
public struct HealthInputs: Sendable {
    public var version: String
    public var installedPath: String
    public var hasIcon: Bool
    public var otherRegistrations: [String]
    public var notificationAuthorization: Int?     // 0 undecided, 1 denied, 2 allowed, nil unknown
    public var notificationsOn: Bool
    public var muted: Bool
    public var codexAppRunning: Bool
    public var codexDataFound: Bool
    public var codexRunningKnown: Bool
    public var codexNotice: String?
    public var claudeAppRunning: Bool
    public var claudeDataFound: Bool
    public var claudeRunningKnown: Bool
    public var claudeNotice: String?
    public var tokenStatsOK: Bool
    public var summaryEndpointHost: String?
    public var summaryKeyStored: Bool
    public var hotKeysRegistered: Bool

    public init(version: String = "", installedPath: String = "", hasIcon: Bool = true, otherRegistrations: [String] = [],
                notificationAuthorization: Int? = 2, notificationsOn: Bool = true, muted: Bool = false,
                codexAppRunning: Bool = true, codexDataFound: Bool = true, codexRunningKnown: Bool = true, codexNotice: String? = nil,
                claudeAppRunning: Bool = true, claudeDataFound: Bool = true, claudeRunningKnown: Bool = true, claudeNotice: String? = nil,
                tokenStatsOK: Bool = true, summaryEndpointHost: String? = nil, summaryKeyStored: Bool = false,
                hotKeysRegistered: Bool = true) {
        self.version = version; self.installedPath = installedPath; self.hasIcon = hasIcon
        self.otherRegistrations = otherRegistrations; self.notificationAuthorization = notificationAuthorization
        self.notificationsOn = notificationsOn; self.muted = muted
        self.codexAppRunning = codexAppRunning; self.codexDataFound = codexDataFound
        self.codexRunningKnown = codexRunningKnown; self.codexNotice = codexNotice
        self.claudeAppRunning = claudeAppRunning; self.claudeDataFound = claudeDataFound
        self.claudeRunningKnown = claudeRunningKnown; self.claudeNotice = claudeNotice
        self.tokenStatsOK = tokenStatsOK; self.summaryEndpointHost = summaryEndpointHost
        self.summaryKeyStored = summaryKeyStored; self.hotKeysRegistered = hotKeysRegistered
    }
}

public func buildHealthReport(_ input: HealthInputs, home: String = NSHomeDirectory()) -> [HealthItem] {
    var items: [HealthItem] = []
    func add(_ name: String, _ level: HealthItem.Level, _ detail: String) { items.append(.init(name: name, level: level, detail: detail)) }

    let applications = [home + "/Applications/", "/Applications/"]
    if applications.contains(where: { input.installedPath.hasPrefix($0) }) {
        add("安装位置", .ok, input.installedPath)
    } else {
        add("安装位置", .warning, "不在“应用程序”目录（\(input.installedPath)），系统可能不给通知授权。请用 scripts/install.sh 安装")
    }

    add("应用图标", input.hasIcon ? .ok : .warning, input.hasIcon ? "已内置" : "应用包里没有图标文件")

    if input.otherRegistrations.isEmpty {
        add("系统登记", .ok, "只有当前这一份")
    } else {
        let shown = input.otherRegistrations.prefix(3).joined(separator: "、")
        add("系统登记", .warning,
            "系统里还登记着同一个应用的其他副本：\(shown)。通知中心可能选中它们，导致通知没有应用图标。"
            + "可运行 lsregister -u <路径> 注销，或删除这些副本")
    }

    switch input.notificationAuthorization {
    case 2:
        if !input.notificationsOn { add("通知", .warning, "权限正常，但你在菜单里关闭了通知") }
        else if input.muted { add("通知", .warning, "权限正常，但当前处于静音中") }
        else { add("通知", .ok, "权限正常") }
    case 1: add("通知", .failure, "被系统拒绝。请到 系统设置 → 通知 → 搭子 打开“允许通知”")
    case 0: add("通知", .warning, "尚未授权。请在系统弹窗中点允许，或到 系统设置 → 通知 里打开")
    default: add("通知", .warning, "无法读取通知权限（可能不是从“应用程序”目录启动的）")
    }

    func source(_ name: String, running: Bool, dataFound: Bool, known: Bool, notice: String?, missingData: String, closed: String) {
        if !running { add(name, .off, closed) }
        else if !dataFound { add(name, .failure, missingData) }
        else if !known { add(name, .warning, notice ?? "状态无法确认。应用升级后内部格式可能变了，请更新搭子") }
        else if let notice { add(name, .warning, notice) }
        else { add(name, .ok, "读取正常") }
    }
    source("Codex", running: input.codexAppRunning, dataFound: input.codexDataFound, known: input.codexRunningKnown,
           notice: input.codexNotice, missingData: "找不到 ~/.codex 的会话数据", closed: "Codex 未运行")
    source("Claude", running: input.claudeAppRunning, dataFound: input.claudeDataFound, known: input.claudeRunningKnown,
           notice: input.claudeNotice, missingData: "找不到 ~/.claude 的会话数据", closed: "Claude 未运行")

    add("Token 统计", input.tokenStatsOK ? .ok : .warning, input.tokenStatsOK ? "读取正常" : "还没有读到数据")

    if let host = input.summaryEndpointHost {
        add("AI 总结", input.summaryKeyStored ? .ok : .warning,
            input.summaryKeyStored ? "已配置（\(host)）" : "已填写地址（\(host)），但钥匙串里没有 API Key")
    } else {
        add("AI 总结", .off, "未配置")
    }

    add("快捷键", input.hotKeysRegistered ? .ok : .warning,
        input.hotKeysRegistered ? "⌃⌥⌘J 与 ⌃⌥⌘K 可用" : "至少有一个快捷键被其他软件占用")
    return items
}

public func formatHealthReport(_ items: [HealthItem], version: String) -> String {
    (["搭子 \(version) 运行状况"] + items.map { "\($0.symbol) \($0.name)：\($0.detail)" }).joined(separator: "\n")
}

/// Paths of every app Launch Services has registered under `bundleID`, parsed from an `lsregister -dump`.
public func registeredAppPaths(bundleID: String, dump: String) -> [String] {
    var paths: [String] = []
    let idPattern = try? NSRegularExpression(pattern: "^identifier:\\s+\(NSRegularExpression.escapedPattern(for: bundleID))(?=\\s|$)", options: .anchorsMatchLines)
    let pathPattern = try? NSRegularExpression(pattern: "^path:\\s+(.+?)\\s+\\(0x[0-9a-fA-F]+\\)\\s*$", options: .anchorsMatchLines)
    for block in dump.components(separatedBy: "\n--------------------------------------------------------------------------------\n") {
        let range = NSRange(block.startIndex..., in: block)
        guard idPattern?.firstMatch(in: block, range: range) != nil,
              let match = pathPattern?.firstMatch(in: block, range: range), let r = Range(match.range(at: 1), in: block) else { continue }
        paths.append(String(block[r]))
    }
    return paths
}
