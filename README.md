<p align="center">
  <img src="Resources/AppIcon-preview.png" width="128" alt="搭子 / Buddy app icon">
</p>

<h1 align="center">搭子 · Buddy</h1>

<p align="center">
  A macOS menu-bar companion for AI coding.<br>
  It watches your local <b>Codex Desktop</b> and <b>Claude Desktop (Claude Code)</b> sessions and nudges you when a task finishes,<br>
  an assistant is waiting for you, a context window is nearly full, or you pass a daily token budget.
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a> · <a href="docs/privacy.md">Privacy</a> · <a href="docs/architecture.md">Architecture</a> · <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <a href="https://github.com/Zheng-JL/ai_assistant/actions/workflows/ci.yml"><img src="https://github.com/Zheng-JL/ai_assistant/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey.svg" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen.svg" alt="No dependencies">
</p>


> **Unofficial.** Not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic. "Codex", "ChatGPT" and "Claude" are trademarks of their owners and are used here only to describe compatibility.

> **Read this first — compatibility.** The app reads *undocumented* local files of Codex Desktop and Claude Desktop. It has been verified only on **macOS 26.6 (Apple Silicon)** with **Codex Desktop 26.924.22138** and **Claude Desktop 2.16120.0** (Claude Code engine 2.1.284). A future update of either app can change those formats. The app is built to show **unknown** (`?` / `--`) rather than a wrong number, and a built-in health check tells you why — but expect to need an update after big releases.

## Screenshots

<p align="center">
  <img src="docs/screenshots/menu.png" width="300" alt="The menu: running and unread counts, today's totals, tokens, templates, settings">
  &nbsp;&nbsp;
  <img src="docs/screenshots/menu-templates.png" width="420" alt="The prompt-template menu with its “More” submenu">
</p>

<sub>macOS 26.6, light mode. The interface is in Chinese; <code>CodexStatus --dump-menu</code> prints the exact menu tree.</sub>

## Why

Waiting on AI coding tools wastes time in three ways: you watch a screen until a task is done, an assistant sits stopped waiting for your approval, and a conversation quietly gets so long that the model forgets earlier context. Buddy puts all of that in the menu bar and notifies you only when something needs you.

## Features

**At a glance**
- One compact menu-bar item for both tools: coloured dots with counts — green *running*, orange *waiting for you*, blue *finished, unread*. Zero counts are hidden; when everything is idle only the icon remains.
- Honest about uncertainty: a state that cannot be established shows `?` / `--`, never a made-up `0`.
- Per-session elapsed time, grouping by project folder, a recent-finished list, and a one-click daily report.

