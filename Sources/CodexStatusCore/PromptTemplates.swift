import Foundation

public struct PromptTemplate: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Set when the heading ends with `@项目名`; nil for templates that apply everywhere.
    public let project: String?
    /// True for templates listed after a lone `## 更多` line; shown in the "更多" submenu.
    public var isMore: Bool = false
}

/// `## 更多` and `## More` (any case) both start the "more" part of the template list.
func isMoreMarker(_ title: String) -> Bool { title == "更多" || title.lowercased() == "more" }

/// Parses a plain-text file where every `## 标题` (optionally `## 标题 @项目名`) starts a template
/// and the lines below it are the text to copy. Anything before the first heading is ignored.
public func parsePromptTemplates(_ text: String, limit: Int = 50) -> [PromptTemplate] {
    var result: [PromptTemplate] = []
    var heading: (title: String, project: String?)?
    var lines: [Substring] = []
    var inMore = false

    func flush() {
        guard let heading else { return }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty, !heading.title.isEmpty, result.count < limit {
            result.append(.init(title: heading.title, body: String(body.prefix(20_000)), project: heading.project,
                                isMore: inMore))
        }
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("## ") {
            flush()
            lines = []
            var title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            var project: String?
            if let at = title.range(of: " @", options: .backwards) {
                let name = title[at.upperBound...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !name.contains(" ") {
                    project = name
                    title = title[..<at.lowerBound].trimmingCharacters(in: .whitespaces)
                }
            }
            if isMoreMarker(title), project == nil { inMore = true; heading = nil; continue }
            heading = (String(title.prefix(60)), project)
        } else if heading != nil {
            lines.append(line)
        }
    }
    flush()
    return result
}

public let defaultPromptTemplateText = """
# 常用提示词模板
# 每个 "## 标题" 是一条模板，标题下面的内容就是点击后复制的文字。
# 单独一行 "## 更多" 之后的模板放进“更多”子菜单，之前的显示在最上面。
# 可用变量（复制时自动替换）：{项目} 最近活跃会话的项目名，{日期} 今天日期，{剪贴板} 当前剪贴板文字。
# 标题末尾写 " @项目名"（项目文件夹名）表示只在该项目下使用，例如：## 项目背景 @my-app
# 括号里的内容需要你粘贴后替换。第一个 "##" 之前的内容（包括这段说明）会被忽略。保存后下次打开菜单自动生效。

## 开局约定
接下来请你自己完成并验证，我只看最终效果。要求：
1. 能自己执行的不要让我动手；确实需要我操作时，只列一件事，并写清楚怎么做。
2. 有多个方案时直接给出推荐和理由，不要罗列让我选。
3. 做完后分开说明：已验证的（附证据）、没法验证的、有风险的。没验证就不要说"已完成"。
4. 用大白话中文回复，不要堆术语。

## 定位根因
这个问题的现象是：（现象）。请先自己查原因，不要先问我问题：看日志和相关代码，复现或找到证据，列出可能的原因并逐个排除，确认根因后再动手，不要直接改症状。给我：根因、证据、最小的修复方案。如果无法确认根因，明说，不要猜着改。

## 最小改动
请用尽量小的改动完成这件事：只改必须改的文件，不顺手重构，不改无关的格式和命名，不新增依赖。改完列出改动清单，并说明为什么每一处是必须的。

## 需求澄清
动手前，只问会改变实现方案的问题，最多 3 个，每个问题给出你的默认假设。如果我没回答，你就按默认假设继续，并在最后列出你做过哪些假设。

## 交接摘要
这个会话已经很长了。请写一份交接摘要，让新会话能直接接着做：目标、已完成的事、关键决定及理由、当前状态（哪些已验证）、下一步、需要避开的坑。控制在 300 字以内，不要复述过程。

## 找茬式审查
请以挑剔的评审者身份审查这次改动，只报告真实的问题：逻辑错误、遗漏的边界情况、并发或资源问题、安全隐患、与现有代码风格不一致。每条给出位置、会怎么出错、建议修法。没有问题就明说没有，不要为了凑数列无关意见。

## 同意并继续
你的建议我同意。请按你建议的顺序完整做完，中途不用再问我；遇到会改变范围的决定或有风险的操作再停下来问我。

## 看图解释
这是一张截图。请用大白话告诉我：它是什么意思、正常吗、我需要做什么。如果是软件自己的问题，请直接帮我改。

## 分析报错
请分析下面的报错，在 {项目} 里找到原因并修复。先给结论和证据，再动手；无法确认原因就明说。
{剪贴板}

## 更多

## 先写测试
先为这个需求写会失败的测试，确认它因为正确的原因失败，再写实现让它通过。最后报告：新增了哪些测试、运行结果、还有哪些情况没覆盖。

## 重构不改行为
请重构（范围：……），要求外部行为完全不变。先确认现有测试覆盖了这部分行为，不够就先补测试；重构分小步，每一步都跑测试；最后用一句话说明结构上变好了什么。

## 方案对比
请给出 2 到 3 个可行方案，每个说明：做法、优点、代价、适用场景。然后明确推荐一个，并说明如果我的前提变了（比如数据量变大）推荐会怎么变。

## 长任务检查点
这个任务比较大。请先拆成若干步，每步写清楚完成标准，然后逐步执行。每完成一步就验证并汇报一行结果，全部完成后再给总结。遇到超出范围或有风险的情况立即停下来问我。

## 安全操作
动手前先用三句话说明：你准备做什么、会改动哪些文件或设置、可能的副作用。下面的操作可能不可逆：（操作）。请先说明会影响什么、怎么回滚；先做备份或只读检查；能先在小范围试一次就先试。如果会修改我电脑上项目以外的内容，先问我，得到确认后再正式执行。

## 性能排查
这里有性能问题：（现象）。请先测量再优化：给出怎么测的、基线数据、瓶颈在哪里的证据。优化后用同样方法再测一次并对比。没有数据支撑的优化不要做。

## 改完自查
结束前请自查并逐条回答：相关测试和类型检查是否通过、新增内容是否在真实使用中确实能用、文档是否需要同步更新、有没有遗留的调试代码。没验证的明说，并列出改动的文件。

## 提交说明
请根据这次改动写提交说明：第一行不超过 50 字说明做了什么，正文说明为什么这样做、有什么影响和风险。不要写"优化代码"这类空话，也不要把无关改动写进去。

## 熟悉陌生代码
我刚接手这个项目。请先通读后用大白话告诉我：它是做什么的、入口在哪里、主要模块怎么分工、数据怎么流动、最容易踩坑的地方。附上关键文件路径，不要贴大段代码。
"""


/// Replaces `{项目}`, `{日期}` and `{剪贴板}` in one pass, so substituted text is never expanded again.
/// Placeholders without a usable value are left as written and reported in `unresolved`.
public func expandTemplate(_ body: String, project: String?, clipboard: String?, now: Date,
                           calendar: Calendar = .current) -> (text: String, unresolved: [String]) {
    guard body.contains("{"), let regex = try? NSRegularExpression(pattern: "\\{(项目|日期|剪贴板|project|date|clipboard)\\}") else {
        return (body, [])
    }
    let clip = clipboard.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String($0.prefix(20_000)) }
    let day = DailyStats.dayKey(now, calendar: calendar)
    let values: [String: String?] = ["项目": project, "project": project, "日期": day, "date": day, "剪贴板": clip, "clipboard": clip]
    var result = ""
    var cursor = body.startIndex
    var unresolved: [String] = []
    for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
        guard let whole = Range(match.range, in: body), let name = Range(match.range(at: 1), in: body) else { continue }
        result += body[cursor..<whole.lowerBound]
        if let value = values[String(body[name])] ?? nil { result += value }
        else {
            result += body[whole]
            if !unresolved.contains("{\(body[name])}") { unresolved.append("{\(body[name])}") }
        }
        cursor = whole.upperBound
    }
    result += body[cursor...]
    return (result, unresolved)
}

/// Returns the template file text with a new template added at the end of the main (non-"更多") part.
/// Nil when the title or body is unusable.
public func insertingTemplate(into text: String, title: String, body: String) -> String? {
    let cleanTitle = String(title.components(separatedBy: .newlines).joined(separator: " ")
        .drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces).prefix(60))
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty, !isMoreMarker(cleanTitle), !trimmedBody.isEmpty, trimmedBody.count <= 20_000 else { return nil }
    // A body line starting with "## " would be read as a new template; indent it.
    let safe = trimmedBody.components(separatedBy: "\n").map { $0.hasPrefix("## ") ? " " + $0 : $0 }
    let block = ["## " + cleanTitle] + safe + [""]
    var lines = text.components(separatedBy: "\n")
    if let marker = lines.firstIndex(where: { isMoreMarker(String($0.trimmingCharacters(in: .whitespaces).dropFirst(3))) && $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ") }) {
        lines.insert(contentsOf: block, at: marker)
    } else {
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        lines += [""] + block
    }
    return lines.joined(separator: "\n")
}
