#!/usr/bin/env python3
"""Record an agent session's status, for the menu bar.

Claude: no argument. Wired to SessionStart/UserPromptSubmit/Notification/Stop/
SessionEnd; the event arrives as JSON on stdin. One file per session, newest
event wins -- nothing to append, parse, or compact.

Codex: `status.py codex-blocked` / `codex-clear`, wired to PermissionRequest and
Stop. The mode is an argument rather than a stdin field on purpose: Codex's hook
payload shape is undocumented and unverified here, and the only thing we actually
need -- which process is blocked -- comes from the parent walk, not the payload.
Codex sessions are otherwise discovered by the plugin, so these only mark blocked.
"""
import json, os, subprocess, sys, time, pathlib

# Not ~/.claude/agents: that is Claude Code's own subagent-definition directory.
DIR = pathlib.Path(os.environ.get("AGENT_STATUS_DIR",
                                  pathlib.Path.home() / ".claude" / "agent-status"))

STATUS = {
    "SessionStart": "running",
    "UserPromptSubmit": "working",
    "Notification": "needs-you",
    "Stop": "idle",
}


def agent_proc(name="claude"):
    """Return (pid, tty) of the agent process running this hook.

    Hooks are spawned without a controlling terminal of their own (`ps -o tty=`
    reports "??"), so walk up the parent chain to the agent itself, which has one.
    The tty is what lets `agents <pid>` find the Ghostty surface to focus.
    """
    pid = os.getppid()
    for _ in range(6):
        try:
            # args=, not comm=: macOS truncates comm to 16 chars, so a claude at
            # /opt/homebrew/bin/claude would read as "/opt/homebrew/bi" and never
            # match. args= is untruncated and must come last (it contains spaces).
            out = subprocess.run(["ps", "-o", "ppid=,tty=,args=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=2).stdout.split()
        except Exception:
            return None, None
        if len(out) < 3:
            return None, None
        ppid, tty, exe = out[0], out[1], out[2]
        if os.path.basename(exe) == name and "app-server" not in " ".join(out[2:]):
            return pid, tty
        try:
            pid = int(ppid)
        except ValueError:
            return None, None
    return None, None


def codex(mode):
    """Mark/clear 'this codex session is waiting on an approval'.

    Keyed by pid, because that is how the plugin already identifies codex
    sessions (it finds them by scanning processes, not by session id).
    """
    pid, _ = agent_proc("codex")
    if pid is None:
        return
    f = DIR / f"codex-{pid}.json"
    if mode != "codex-blocked":
        f.unlink(missing_ok=True)  # turn ended: whatever it asked for is resolved
        return
    label = "needs approval"
    try:  # payload shape is unverified; use it only if it happens to help
        ev = json.load(sys.stdin)
        for k in ("tool_name", "tool", "command", "message"):
            if ev.get(k):
                label = str(ev[k])[:80]
                break
    except Exception:
        pass
    DIR.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps({"ts": time.time(), "msg": label}))


def main():
    if len(sys.argv) > 1 and sys.argv[1].startswith("codex-"):
        codex(sys.argv[1])
        return
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return  # never break the session over a status file
    sid = ev.get("session_id")
    if not sid or "/" in sid:
        return
    event = ev.get("hook_event_name")
    f = DIR / f"{sid}.json"

    if event == "SessionEnd":
        f.unlink(missing_ok=True)
        return

    DIR.mkdir(parents=True, exist_ok=True)
    pid, tty = agent_proc()
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps({
        "status": STATUS.get(event, "running"),
        "pid": pid,
        "tty": tty,
        "cwd": ev.get("cwd", ""),
        # Nothing fires when Claude resumes after you approve a permission prompt,
        # so needs-you cannot be cleared by an event. The plugin watches this file
        # instead: if it grows past our timestamp, Claude is working again.
        "transcript": ev.get("transcript_path", ""),
        "msg": (ev.get("message") or "")[:80],
        "ts": time.time(),
    }))
    tmp.replace(f)  # atomic: the menu bar may read this mid-write


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # a status file is never worth a traceback in someone's session
