# ahem

**A macOS menu bar app that tells you which AI coding-agent session is waiting on you — one click from the window that needs you.**

Run five Claude Code sessions across five projects and the question is never "are they working?", it's "which one is stuck waiting for me?" ahem answers that from the menu bar, pings you the moment a session blocks, and puts you back in the right window with one click.

```
🔴2 🟢2
─────────────────────────────────────────────────────────
🔴 Fix flaky auth test · api · needs permission (2m)
🔴 Add empty state to the inbox · web · waiting for input (18m)
🟢 Port the CLI to Bun · tooling (4s)
🟢 rerun the migration · api/codex (12s)
⚪️ Draft release notes · docs · idle (3h)
⚪️ src · waiting for input (46m) · no window
```

🔴 blocked on you · 🟢 working · ⚪️ done with its turn

## Features

- **Live session status** — every Claude Code and Codex session in your menu bar, sorted by who needs you most, named after what it's actually working on.
- **Click to focus** — click a row and the right terminal window comes to the front, tab and split selected.
- **Native banners** — a session turning 🔴 posts a macOS notification with sound; click it to jump straight to that window.
- **Accurate, not just event-driven** — hook events are treated as a floor and corrected against real transcript activity, so a session running background subagents shows green, not idle.
- **Local and private** — reads files agents already write to disk. No accounts, no telemetry, no network.
- **Small** — a few hundred lines of Python and Swift. The status logic is one script you can read over coffee.

## Requirements

- macOS 13+
- [Claude Code](https://claude.com/claude-code) and/or [Codex CLI](https://github.com/openai/codex)
- A supported terminal: **Ghostty**, **Terminal.app**, or **iTerm2**
- Xcode Command Line Tools (`xcode-select --install`) to build the menu bar app

## Install

```sh
git clone https://github.com/hirokib/ahem && cd ahem
./install.sh                 # symlinks the CLI, wires the hooks, installs ahem.app
open /Applications/ahem.app
```

Then:

- **Allow notifications** when macOS asks — that's the banner feature.
- **Allow Automation** ("ahem wants to control Ghostty/Terminal/iTerm2") — that's click-to-focus.
- Add ahem to **System Settings → General → Login Items** to keep it across reboots.
- Codex asks you to trust its hooks on next start; until you do, it silently skips them.

`./uninstall.sh` reverses everything; `./test.sh` runs the test suite.

## Usage

The menu bar is the product: glance at it, click what's red.

The same data is available in a terminal:

```sh
ahem             # list agent processes; X marks orphans whose window is gone
ahem 97690       # focus that session's window
watch -n2 plugin/ahem.3s.sh   # the full menu, rendered as text
```

## How it works

Claude Code hooks write one small status file per session, overwritten on each event:

| Hook               | Status       |
| ------------------ | ------------ |
| `SessionStart`     | 🟢 running   |
| `UserPromptSubmit` | 🟢 working   |
| `Notification`     | 🔴 needs you |
| `Stop`             | ⚪️ idle      |
| `SessionEnd`       | (removed)    |

The hooks don't cover everything: nothing fires when Claude resumes after you approve a permission prompt, and `Stop` fires while background subagents are still running. So the status file is a floor — if the session's transcript (or a subagent's) shows an `assistant` or `user` entry newer than the last event, the row goes green anyway. Only those entries count: Claude also writes recaps and bookkeeping to the transcript while idle, which is why file mtime can't be trusted.

Codex is discovered from the outside: `ps` finds the process, `lsof` finds the rollout file it holds open, and the rollout's last event says whether the turn ended. One hook (`PermissionRequest`) fills the only gap — whether it's blocked on an approval.

Session names come from the terminal's window title, which Claude keeps set to the task at hand. Codex puts the directory there instead, so its rows fall back to your last prompt.

The pieces:

```
bin/ahem            CLI: list sessions, focus a window by pid
hook/status.py      Claude/Codex hook: writes a session's status file
plugin/ahem.3s.sh   the brain: builds the menu (SwiftBar text format)
app/main.swift      menu bar app: renders the plugin, posts clickable banners
```

The Swift app deliberately contains no status logic — it renders whatever the plugin script prints. All behavior lives in one testable Python file.

## Limitations

- Ghostty, Terminal.app, and iTerm2 only (background Terminal.app tabs can't expose their titles, so those rows are named by directory).
- Codex under `--yolo` never shows 🔴 — it never asks for anything.
- Closing a terminal window doesn't kill the agent; the process lingers with no window to focus. Those rows dim and mark `X` in the CLI.
- macOS only.

## Privacy

Everything is local. ahem reads session transcripts and status files on your disk, calls no network endpoints, and stores nothing beyond one small JSON file per live session in `~/.claude/agent-status/`.
