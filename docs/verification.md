# Verification / 验证说明

An honest list of what has and has not been checked. 如实列出哪些检查过、哪些没有。

Last updated: 2026-10-01, release 0.2.0.

## Environment checked / 验证环境

| | |
| --- | --- |
| macOS | 26.6, Apple Silicon (arm64) — **only this** |
| Swift | 6.3 |
| Codex Desktop | 26.924.22138 (`com.openai.codex`) |
| Claude Desktop | 2.16120.0, Claude Code engine 2.1.284 |

## Automated / 自动化

- `swift test`: **194 tests pass**, all on synthetic temporary data. They cover state detection for both tools (including damaged, truncated, mixed-up and hostile inputs), notification logic, token counting and de-duplication, context alerts, budget, daily report, prompt templates, secret redaction, conversation extraction, prompt budgeting, both model API formats (against a mocked URL protocol), health-check rules, and the Claude engine path rules.
- CI (`.github/workflows/ci.yml`) runs the tests, a release build and a shell syntax check on GitHub's `macos-15` runner (Xcode 16.4, macOS 15 SDK) and passes. Its first run found two real problems that the author's newer toolchain hid — `UNNotificationSettings` / `UNUserNotificationCenter` are not `Sendable` in the macOS 15.5 SDK — which are fixed. CI only compiles and runs the unit tests; it does not run the app.

## Checked against a real machine / 真实环境核对

- Token numbers (new input / cache / output) matched an independent script that re-computed them from the raw logs.
- A day's raw logs of ≈ 12 MB reduced to ≈ 27 thousand characters for the AI summary, with no tool output, reasoning or injected context left in; the full path was run against a **local fake endpoint** (the request shape, authentication header and absence of the API key in the body were checked).
- Keychain write / update / read / delete round trip with a throw-away item.
- Health check: all rows healthy on the author's machine; a deliberately planted stray copy of the app was detected and then cleaned up.
- Session jump: a deliberately malformed id produced a "link invalid" warning in Claude's log, while the real id produced none — so Claude accepts the id format.
- Installer: full runs, including replacing an older build and migrating from earlier app names.
- The notification icon problem (blank icon) was reproduced, diagnosed and fixed; the steps are in the README.

## Not verified / 没有验证

- **Appearance, partly.** The author's tooling cannot take screenshots (no screen-recording permission). The main menu, the template submenus and the notification banner were confirmed from screenshots the author supplied (macOS 26.6, light mode; see `docs/screenshots/`). **Not checked visually:** dark mode, the settings / send-confirmation / health-report dialogs, the "copied ✓" flash, multiple displays.
- **A real model endpoint.** The AI summary was never run against a real provider by the test suite. Different "OpenAI-compatible" providers differ; use *Test connection* first. The quality of the summaries has not been evaluated.
- **Other environments.** Intel Macs, macOS versions other than 26.6, other versions of Codex or Claude, multiple displays, light/dark mode on every surface.
- **Whether Claude's session jump lands on the right session** (the link is accepted; the destination could not be observed from logs).
- **Failure branches of the installer** (rollback when the new build fails to start) were reviewed but not exercised with injected faults.
- **Long-running behaviour** of the long-task reminder, quiet hours, budget alert and keep-awake over real sleep cycles: unit-tested only.
- **Gatekeeper behaviour** of a downloaded, ad-hoc-signed build on another Mac.
- **Performance** was measured on one machine (cold start of token statistics ≈ 50–90 ms, refresh ≈ 0 ms, ≈ 60 MB resident, ≈ 0.4 % idle CPU).

If you can fill any of these gaps, please open an issue or a pull request with what you tried and on which versions.
