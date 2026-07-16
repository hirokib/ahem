#!/usr/bin/env python3
# <xbar.title>ahem</xbar.title>
# <xbar.version>v1.1</xbar.version>
# <xbar.author>hiroki</xbar.author>
# <xbar.desc>Which agent session needs you. Click a row to focus its Ghostty window.</xbar.desc>
# <xbar.dependencies>python3,ghostty</xbar.dependencies>
"""SwiftBar/xbar plugin. Also runs standalone: `watch -n2 plugin/ahem.3s.sh`.

Claude sessions report themselves via hooks (see hook/status.py). Codex is found
by scanning processes, with one hook filling the gap scanning cannot -- whether a
session is blocked on an approval. See codex_rows().
"""
import datetime, json, os, pathlib, subprocess, time

DIR = pathlib.Path(os.environ.get("AGENT_STATUS_DIR",
                                  pathlib.Path.home() / ".claude" / "agent-status"))
# Resolve through the symlink SwiftBar loads us by, so we find our sibling CLI.
FOCUS = pathlib.Path(__file__).resolve().parent.parent / "bin" / "ahem"

DOT = {"needs-you": "🔴", "working": "🟢", "running": "🟢", "idle": "⚪️"}
ORDER = {"needs-you": 0, "working": 1, "running": 2, "idle": 3}
LABEL = {"needs-you": "needs input", "idle": "idle", "running": "ready", "working": "working…"}

# An interrupted turn never writes task_complete. Without this, a Ctrl-C'd codex
# session would show green forever.
STALE = 120
# Slack for a rollout write landing in the same instant as a permission request.
GRACE = 2


