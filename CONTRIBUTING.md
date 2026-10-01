# Contributing / 贡献指南

Thanks for helping! Issues and pull requests are welcome in **English or Chinese**.
欢迎提 issue 和 PR，中英文均可。

## Ground rules / 基本原则

These come from how the tool is built; please keep them when you change code.

1. **Never guess.** If a state cannot be established reliably, show *unknown* (`?`, `--`), not `0` and not a plausible value. Do not infer "running" or "read" from process counts, file modification times or idle status.
2. **Read-only.** The app must not modify Codex or Claude apps, settings, sessions or databases, and must not send messages into sessions.
3. **Privacy first.** Anything that reads conversation *text* or makes a network request must be explicit, user-triggered, documented in [docs/privacy.md](docs/privacy.md), and covered by tests. Status detection decodes only allow-listed fields.
4. **Synthetic data only in tests and issues.** Never commit or paste real conversation logs, session titles, tokens, API keys or paths from your machine.
5. **Fail loudly, degrade gracefully.** Unknown versions or formats should produce a visible notice, not a silent wrong number and not a total outage.

## Setup / 开发环境

- macOS 14 or later, Xcode 16+ (Swift 6 toolchain). No third-party dependencies.

```sh
git clone <your fork>
cd <repo>
swift test                  # all tests use synthetic data
bash scripts/build-app.sh   # build + sign (ad-hoc) into a new temp folder
bash scripts/install.sh     # build, test, back up, replace ~/Applications/搭子.app, roll back on failure
```

> Notifications only work when the app runs from `~/Applications` or `/Applications`. Do **not** `open` copies from `/tmp`: Launch Services keeps registering them under the same bundle identifier and the notification icon can go blank. See the troubleshooting section of the README.

## Project layout / 目录结构

See [docs/architecture.md](docs/architecture.md). In short: logic with no UI lives in `Sources/CodexStatusCore` (fully unit-tested); the menu-bar app is `Sources/CodexStatusApp`; process inspection in C is `Sources/ProcessInspection`.

## Before you open a pull request / 提交 PR 前

- [ ] `swift test` passes.
- [ ] New logic has tests, written with synthetic data.
- [ ] If you changed the menu, compare `CodexStatus --dump-menu` before and after (this works without screen-recording permission).
- [ ] If you touched data reading, run `CodexStatus --health` and `--diagnose` against a real Codex/Claude install and say what versions you tried.
- [ ] If you changed what is read or sent, update [docs/privacy.md](docs/privacy.md) and the README.
- [ ] Add a line to `CHANGELOG.md` under *Unreleased*.
- [ ] Say honestly what you could **not** verify (UI appearance, a particular app version, ...).

## Reporting compatibility problems / 兼容性问题

Codex Desktop and Claude Desktop change internal formats without notice. When something breaks after an update, open a *Bug report* and include the output of `CodexStatus --health` (review it first) and the app versions. Please do not attach raw session files.

## Commit style

Short imperative subject, then a paragraph on *why* if it is not obvious. One topic per commit.
