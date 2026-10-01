# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-01

First public release (formerly an internal tool called "Codex Status").

### Added
- Single compact menu-bar item for Codex Desktop and Claude Desktop (Claude Code) sessions: running / waiting / unread counts as coloured dots; unknown states show `?` or `--`, never a made-up zero.
- Notifications for finished tasks, tasks waiting for you, long-running tasks, near-full context windows and budget overruns; three-line layout with a status badge, "Open" and "Mute 1 hour" buttons, thresholds, quiet hours and mute.
- Per-session elapsed time, grouping by project, recent-finished list, today's summary, and a copyable daily report.
- Token usage for today (new input / output / cache hits, by project), context-window usage, an optional daily budget and a 7-day trend.
- Prompt templates in a plain Markdown file, with `{项目}`, `{日期}`, `{剪贴板}` variables, "save clipboard as template" and a global shortcut.
- Optional, manual AI summary: your own endpoint, model name and API key (OpenAI-compatible or Anthropic format), secret redaction before sending, a confirmation dialog, a daily journal and a long-term "lessons learned" list.
- Jump to a Codex thread or a Claude Code session from the menu or a notification.
- Claude Code engine detection accepts any numeric `major.minor.patch` engine folder (the path shape is still checked strictly); a version other than the hand-verified `2.1.284` is flagged as "unverified" in the menu instead of making the whole Claude side unreadable.
- Keep-awake while tasks run, launch at login, global shortcuts, and a built-in health check (`检查运行状况…` / `--health`).
- Safe installer (`scripts/install.sh`): builds, tests, verifies the signature, backs up, replaces, and rolls back on failure.

### Known limitations
- Relies on undocumented local file formats of Codex Desktop and Claude Desktop.
- Ad-hoc signed, not notarized.
- Verified only on macOS 26.6 / Apple Silicon. See [docs/verification.md](docs/verification.md).
