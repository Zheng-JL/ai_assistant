import AppKit
import CodexStatusCore
import ServiceManagement

// The 设置 submenu and the actions behind it.
extension MenuController {
    func thresholdItem() -> NSMenuItem {
        let row = NSMenuItem(title: "完成通知门槛", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for choice in Notifier.thresholdChoices {
            let child = NSMenuItem(title: choice.label, action: #selector(setThreshold(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = choice.seconds
            child.state = notifier.minimumDuration == choice.seconds ? .on : .off
            submenu.addItem(child)
        }
        row.submenu = submenu
        return row
    }

    func addSettingsMenu() {
        let settings = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        settings.image = symbol("gearshape")
        let submenu = NSMenu()
        submenu.addItem(thresholdItem())

        let quiet = NSMenuItem(title: "勿扰时段", action: nil, keyEquivalent: "")
        let quietMenu = NSMenu()
        for choice in Notifier.quietChoices {
            let child = NSMenuItem(title: choice.label, action: #selector(setQuiet(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = choice.hours.map { "\($0.startHour)-\($0.endHour)" } ?? "off"
            child.state = notifier.quietHours == choice.hours ? .on : .off
            quietMenu.addItem(child)
        }
        quiet.submenu = quietMenu
        submenu.addItem(quiet)

        let stuck = NSMenuItem(title: "长时间运行提醒", action: nil, keyEquivalent: "")
        let stuckMenu = NSMenu()
        for choice in Notifier.stuckChoices {
            let child = NSMenuItem(title: choice.label, action: #selector(setStuck(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = choice.minutes
            child.state = notifier.stuckMinutes == choice.minutes ? .on : .off
            stuckMenu.addItem(child)
        }
        stuck.submenu = stuckMenu
        submenu.addItem(stuck)

        func choiceMenu(_ title: String, _ choices: [(String, Int)], current: Int, action: Selector) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let inner = NSMenu()
            for (label, value) in choices {
                let child = NSMenuItem(title: label, action: action, keyEquivalent: "")
                child.target = self
                child.representedObject = value
                child.state = current == value ? .on : .off
                inner.addItem(child)
            }
            parent.submenu = inner
            return parent
        }
        submenu.addItem(choiceMenu("上下文提醒", Notifier.contextChoices.map { ($0.label, $0.percent) },
                                   current: notifier.contextPercent, action: #selector(setContextPercent(_:))))
        submenu.addItem(choiceMenu("每日用量预算（新输入+输出）", Notifier.budgetChoices.map { ($0.label, $0.tokens) },
                                   current: notifier.dailyBudget, action: #selector(setBudget(_:))))

        submenu.addItem(.separator())
        let awake = NSMenuItem(title: "任务运行时保持唤醒（合盖仍会休眠）", action: #selector(toggleKeepAwake), keyEquivalent: "")
        awake.target = self
        awake.state = notifier.keepAwakeEnabled ? .on : .off
        submenu.addItem(awake)
        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        submenu.addItem(login)
        settings.submenu = submenu
        menu.addItem(settings)
    }

    @objc func setContextPercent(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        notifier.contextPercent = percent
        rebuildMenu()
    }

    @objc func setBudget(_ sender: NSMenuItem) {
        guard let tokens = sender.representedObject as? Int else { return }
        notifier.dailyBudget = tokens
        notifier.budgetAlertedDay = nil
        rebuildMenu()
    }

    @objc func setQuiet(_ sender: NSMenuItem) {
        let value = sender.representedObject as? String ?? "off"
        let parts = value.split(separator: "-").compactMap { Int($0) }
        notifier.quietHours = parts.count == 2 ? QuietHours(startHour: parts[0], endHour: parts[1]) : nil
        rebuildMenu()
    }

    @objc func setStuck(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        notifier.stuckMinutes = minutes
        rebuildMenu()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            openingError = nil
        } catch {
            openingError = "无法修改开机启动（需把应用放在“应用程序”目录）"
        }
        rebuildMenu()
    }

    @objc func setThreshold(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        notifier.minimumDuration = seconds
        rebuildMenu()
    }

    func updateKeepAwake() {
        keepAwake.set(shouldKeepAwake(enabled: notifier.keepAwakeEnabled,
                                      running: [snapshot.runningCount, claudeSnapshot.runningCount]))
    }

    @objc func toggleKeepAwake() {
        notifier.keepAwakeEnabled.toggle()
        updateKeepAwake()
        rebuildMenu()
    }
}
