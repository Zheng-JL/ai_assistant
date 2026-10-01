# 隐私说明

[English](privacy.md)

这一页写明本工具读取什么、保存什么、发送什么。如果代码和这一页不一致，那就是 bug，请提 issue。

**一句话总结**

- 一切都在你的 Mac 上运行。**没有遥测、没有统计、没有检查更新、没有账号。**
- 唯一的网络代码是**可选的 AI 总结**（以及它的“测试连接”按钮）。它只把数据发到**你自己填写的接口**，而且只在你点击时才发。
- 对 Codex 和 Claude 是**只读**的：不修改它们的文件、设置和会话，也不会往会话里发消息。
- 没有第三方依赖，所以没有第三方代码能看到你的数据。

## 1. 始终会读取的内容

状态检测只读取本地文件里有限的一小段，并且只解码**白名单字段**，不解码消息正文、命令、工具参数和工具输出。

| 来源 | 用到的内容 |
| --- | --- |
| `~/.codex/.codex-global-state.json` | “未读”相关字段 |
| `~/.codex/session_index.jsonl` | 会话 ID；仅对已确认是主会话的才解码标题 |
| `~/.codex/sessions/`、`archived_sessions/` | 目录列表；rollout 文件第一行（来源、工作目录——只保留**最后一级文件夹名**） |
| `~/.codex/sessions/**/rollout-*.jsonl` | 轮次开始/完成事件、时间戳、“等待输入”调用的 ID，以及 `token_count` 事件 |
| `~/.claude/sessions/<PID>.json`（每个 ≤ 64 KiB） | `pid`、进程启动时间、`version`、`entrypoint`、`kind`、`sessionId`、`hostSessionId`、`status`、`statusUpdatedAt`、agent 标记、`spare`、`cwd`（只保留最后一级文件夹名）、`name`（标题） |
| `~/.claude/projects/**/*.jsonl` | **只读当天有改动的文件**；只解码 `timestamp`、`cwd`、消息 `id` 和 `usage` 计数，用于 Token 统计 |
| macOS `libproc` | Codex/Claude 进程的身份、父子关系和可执行文件路径；已核验的 Codex 引擎的打开文件*路径*。不读文件内容、不加锁、不控制进程 |

**不会**读取：认证文件、Cookie、其他应用的钥匙串条目、进程环境变量、日志数据库，以及上述之外的任何 Claude/Codex 配置。

需要说明的是，上面这些文件本身*包含*对话正文；状态代码会分块读取它们的字节，但不会把消息正文放进自己的数据结构。

## 2. 保存在本机的内容

| 内容 | 位置 | 包含 |
| --- | --- | --- |
| 偏好设置与计数 | `UserDefaults`，Bundle ID `com.zhengjl.codexstatus`；键：`notificationsEnabled`、`notificationsMutedUntil`、`notificationMinimumSeconds`、`quietStartHour`、`quietEndHour`、`stuckAfterMinutes`、`contextAlertPercent`、`dailyTokenBudget`、`budgetAlertedDay`、`keepAwakeWhileRunning`、`summaryAPIFormat`、`summaryEndpoint`、`summaryModel`、`summaryConfirmedHost`、`summaryMaxChars`、`recentFinished`、`dailyStats`、`dailyLog`、`tokenHistory` | 设置；**最近 8 个完成的任务**和**当天完成的任务**（最多 300 条），含**任务标题、项目文件夹名、时间、用时**；每天的 Token 合计 |
| 提示词模板 | `~/Library/Application Support/Codex Status/prompts.md` | 你自己写的文字 |
| AI 总结产物 | `…/journal/YYYY-MM-DD.md`、`…/lessons.md`（及 `lessons.md.bak`） | 模型写的总结，可能提到你对话里的内容 |
| 安装脚本的备份 | `…/previous/*.zip` | 本应用上一个版本 |
| API Key | macOS 钥匙串，服务名 `com.zhengjl.codexstatus.llm` | 你填写的 Key |

菜单 → *最近完成* → *清空历史* 会清除最近完成列表、当天日志和当天计数。其余内容可手动删除；删掉上面的文件夹和 `UserDefaults` 域，应用就回到干净状态。

会话标题可能涉及隐私。它们会显示在你自己屏幕上的菜单和通知里，并保存在上面两处；除非你使用 AI 总结，否则不会出现在别的地方。

## 3. 会发送什么（只有 AI 总结）

在**你**配置好接口和 Key 并点击“现在总结今天…”（或“测试连接”，它只发一个词 “ping”）之前，什么都不会发送。第一次向某个地址发送前，会弹窗显示收件地址、会话与消息数量、大小和估算 token 数；可勾选“该地址不再询问”，改了地址会重新询问。

**正文是怎么准备的：**只有在你点击“现在总结今天…”的那一刻，应用才会读取第 1 节同样的目录（`~/.claude/projects`、`~/.codex/sessions`）里当天的会话文件，并在内存里解码当天对话的*消息正文*来组装请求。这一步除了模型返回的总结，不会保存任何东西。（`--summarize-plan` 命令做同样的准备，但只打印统计数字。）

**会发送：**
- *当天*对话里人能读的文字：你说的话和 AI 回复的文字，逐条裁剪并限制总量（默认约 6 万字符；超出则压缩，优先保留你的原话和每个会话的开头与结尾）；
- 项目文件夹名、会话短 ID 和钟点；
- 你现有的 `lessons.md`（最多 8000 字符），让模型合并；
- 固定的指令文字（见 `Sources/CodexStatusCore/SummaryPrompt.swift`）。

**绝不发送：**工具调用及其输出、命令结果、文件内容、隐藏的推理、图片与附件、系统/开发者/注入的上下文（如环境信息、`AGENTS.md`）、子智能体对话、其他日期的消息，以及你的 API Key（它只放在发给你所选接口的请求头里）。

**发送前脱敏**（尽力而为，基于正则）：私钥块、`sk-…` / `rk-…` 密钥、`sk_live_…` 类密钥、AWS `AKIA…`、GitHub 令牌（`ghp_…`、`github_pat_…`）、Slack `xox…`、`Bearer …`、JWT、URL 里的 `user:password@`，以及 `api_key=…`、`secret: …`、`password=…`、`token=…` 这类赋值。确认框会显示隐藏了多少处。**它识别不了自定义格式的机密。**请不要在准备总结的对话里输入机密。

**地址规则：**远程地址必须是 `https`；只有 `localhost`、`127.0.0.1`、`::1` 允许 `http`。错误信息里不会出现 Key。

**谁会收到：**你所配置接口的运营方，适用*他们*的条款和数据保留策略。请注意：Codex 的对话文字原本只会发给 OpenAI，通过别的服务商来总结是你主动选择的新数据流向。每次请求都会消耗该接口的 token。

## 4. 剪贴板

只有在你复制含 `{剪贴板}` / `{clipboard}` 的模板，或选择“把剪贴板存为模板…”时才会读取剪贴板；复制模板、日报或踩坑清单时会写入剪贴板。粘进模板的剪贴板内容不会被记录。

## 5. 其他

- 应用会向 macOS 申请通知权限；如果你启用，还会创建登录项。这两项都是标准系统功能，可在“系统设置”里撤销。
- “保持唤醒”在任务运行期间使用标准的电源断言接口，不需要权限。
- 全局快捷键使用系统热键接口，不需要“辅助功能”或“输入监控”权限。
- 应用是 ad-hoc 签名、未公证的。你下载的构建只能和你获取它的渠道一样可信；从源码构建可以先读代码。