**Notifications**
- Finished (with a minimum-duration threshold so short tasks don't nag), waiting for your input or approval, running unusually long, context window nearly full, daily budget exceeded.
- Three-line layout — what happened / project and duration / task name — with a status badge and **Open** / **Mute 1 hour** buttons. Click to jump to the Codex thread or Claude Code session.
- Quiet hours, mute, and per-kind thresholds.

**Tokens and context**
- Today's token usage per tool, split into new input / output / cache hits, by project, with a 7-day trend and an optional daily budget. Shows usage only — no prices, and no plan quota (that is not in the local logs).
- Context-window usage per session (a percentage for Codex; absolute size for Claude, whose logs don't state the window).

**Prompt templates**
- Reusable prompts in a plain Markdown file, one click to copy. Variables `{project}`, `{date}`, `{clipboard}` (Chinese `{项目}` `{日期}` `{剪贴板}` also work). "Save clipboard as template", project-scoped templates, and a global shortcut.

**Optional AI daily summary** *(off by default, manual only)*
- Sends the day's conversation text to **an endpoint you configure** (OpenAI-compatible or Anthropic format, your own model name and key) and writes a daily journal plus a long-term "lessons learned" list you can paste into new sessions. See [How the AI summary works](#ai-daily-summary) and [docs/privacy.md](docs/privacy.md) before using it.

**Utilities**
- Keep the Mac awake while tasks run (off by default), launch at login, global shortcuts `⌃⌥⌘J` (menu) and `⌃⌥⌘K` (templates), and **Check status…** — a health check that explains why something shows `?`.

## Requirements

- macOS 14 or later (verified on macOS 26.6, Apple Silicon only).
- Codex Desktop and/or Claude Desktop installed and used on this Mac.
- To build from source: Xcode 16+ / a Swift 6 toolchain. There are **no third-party dependencies**.

## Install

Building from source is the recommended way:

```sh
git clone https://github.com/Zheng-JL/ai_assistant.git
cd ai_assistant
bash scripts/install.sh
```

`scripts/install.sh` builds, runs the tests, checks the signature, backs up any previous version, installs `搭子.app` into `~/Applications` and starts it. If the new version fails to start it restores the previous one; if the build or tests fail, your installed app is left untouched.

- **Install into `~/Applications` or `/Applications`.** macOS only grants notification permission (and shows the notification icon) for apps there. Don't `open` copies from `/tmp`.
- **Pre-built zips** (if published on the Releases page) are only *ad-hoc signed* and **not notarized** (there is no paid Apple Developer account behind this project). Gatekeeper will likely block the first launch; building from source avoids that. Opening an unsigned download is your decision.
- The app does not install anything else, does not register a login item unless you tick it, and shows no Dock icon — quit from the menu.

On first launch allow notifications when macOS asks.

## Using it

Click the menu-bar icon (or press `⌃⌥⌘J`). An example, with made-up data:

```
Codex
  Local · 10:41:07
  ● Running  1  ▸
        Fix login failure  ·  6 min  ·  Context 41%
  ● Finished, unread  0
────────
Claude Code
  ● Running  0
  Idle  2  ▸
        Write the release notes  ·  12 min ago
────────
Today: 7 finished · 52 min total · longest 14 min
Recent finished  ▸
Copy today's report
AI summary & lessons  ▸
Today's tokens (excl. cache)
  Codex   63.4K  ▸  new input / output / cache hits / by project
  Claude  403.6K ▸
Prompts  ▸
────────
Refresh · Open Codex · Open Claude
Notifications · Mute 1 hour · Settings ▸ · Check status…
Quit
```

(The real menu is in Chinese. `CodexStatus --dump-menu` prints the exact current tree.)

### Prompt templates

Templates live in `~/Library/Application Support/Codex Status/prompts.md` and are created with examples on first use. The app never overwrites your file.

```markdown
## Read first, then edit
Read the relevant code, explain your plan, and wait for my OK before changing anything.

## Fix this error @my-app
Analyse the error below in {project} and find the cause before touching code:
{clipboard}

## More
## Commit message
Write a commit message for this change: ...
```

- `## Title` starts a template; everything below it is the text that gets copied. A lone `## More` (or `## 更多`) line moves the templates after it into the "More" submenu.
- Append ` @project-folder-name` to a title to show it only when that project has a session.
- Variables are replaced in a single pass (text inserted from the clipboard is never expanded again); a missing value is left as written and flagged in the menu bar. The clipboard is read only for templates that contain `{clipboard}`.

### AI daily summary

Disabled until you configure it, and it only runs when you click **"Summarize today…"**.

1. Menu → *AI summary & lessons* → *Settings…*: API format (OpenAI-compatible or Anthropic), endpoint URL, model name, API key. The key is stored **only in the macOS Keychain**.
2. *Test connection* sends a single "ping".
3. *Summarize today…* shows a confirmation with the destination host, the number of sessions and messages, size and an estimated token count, then sends the request.

Results are plain Markdown in `~/Library/Application Support/Codex Status/`: `journal/YYYY-MM-DD.md` and `lessons.md` (merged and de-duplicated by the model each time, max 30 entries; the previous one is kept as `lessons.md.bak`).

What is sent: only the human-readable text of that day's conversations (your messages and the assistant's replies), shortened and capped (about 60k characters by default), after best-effort secret redaction. Never sent: tool calls and output, command results, file contents, hidden reasoning, images, injected system context, sub-agent chatter. Remote endpoints must be `https`; `localhost` may use `http`. **Redaction is regex-based and cannot catch secrets in custom formats — don't put secrets in conversations.** Quality depends on the model you choose. Each run consumes tokens on your endpoint.

## Where things are stored

| What | Where |
| --- | --- |
| Preferences, recent finished, today's log, token history | the app's `UserDefaults` (bundle id `com.zhengjl.codexstatus`) |
| Prompt templates | `~/Library/Application Support/Codex Status/prompts.md` |
| Daily journal, lessons | `~/Library/Application Support/Codex Status/journal/`, `lessons.md` |
| Previous app version (installer backup) | `~/Library/Application Support/Codex Status/previous/` (zip) |
| API key | macOS Keychain, service `com.zhengjl.codexstatus.llm` |

The folder and bundle identifier keep the project's original name ("Codex Status") so existing users keep their settings. Forks that ship their own build should change the bundle identifier.

## Troubleshooting

Start with **Check status…** in the menu (or run `CodexStatus --health`). It reports install location, icon, duplicate registrations, notification permission, Codex, Claude, token stats, AI summary and shortcuts, with a reason for each problem.

- **Shows `?` or `--` for Codex/Claude** — the app could not verify the state, usually after an app update changed an internal format. Check *Check status…*, then open an issue with its output and your app versions.
- **No notifications** — the app must run from `~/Applications` or `/Applications`; then allow it in *System Settings → Notifications*.
- **Notification has a blank icon instead of the app icon** — macOS cached the icon from before the app had one, or another copy of the app (same bundle id) is registered. Remove stray copies (`lsregister -u <path>`), then quit `NotificationCenter` and `iconservicesagent` (macOS restarts them) and delete the per-user caches `$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices` and `com.apple.iconservicesagent`. Old notifications keep their old icon; test with `CodexStatus --notify-test`.
- **Keychain asks for permission after reinstalling** — each build is signed ad-hoc, so macOS sees a "new" app. Choose *Always Allow*.

## Compatibility and limits

- Counts only **main interactive sessions of the desktop apps**. Terminal CLI sessions, archived or remote sessions, sub-agents, Cowork and cloud sessions are not counted.
- Codex: needs the default `~/.codex` (no custom `CODEX_HOME`), a single persisted read identity and the default local execution store. "Unread" comes from Codex's own read-state file; other formats show unknown.
- Claude: "finished and unread" has no reliable source in the local files, so it is not shown. Session jump uses a `claude://` link taken from the app's own routes and a `local_…` id from its registry files; if a session has no usable id the row is greyed out.
- Permission approvals that Codex does not expose still count as *running* (explicit `request_user_input` waits are shown separately).
- Per-file read limit of 8 MiB for status files. Oversized or damaged files give *unknown*, not zero.
- A Codex session forked from another one on the same day can double-count the inherited token usage.
- Not tested: Intel Macs, macOS versions other than 26.6, other app versions, the appearance of every dialog on every display. See [docs/verification.md](docs/verification.md) for exactly what has and has not been checked.

## Developing

```sh
swift test                  # synthetic data only
bash scripts/build-app.sh   # build + ad-hoc sign into a fresh temp folder (does not install)
bash scripts/install.sh     # build, test, back up, replace, roll back on failure
bash scripts/make-icon.sh   # regenerate Resources/AppIcon.icns from IconArt.swift
```

Useful headless commands (run the binary inside the installed `.app`): `--health`, `--diagnose [--details]`, `--dump-menu`, `--dump-report`, `--summarize-plan` (statistics only, prints no conversation text), `--notify-test`, `--keychain-selftest`, `--make-icon <dir>`, `--make-glyph <png>`, `--make-badges <png>`. See [docs/architecture.md](docs/architecture.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 ZhengJL. No warranty; read [docs/privacy.md](docs/privacy.md) before enabling the AI summary.
