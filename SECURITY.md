# Security Policy / 安全政策

## Reporting a vulnerability / 报告漏洞

Please **do not open a public issue** for security problems.
Use GitHub's private vulnerability reporting: the repository's **Security** tab → **Report a vulnerability**.

请不要用公开 issue 报告安全问题，请使用仓库 **Security** 标签页里的 **Report a vulnerability**（私密报告）。

This is a small volunteer project. Reports are handled on a best-effort basis; there is no guaranteed response time.

## What counts as a security issue / 属于安全问题的范围

- Anything that makes the app **send data somewhere it should not**. The only network code is the optional AI summary (`Sources/CodexStatusCore/ModelClient.swift`); it must only run after the user configures an endpoint and confirms.
- Leaking or mishandling the **API key** (it must only live in the macOS Keychain and never reach logs, error messages, preferences or files).
- Bypassing the **redaction** step or the **allow-list** of what is extracted from conversation logs.
- Unsafe handling of **file paths or URLs** (for example building a `claude://` or `codex://` link from an unvalidated identifier, or following symbolic links out of the expected folders).
- Anything that lets the app **modify** Codex or Claude data, which it is designed never to do.

Not security issues: the app showing `?` / `--` after Codex or Claude changes an internal file format (it relies on undocumented formats and is designed to show "unknown"); redaction missing a secret in a **custom** format (it is documented as best-effort).

## Supported versions / 支持的版本

Only the latest release and `main` receive fixes.

## Handling of secrets / 机密处理

See [docs/privacy.md](docs/privacy.md) for exactly what the app reads, stores and sends.
