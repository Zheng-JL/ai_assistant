# Architecture

How the app works, which undocumented things it relies on, and how to re-verify it after Codex or Claude update. (English only for now; the user-facing documentation is in both languages.)

## Overview

```
                 every 3 s                         ┌──────────────────────────┐
 ~/.codex ──────► LocalStatusSource ─┐             │  TransitionDetector       │──► Notifier (banners)
 libproc ───────►                    ├─► Snapshot ─►  (finished / waiting /     │──► HistoryStore, DailyLog
 ~/.claude/sessions ► ClaudeStatusSource ┘  Smoother │   long-running)          │
 today's logs ───► TokenUsageSource ──► TokenReport ─► ContextAlertTracker,     │──► menu (MenuController+…)
                                                     │  budget, TokenHistory     │
                                                     └──────────────────────────┘
 on demand only:  TranscriptExtractor ► Redactor ► SummaryPrompt ► ModelClient ► journal / lessons
```

## Modules

| Target | Role |
| --- | --- |
| `Sources/CodexStatusCore` | Everything that is not UI. All of it is unit-tested with synthetic data. |
| `Sources/CodexStatusApp` | The menu-bar app: `MenuController` (lifecycle, sampling) plus extensions `+Sections`, `+Templates`, `+Settings`, `+Opening`, `+Health`; `Notifier`, `HistoryStore`, `SummaryCoordinator`, `KeychainStore`, `IconArt`, … |
| `Sources/ProcessInspection` | A small C module around `libproc`: process identity, parent/child relations, executable paths and the open-file paths of the Codex engine. |

Key types in Core: `StatusSnapshot` / `SessionStatus` (what the UI shows), `TransitionDetector` (turns snapshots into events), `SnapshotSmoother`, `TokenUsageSource`, `ContextAlertTracker`, `DailyReport`, `HealthCheck`, and for the optional summary `TranscriptExtractor`, `Redactor`, `SummaryPrompt`, `ModelClient`, `DailySummarizer`.

## Design principles

1. **Unknown beats wrong.** Every source can return "I can't establish this". The UI then shows `?` / `--`. Counts are `Int?`, never defaulted to 0. A one-off unknown is hidden by `SnapshotSmoother`; a persistent one is shown.
2. **Verify identity, twice.** A process only counts if its path, owner and start time match, and the start times are re-checked after the scan (PIDs get reused).
3. **Bounded, allow-listed reads.** Files are read in capped chunks (8 MiB for status files). `Decodable` types name only the fields they need, so message text is never decoded by status code. Symbolic links are not followed, and the Claude registry files and the token readers require the file to belong to the current user.
4. **Never write to the other apps.** Read-only everywhere. The only things the app writes are its own files (see [privacy.md](privacy.md)).
5. **Explicit opt-in for anything that reads text or uses the network.** Only the AI summary does, only on click, with a confirmation.

## What it relies on (all undocumented)

These are the fragile parts. They were observed on the versions listed in [verification.md](verification.md).

### Codex Desktop (`com.openai.codex`)

| Need | Source | Notes |
| --- | --- | --- |
| Is a session a main desktop session? | first line of `~/.codex/sessions/**/rollout-*.jsonl` (`session_meta`): `originator == "Codex Desktop"`, `source == "vscode"` | sub-agents have `source.subagent`, CLI has `cli` |
| Is it in the index? | `~/.codex/session_index.jsonl` | un-indexed internal threads are ignored |
| Running | latest `task_started` without a later `task_complete`/`turn_aborted`, **and** the bundled engine process holds that session's writer file, **and** the process started before the turn | engine path: `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`; writer locks in `~/.codex/thread-writer-locks/` |
| Waiting for you | an unanswered `request_user_input` function call | other approvals are not exposed and count as running |
| Finished + unread | `task_complete` plus Codex's own read state in `~/.codex/.codex-global-state.json` → `electron-thread-read-state-v1` → key `local:<sha256 of the standard local host>` | the key constant is covered by a test; multi-identity or legacy shapes give *unknown* |
| Tokens / context | `token_count` events: cumulative `total_token_usage` (only the growth is counted), `last_token_usage`, `model_context_window` | |

### Claude Desktop (`com.anthropic.claudefordesktop`)

| Need | Source | Notes |
| --- | --- | --- |
| Live engines | child processes whose executable is `~/Library/Application Support/Claude/claude-code/<major.minor.patch>/claude.app/Contents/MacOS/claude` | any numeric version is accepted; the path shape is strict |
| Session state | `~/.claude/sessions/<PID>.json` for each live engine: `status` is `busy` / `waiting` / `idle` / `shell`; `entrypoint == "claude-desktop"`, `kind == "interactive"` | process start time in the file must match the real process |
| Version | `version` in that file | only `2.1.284` was verified by hand; others read the same way but add a visible "unverified version" notice. An unknown `status` word gives *unknown* |
| Jump to a session | `claude://code/continue?session=<hostSessionId>` | route taken from the Claude app's own code; the id must match `^local_[A-Za-z0-9-]{1,64}$` or no link is built |
| Tokens / context | `~/.claude/projects/**/*.jsonl` assistant `message.usage`, de-duplicated by message id | the context window is not in the logs |
| Finished + unread | *not available* | no reliable source was found, so it is not shown |

## Notifications

`TransitionDetector` remembers only sessions it has seen *active*, so the first sample after launch never notifies. Events: finished (idle/completed after active), needs input, long-running (once per run). `ContextAlertTracker` alerts once per session at the threshold and re-arms 20 points below. Delivery goes through `UNUserNotificationCenter`; macOS only grants that to apps in `~/Applications` or `/Applications`, and keys the icon to the bundle identifier — see *Troubleshooting* in the README for the stale-registration problem this caused.

## After Codex or Claude update

1. Run `CodexStatus --health`. A `⚠` on Codex or Claude names the cause.
2. Run `CodexStatus --diagnose --details` for the raw per-session view (statistics and ids, no titles or text).
3. Look at the table above and compare with a fresh log from the new version (use *your own* logs locally; don't commit them).
4. Constants live in: `RolloutState.swift` (origin/source), `UnreadState.swift` (read-state shape and host key), `ClaudeStatusSource.swift` (`verifiedVersion`, statuses), `ProcessInspection.c` (engine paths).
5. Add a test with a **synthetic** record in the new shape, then change the code.

## Testing

- `swift test` — all tests use synthetic temporary files; nothing touches real sessions.
- UI is verified without screen-recording permission through headless commands: `--dump-menu` prints the whole menu tree (diff it before/after a refactor), `--health`, `--dump-report`, `--summarize-plan`.
- The AI summary client is tested against a mocked `URLProtocol`; the end-to-end path was also exercised against a local fake endpoint.
- What cannot be tested automatically: visual appearance, real notification rendering, real model endpoints. See [verification.md](verification.md).

## Adding another tool

Implement a source that returns a `StatusSnapshot` (with `nil` counts when unsure), feed it through `SnapshotSmoother` and `TransitionDetector` like the existing two, and add a section in `MenuController`. Read-only, allow-listed decoding, identity checks and synthetic tests are expected (see [CONTRIBUTING.md](../CONTRIBUTING.md)).
