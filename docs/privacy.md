# Privacy

[简体中文](privacy.zh-CN.md)

This page says exactly what the app reads, keeps and sends. If the code and this page ever disagree, that is a bug — please open an issue.

**Summary**

- Everything runs on your Mac. There is **no telemetry, no analytics, no update check, no account**.
- The only network code is the **optional AI summary** (and its "Test connection" button). It sends data to **the endpoint you type in**, and only when you click.
- The app is **read-only** with respect to Codex and Claude: it never modifies their files, settings or sessions, and never sends messages into a session.
- There are no third-party dependencies, so no third-party code sees your data.

## 1. What the app reads (always on)

Status detection reads small, bounded parts of local files and only *decodes allow-listed fields*. It does not decode message text, commands, tool arguments or tool output.

| Source | What is used |
| --- | --- |
| `~/.codex/.codex-global-state.json` | the "unread" fields |
| `~/.codex/session_index.jsonl` | session IDs; the title is decoded only for sessions confirmed as main sessions |
| `~/.codex/sessions/`, `archived_sessions/` | folder listing; the first line of rollout files (origin, working directory — only the **last folder name** is kept) |
| `~/.codex/sessions/**/rollout-*.jsonl` | turn start/complete events, timestamps, ids of "waiting for input" calls, and `token_count` events |
| `~/.claude/sessions/<PID>.json` (≤ 64 KiB each) | `pid`, process start, `version`, `entrypoint`, `kind`, `sessionId`, `hostSessionId`, `status`, `statusUpdatedAt`, an agent marker, `spare`, `cwd` (last folder name only), `name` (title) |
| `~/.claude/projects/**/*.jsonl` | **only files changed today**; only `timestamp`, `cwd`, message `id` and the `usage` token counters are decoded, for the token statistics |
| macOS `libproc` | identity, parent/child relation and executable path of the Codex/Claude processes; open-file *paths* of the verified Codex engine. It does not read file contents, take locks or control processes |

It does **not** read: authentication files, cookies, other apps' Keychain items, process environments, log databases, or any Claude/Codex configuration beyond the above.

Note that the files above *contain* conversation text; the status code reads their bytes in bounded chunks but never puts message text into its data structures.

## 2. What the app keeps on disk

| What | Where | Contains |
| --- | --- | --- |
| Preferences and counters | `UserDefaults`, bundle id `com.zhengjl.codexstatus`; keys: `notificationsEnabled`, `notificationsMutedUntil`, `notificationMinimumSeconds`, `quietStartHour`, `quietEndHour`, `stuckAfterMinutes`, `contextAlertPercent`, `dailyTokenBudget`, `budgetAlertedDay`, `keepAwakeWhileRunning`, `summaryAPIFormat`, `summaryEndpoint`, `summaryModel`, `summaryConfirmedHost`, `summaryMaxChars`, `recentFinished`, `dailyStats`, `dailyLog`, `tokenHistory` | settings; the **last 8 finished tasks** and **today's finished tasks** (up to 300) with **task title, project folder name, time and duration**; per-day token totals |
| Prompt templates | `~/Library/Application Support/Codex Status/prompts.md` | text you wrote |
| AI summary output | `…/journal/YYYY-MM-DD.md`, `…/lessons.md` (+ `lessons.md.bak`) | model-written summaries — they can mention things from your conversations |
| Installer backup | `…/previous/*.zip` | the previous build of this app |
| API key | macOS Keychain, service `com.zhengjl.codexstatus.llm` | the key you entered |

Menu → *Recent finished* → *Clear history* removes the recent list, today's log and today's counters. Everything else can be deleted by hand; deleting the folder above and the `UserDefaults` domain returns the app to a clean state.

Session titles can be private. They are shown in the menu and in notifications on your own screen, and kept in the two places above — never anywhere else unless you use the AI summary.

## 3. What the app sends (only the AI summary)

Nothing is sent until **you** configure an endpoint and key and click *Summarize today…* (or *Test connection*, which sends only the word "ping"). Before the first send to a host, a dialog shows the destination host, the number of sessions and messages, the size and an estimated token count; you can tick "don't ask again for this host", and changing the endpoint resets that.

**How the text is prepared:** only at that moment — when you click *Summarize today…* — the app reads today's session files in the same folders as in section 1 (`~/.claude/projects`, `~/.codex/sessions`) and decodes the *message text* of today's conversations, in memory, to build the request. Nothing from this step is stored except the summary the model returns. (The `--summarize-plan` command does the same preparation but prints only statistics.)

**Sent:**
- the human-readable text of *today's* conversations: your messages and the assistant's text replies, each shortened, with a total cap (default ≈ 60,000 characters; above the cap the text is compressed, keeping your own words and the start and end of each session);
- project folder names, session short ids and clock times;
- your current `lessons.md` (up to 8,000 characters) so the model can merge it;
- the fixed instructions (see `Sources/CodexStatusCore/SummaryPrompt.swift`).

**Never sent:** tool calls and their output, command results, file contents, hidden reasoning, images and attachments, system/developer/injected context (for example environment info or `AGENTS.md`), sub-agent conversations, messages from other days, your API key (it travels only in the request header to the endpoint you chose).

**Redaction before sending** (best effort, regex based): private-key blocks, `sk-…`/`rk-…` keys, `sk_live_…`-style keys, AWS `AKIA…`, GitHub tokens (`ghp_…`, `github_pat_…`), Slack `xox…`, `Bearer …`, JWTs, `user:password@` in URLs, and assignments such as `api_key=…`, `secret: …`, `password=…`, `token=…`. The dialog shows how many were hidden. **It cannot recognise secrets in custom formats.** Do not type secrets into conversations you intend to summarise.

**Endpoint rules:** remote endpoints must be `https`; plain `http` is allowed only for `localhost`, `127.0.0.1` and `::1`. Error messages never contain the key.

**Who receives it:** whoever operates the endpoint you configured, under *their* terms and retention policy. Note that Codex conversation text normally goes only to OpenAI; summarising it through another provider is a new data flow that you are choosing. Each request consumes tokens on that endpoint.

## 4. Clipboard

The clipboard is read only when you copy a template that contains `{clipboard}` / `{剪贴板}`, or when you choose *Save clipboard as template…*. It is written when you copy a template, the daily report or the lessons list. Clipboard text pasted into a template is not logged.

## 5. Other things to know

- The app asks macOS for notification permission and, if you enable it, creates a login item. Both are standard system features you can revoke in System Settings.
- "Keep the Mac awake" uses the standard power-assertion API while tasks run; it needs no permission.
- Global shortcuts use the system hot-key API and need no Accessibility or Input Monitoring permission.
- The app is ad-hoc signed and not notarized. Builds you download are only as trustworthy as where you got them from; building from source lets you read the code first.