def sh(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""


def alive(pid):
    try:
        os.kill(pid, 0)  # signal 0 = existence check, does not touch the process
        return True
    except (OSError, TypeError):
        return False


def age(ts):
    s = max(0, int(time.time() - ts))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    return f"{s // 3600}h"


# --- claude: hooks push status to us ---

def claude_rows():
    rows = []
    for f in sorted(DIR.glob("*.json")) if DIR.exists() else []:
        if f.name.startswith("codex-"):
            continue  # a blocked marker, not a claude session
        try:
            d = json.loads(f.read_text())
        except Exception:
            continue
        if not alive(d.get("pid")):
            f.unlink(missing_ok=True)  # session died without firing SessionEnd
            continue
        d.setdefault("agent", "claude")
        busy = active_since(d)
        if d.get("status") in ("needs-you", "idle") and busy > d.get("ts", 0) + GRACE:
            # Report what it is doing, and date the row from the work, not the
            # stale event -- otherwise a busy session reads "idle (44s)".
            d["status"], d["msg"], d["ts"] = "working", "", busy
        rows.append(d)
    return rows


WORK = ("assistant", "user")  # everything else in a transcript is bookkeeping


def last_work_at(path, after=0):
    """When this transcript last recorded real work, or 0 if none since `after`.

    File mtime is NOT a proxy for work. Claude writes to the transcript while the
    session sits idle: away_summary (the recap, ~2min after a turn ends),
    stop_hook_summary, turn_duration, ai-title, mode. Trusting mtime showed a
    finished session as green forever, since nothing later corrects it.
    """
    def newer(t):
        return t if t > after else 0

    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return 0
    if mtime <= after:
        return 0  # cheap reject: nothing in here can be newer than `after`
    for e in tail_json(path):
        if e.get("type") not in WORK:
            continue
        stamp = e.get("timestamp")
        if not stamp:
            return newer(mtime)  # a work entry we cannot date; mtime is our best guess
        try:
            return newer(datetime.datetime.fromisoformat(
                stamp.replace("Z", "+00:00")).timestamp())
        except ValueError:
            return newer(mtime)
    return 0  # nothing but bookkeeping in the tail -- NOT mtime, that was the bug


def active_since(d):
    """When this session last did real work; 0 if nothing is known.

    Two hook gaps make the recorded status untrustworthy on its own, and both
    look the same from here -- the session is quietly still busy:

      - Approving a permission prompt fires nothing, so needs-you would stick
        until the turn ended, showing red for a session that is working.
      - Stop fires when the *main* agent finishes, while background subagents keep
        running, showing idle for a session with four agents mid-flight.

    Claude does no work while genuinely waiting on you, so work newer than the
    event that set our status means it is still going. Subagents get their own
    transcripts under <transcript-without-.jsonl>/subagents/, which is the only
    place their activity shows up -- the main transcript stays quiet.
    """
    t = d.get("transcript")
    if not t:
        return 0
    after = d.get("ts", 0)
    times = [last_work_at(t, after)]
    try:
        for f in (pathlib.Path(t).with_suffix("") / "subagents").glob("*.jsonl"):
            times.append(last_work_at(f, after))
    except OSError:
        pass
    return max(times, default=0)


# --- codex: read from the outside, plus one hook ---
# Working-vs-finished is visible without any config: codex holds its rollout open
# and the last event says the state. Blocked-on-approval is not -- rollouts record
# no approval events at all -- so PermissionRequest is wired to mark it. Note that
# hook never fires under `codex --yolo`, so those sessions never show needs-you.

def tail_json(path, tail=65536):
    """Newest-first JSON lines from the end of a file, without reading it all."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - tail))
            chunk = f.read().decode("utf-8", "ignore")
    except OSError:
        return []
    out = []
    for line in reversed(chunk.splitlines()):
        try:
            out.append(json.loads(line))  # a truncated first line fails and is skipped
        except Exception:
            continue
    return out


def last_payload_type(path, tail=65536):
    """Type of the final event in a rollout."""
    for d in tail_json(path, tail):
        t = (d.get("payload") or {}).get("type")
        if t:
            return t
    return None


def codex_name(path, tail=65536):
    """Codex's task name: its last prompt. Its terminal title is only the cwd, and
    rollouts carry no summary, so the raw prompt is the best name available.
    None if the turn has produced more output than fits the tail.
    """
    for d in tail_json(path, tail):
        p = d.get("payload") or {}
        if p.get("type") == "user_message" and p.get("message"):
            return str(p["message"])
    return None


def rollout_status(path, now=None):
    last = last_payload_type(path)
    if last in ("task_complete", "turn_aborted"):
        return "idle"  # clean turn boundary: codex is waiting on you
    now = time.time() if now is None else now
    try:
        quiet = now - os.path.getmtime(path)
    except OSError:
        return "idle"
    return "working" if quiet < STALE else "idle"


def blocked_on(pid, rollout):
    """A PermissionRequest hook marks a pid blocked; nothing marks it unblocked.

    While codex waits on you it writes nothing to the rollout, so the rollout
    having advanced past the marker means the approval was answered. The Stop
    hook removes the marker too, but only at end of turn -- this clears it the
    moment codex moves on. GRACE absorbs a rollout write landing in the same
    instant as the request.
    """
    f = DIR / f"codex-{pid}.json"
    try:
        m = json.loads(f.read_text())
    except Exception:
        return None
    try:
        if os.path.getmtime(rollout) > m["ts"] + GRACE:
            f.unlink(missing_ok=True)
            return None
    except OSError:
        pass
    return m.get("msg") or "needs approval"


# --- naming: what is this session actually doing? ---

def ghostty_titles():
    """tty -> terminal title. Claude keeps its title set to the current task and
    updates it as the task changes, which is exactly the name we want and better
    than anything derivable from the transcript. Codex only puts the cwd there.
    """
    # Separator is a space, not `tab`: Ghostty's dictionary defines a `tab` class,
    # which shadows AppleScript's tab constant inside the tell block and emits the
    # literal word. A tty never contains a space, so the first one splits cleanly.
    if os.environ.get("AGENTS_SKIP_GHOSTTY"):
        return {}
    out = sh("osascript", "-e", '''tell application "Ghostty"
      set out to ""
      repeat with s in terminals
        set out to out & (tty of s) & " " & (name of s) & linefeed
      end repeat
      return out
    end tell''')
    titles = {}
    for line in out.splitlines():
        tty, _, name = line.partition(" ")
        if tty.startswith("/dev/"):
            titles[tty.replace("/dev/", "")] = name.strip()
    return titles


def clean_title(title, cwd):
    """A task name, or None if the title is just decoration.

    Claude prefixes a status glyph (✳, braille spinner); a plain shell shows a
    path; codex shows the bare directory. None of those name a task.
    """
    if not title:
        return None
    name = title.lstrip("✳⠁⠂⠄⠈⠐⠠⡀⢀⠃⠉⠋⠛⠟⠿⡿⣿⠼⠴⠦⠧⠇⠏* ").strip()
    if not name or name.startswith(("~", "/")):
        return None
    if name == os.path.basename(cwd or ""):
        return None
    return name


def short_msg(m):
    """"Claude is waiting for your input" -> "waiting for input". The row already
    says which agent and the dot already says it needs you."""
    if not m:
        return ""
    m = m.strip().rstrip(".")
    for p in ("Claude is ", "Claude "):
        if m.startswith(p):
            m = m[len(p):]
            break
    return truncate(m.replace("your ", ""), 24)


def truncate(s, n=45):
    s = " ".join(s.split())  # a prompt may be multi-line; a row is not
    return s if len(s) <= n else s[:n - 1].rstrip() + "…"


def codex_pids():
    """(pid, tty) for TUI sessions -- the app-server children share name and tty."""
    found = []
    for line in sh("ps", "-eo", "pid=,tty=,args=").splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3:
            continue
        pid, tty, args = parts
        if os.path.basename(args.split()[0]) == "codex" and "app-server" not in args:
            found.append((pid, tty))
    return found


def codex_rows():
    # Codex is discovered by scanning live processes, so tests set this to stay
    # deterministic -- otherwise real sessions leak into their expected output.
    if os.environ.get("AGENTS_SKIP_CODEX"):
        return []
    procs = codex_pids()
    if not procs:
        return []
    ttys = dict((int(p), t) for p, t in procs)
    # One lsof for every session: it costs ~0.2s, and per-pid calls would multiply that.
    out = sh("lsof", "-p", ",".join(p for p, _ in procs), "-Fpfn")
    rows, pid, fd, cur = [], None, None, {}
    for line in out.splitlines():
        tag, val = line[:1], line[1:]
        if tag == "p":
            pid, cur = int(val), {}
            rows.append((pid, cur))
        elif tag == "f":
            fd = val
        elif tag == "n" and cur is not None:
            if fd == "cwd":
                cur["cwd"] = val
            elif val.endswith(".jsonl") and "/sessions/" in val:
                cur["rollout"] = val
    live, out = {p for p, _ in rows}, []
    for pid, d in rows:
        if "rollout" not in d:
            continue
        msg = blocked_on(pid, d["rollout"])
        out.append({"status": "needs-you" if msg else rollout_status(d["rollout"]),
                    "pid": pid, "cwd": d.get("cwd", ""), "msg": msg or "",
                    "agent": "codex", "name": codex_name(d["rollout"]),
                    "tty": ttys.get(pid), "ts": os.path.getmtime(d["rollout"])})
    for f in DIR.glob("codex-*.json"):  # markers outlive sessions that were killed
        try:
            if int(f.stem.split("-")[1]) not in live:
                f.unlink(missing_ok=True)
        except (ValueError, IndexError):
            pass
    return out


def load():
    rows = claude_rows() + codex_rows()
    titles = ghostty_titles() if rows else {}  # one call for every session, not one each
    for d in rows:
        if d["agent"] == "claude":
            d["name"] = clean_title(titles.get(str(d.get("tty") or "")), d.get("cwd"))
        # No surface means the window was closed while the process lived on: there
        # is nothing to focus. An empty map means Ghostty is gone or the query
        # failed -- do not then claim every session lost its window.
        d["window"] = not titles or str(d.get("tty") or "") in titles
    # Unfocusable rows sort last: nothing can be done about them from here.
    rows.sort(key=lambda d: (not d["window"], ORDER.get(d.get("status"), 9), -d.get("ts", 0)))
    return rows


def main():
    rows = load()
    blocked = sum(1 for d in rows if d["status"] == "needs-you")
    busy = sum(1 for d in rows if d["status"] in ("working", "running"))

    bar = []
    if blocked:
        bar.append(f"🔴{blocked}")
    if busy:
        bar.append(f"🟢{busy}")
    print(" ".join(bar) if bar else "⚪️")

    print("---")
    if not rows:
        print("No active sessions | color=#888888")
    for d in rows:
        where = os.path.basename(d.get("cwd") or "") or "?"
        if d.get("agent") == "codex":
            where += "/codex"
        name = d.get("name")
        # Name it whenever we know it, including when idle -- an idle session is
        # still *about* something, and that is what you need in order to decide
        # whether to go back to it.
        parts = [truncate(name), where] if name else [where]
        if d["status"] == "needs-you":
            parts.append(short_msg(d.get("msg")) or LABEL["needs-you"])
        elif d["status"] == "idle" or not name:
            parts.append(LABEL.get(d["status"], d["status"]))
        # Everything must stay on the row: an NSMenuItem with a submenu never fires
        # its own action, so nesting anything here would cost the click-to-focus.
        row = f"{DOT.get(d['status'], '·')} {' · '.join(parts)} ({age(d.get('ts', 0))})"
        if not d["window"]:
            # Dimmed and inert rather than hidden: the process may still be doing
            # real work, and a row that looks clickable but cannot focus is a lie.
            print(f"{row} · no window | color=#888888")
        else:
            print(f"{row} | bash={FOCUS} param1={d['pid']} terminal=false refresh=true")
    print("---")
    print("Refresh | refresh=true")


if __name__ == "__main__":
    main()
