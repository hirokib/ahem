# AGENTS.md

Notes for anyone (human or agent) working on ahem. `CLAUDE.md` is a symlink to
this file. Read `README.md` first for what the tool does and how it works.

## Layout

```
bin/ahem            CLI: list sessions, focus a window by pid, setup/unsetup
hook/status.py      Claude/Codex hook: writes one status file per session
plugin/ahem.3s.sh   builds the menu (SwiftBar text format), the status brain
app/main.swift      menu bar app: renders the plugin, posts clickable banners
build.sh            builds and signs build/ahem.app
install.sh          dev install: build + `ahem setup`
test.sh             the test suite
```

The plugin is the single source of truth. The Swift app only renders its output
and posts banners; keep status and naming logic in the plugin, not in Swift.

## Working on it

Run `./test.sh` before every commit. It runs against a temp `AGENT_STATUS_DIR`
and must not touch real state. The suite sets `AGENTS_SKIP_CODEX`,
`AGENTS_SKIP_TITLES`, and `AGENTS_SKIP_PTY` so it never depends on the live
system's processes, terminals, or ptys.

`./install.sh` builds the app, installs it to /Applications, and wires the
hooks. `ahem unsetup` reverses it.

Style: shortest thing that works. Prefer the standard library over a dependency
and one file over four. Comment only what the code cannot say, such as a
platform quirk or a deliberate shortcut. Do not comment what the next line does.

Commits: write the message as the author of the change. No AI attribution
trailers.

## Gotchas worth not rediscovering

Presence and naming:

- Window presence comes from pty ownership (`pty_owners` in the plugin), not
  from an AppleScript window sweep. AppleScript cannot see windows on other
  Spaces or in unscripted apps like VS Code, so `tty in titles` wrongly dimmed
  live sessions as "no window". A window exists if some app owns the pty.
- The AppleScript title sweep is for naming only. It runs against Ghostty,
  Terminal.app, and iTerm2, each gated by `pgrep` because telling an app
  launches it.
- Never call AppleScript `activate` to focus a window. If the target is on
  another Space it switches Spaces but leaves the window non-key, so keystrokes
  go nowhere until you click it. This locked up input entirely. Use each
  terminal's own focus verb.

Status accuracy:

- File mtime is not a proxy for work. Claude writes `away_summary`,
  `stop_hook_summary`, `turn_duration`, `ai-title`, and `mode` to the transcript
  while idle. Count only `assistant` and `user` entries by their ISO timestamps.
  A tail of pure bookkeeping means no work; falling back to mtime there is the
  bug.
- Hook status is a lower bound, not the truth. Approving a permission prompt
  fires nothing, and `Stop` fires while subagents keep running. Both report a
  busy session as idle. Disk activity is the correction; do not add state to the
  hooks to paper over it.
- Subagents write only to their own transcripts at
  `<transcript-minus-.jsonl>/subagents/agent-*.jsonl`. The main transcript stays
  quiet while they run.

Process and terminal:

- `ps -o comm=` truncates to 16 chars on macOS. Use `ps -o args=`. A claude at
  `/opt/homebrew/bin/claude` reads back as `/opt/homebrew/bi` and the parent
  walk fails, dropping the session.
- `tab` is unusable inside a Ghostty `tell` block. Its dictionary defines a
  `tab` class that shadows AppleScript's tab constant, so `& tab &` emits the
  literal word "tab" and the parse returns nothing. Separate fields with a
  space; a tty never contains one.
- A row must never have a submenu. An `NSMenuItem` with a submenu never fires
  its own action, which silently kills click-to-focus. `test.sh` guards this.

Hooks:

- Codex hooks are silently skipped unless trusted, live only at
  `~/.codex/hooks.json` (not `hooks/hooks.json`), and `"async": true` stops a
  hook firing at all.
- Never write to `config.toml`'s `notify`. It is a single slot and may already
  belong to something else.
- A hook must never raise. `status.py` wraps `main()` and always exits 0. A
  traceback in someone's session is worse than a missing status file.

Tests:

- Do not assert against the ambient session. The tests often run inside a claude
  session, so a walk test would find that pid and pass for the wrong reason. The
  fixture symlinks `/bin/zsh` to a file named `claude` (a copy gets SIGKILLed by
  code signing) and appends `; true` so zsh does not exec the hook in place.
- Never point a test at the real status dir. Firing a hook by hand from a claude
  session writes a real file for the ambient pid.

## Scope

Ambient status only: which session needs me, and focus its window. Not a session
manager, log viewer, or dashboard.
