# ahem

Menu bar dot for which coding-agent session is waiting on you. Click a row to focus
that window.

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

Claude Code and Codex, in Ghostty, on macOS.

## Install

```sh
./install.sh          # symlinks the CLI + plugin, wires the hooks
./uninstall.sh
./test.sh
```

The menu bar part needs [SwiftBar](https://swiftbar.app), which `install.sh` doesn't
install for you:

```sh
brew install --cask swiftbar     # point its plugin folder at ~/.swiftbar
```

Codex will ask you to trust its hooks the first time it starts after you install.
If you don't, it skips them and doesn't report an error.

Same view without SwiftBar:

```sh
watch -n2 plugin/ahem.3s.sh
```

CLI:

```sh
ahem             # claude + codex processes; X means the window is gone
ahem 97690       # focus that session
```

## How it works

Claude Code hooks write one status file per session, overwritten on each event:

| Hook               | Status       |
| ------------------ | ------------ |
| `SessionStart`     | 🟢 running   |
| `UserPromptSubmit` | 🟢 working   |
| `Notification`     | 🔴 needs you |
| `Stop`             | ⚪️ idle      |
| `SessionEnd`       | (removed)    |

They land in `~/.claude/agent-status/<session_id>.json`.

The hooks don't cover everything. Nothing fires when Claude picks back up after you
approve a permission prompt, and `Stop` fires while background subagents are still
going. Both leave a working session looking stopped. So the status file is a floor:
if there's an `assistant` or `user` entry in the transcript newer than the event,
the row goes green anyway. Subagents write to their own transcripts under
`<transcript>/subagents/`.

I had that check on file mtime first, which was wrong for about a day before I
noticed every finished session was stuck green. Claude appends a recap to the
transcript a couple of minutes after a turn ends, plus hook summaries and turn
timings. Only `assistant` and `user` entries count as work.

Codex has no hook worth wiring except `PermissionRequest`, and under `--yolo` that
never fires either, since it never asks. It does hold its rollout `.jsonl` open, so
`ps` plus one `lsof` finds the file. The last event in it is `task_complete` if the
turn ended.

Names come off the Ghostty window title, which Claude keeps set to whatever it's
working on. Codex puts the directory there instead, so it falls back to the last
prompt you typed.

`CLAUDE.md` has the rest: `comm` truncating at 16 chars, what `tab` means inside a
Ghostty `tell` block, why a row can't have a submenu.

```
bin/ahem            the CLI
hook/status.py      writes a session's status file
plugin/ahem.3s.sh   the menu bar (runs standalone too)
```

## Limits

- Ghostty only.
- Codex under `--yolo` never goes red.
- Closing a Ghostty window doesn't kill the agent. The pty stays open, nothing gets
  SIGHUP'd, and the process sits there for hours with no surface to focus. Those
  rows go grey; `ahem` marks them `X`.
- Sessions that die without `SessionEnd` are cleaned up on the next render.
