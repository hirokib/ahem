#!/bin/zsh
# Self-check: ./test.sh -- runs against a temp status dir, touches no real state.
set -e
REPO=${0:A:h}
export AGENT_STATUS_DIR=$(mktemp -d)
export AGENTS_SKIP_CODEX=1     # live codex sessions would make menu output nondeterministic
export AGENTS_SKIP_GHOSTTY=1   # ditto for whatever windows happen to be open
trap 'rm -rf "$AGENT_STATUS_DIR"' EXIT

python3 - "$REPO" <<'EOF'
import datetime, json, os, pathlib, subprocess, sys, time
repo = sys.argv[1]
D = pathlib.Path(os.environ["AGENT_STATUS_DIR"])


def fire(event, sid, msg=""):
    ev = {"session_id": sid, "hook_event_name": event, "cwd": f"/tmp/proj-{sid}", "message": msg}
    subprocess.run(["python3", f"{repo}/hook/status.py"], input=json.dumps(ev),
                   text=True, check=True)


def read(sid):
    return json.loads((D / f"{sid}.json").read_text())


def fixture(sid, status, msg="", pid=None, ts=None, transcript=""):
    """A session file as the hook would leave it. Default pid is alive (us)."""
    (D / f"{sid}.json").write_text(json.dumps({
        "status": status, "pid": os.getpid() if pid is None else pid,
        "tty": "ttys1", "cwd": f"/tmp/{sid}", "msg": msg, "transcript": transcript,
        "ts": time.time() if ts is None else ts}))


def menu():
    return subprocess.run(["python3", f"{repo}/plugin/ahem.3s.sh"],
                          capture_output=True, text=True, check=True).stdout


# --- hook: event -> status ---
fire("SessionStart", "a"); assert read("a")["status"] == "running"
fire("UserPromptSubmit", "a"); assert read("a")["status"] == "working"
fire("Notification", "a", "needs permission"); assert read("a")["status"] == "needs-you"
assert read("a")["msg"] == "needs permission"
fire("Stop", "a"); assert read("a")["status"] == "idle"
assert read("a")["cwd"] == "/tmp/proj-a"

# newest event wins: one file per session, no appending
assert len(list(D.glob("*.json"))) == 1

# --- the pid walk ---
# The hook gets no tty of its own, so it walks up to the claude process. Test it
# under a process actually named `claude`; asserting against the ambient session
# would pass for the wrong reason (these tests may themselves run under claude).
import shutil, tempfile
sandbox = tempfile.mkdtemp()
fake = pathlib.Path(sandbox) / "claude"
# symlink, not copy: macOS code-signing SIGKILLs a copied /bin/zsh. `ps -o comm=`
# reports the path used to exec, so the symlink name is what the walk matches on.
fake.symlink_to("/bin/zsh")
# trailing `; true` keeps the hook a *child*: zsh execs a final command in-place,
# which would replace this fake claude and leave nothing for the walk to find.
r = subprocess.run([str(fake), "-c", f'echo $$; {sys.executable} {repo}/hook/status.py; true'],
                   input=json.dumps({"session_id": "walk", "hook_event_name": "SessionStart",
                                     "cwd": "/tmp/walk"}),
                   capture_output=True, text=True)
fake_pid = int(r.stdout.strip())
assert read("walk")["pid"] == fake_pid, f'walked to {read("walk")["pid"]}, want {fake_pid}'
(D / "walk.json").unlink()
shutil.rmtree(sandbox)

# SessionEnd removes the file; a second one is not an error
fire("SessionEnd", "a"); assert not (D / "a.json").exists()
fire("SessionEnd", "a")

# malformed stdin must never raise -- a status file is not worth breaking a session over
subprocess.run(["python3", f"{repo}/hook/status.py"], input="not json", text=True, check=True)
subprocess.run(["python3", f"{repo}/hook/status.py"], input="{}", text=True, check=True)
assert not list(D.glob("*.json"))

# --- menu: sorting, labels, pruning ---
fixture("busy", "working")
fixture("blocked", "needs-you", "approve this?")
out = menu()
assert out.splitlines()[0] == "🔴1 🟢1", out.splitlines()[0]
rows = [l for l in out.splitlines() if "bash=" in l]
assert "blocked" in rows[0], "blocked sorts first\n" + out
assert "busy" in rows[1], out
# what it is asking for rides on the row itself
assert "approve this?" in rows[0], out

# REGRESSION GUARD: no row may have a submenu. An NSMenuItem with a submenu never
# fires its own action, so nesting anything under a row silently kills
# click-to-focus -- and it killed it on exactly the red rows you most want to click.
for l in out.splitlines():
    assert not (l.startswith("--") and not l.startswith("---")), \
        f"submenu item would break click-to-focus: {l!r}"
# and every session row must carry a focus action
for l in rows:
    assert "bash=" in l and "param1=" in l, l


# a session with no live process is pruned, not shown
fixture("ghost", "working", pid=999999)
out = menu()
assert "ghost" not in out, "dead session should be pruned"
assert not (D / "ghost.json").exists(), "prune deletes the file"

# pid=None (walk failed) is also treated as dead, not crashed on
fixture("nopid", "working", pid=None)
(D / "nopid.json").write_text(json.dumps({"status": "working", "pid": None, "tty": None,
                                          "cwd": "/tmp/nopid", "msg": "", "ts": time.time()}))
assert "nopid" not in menu()

# corrupt file is skipped, not fatal
(D / "corrupt.json").write_text("{{{")
assert "🔴1" in menu()

# --- only real work counts as activity ---
# Claude writes to the transcript while idle: away_summary (the recap, ~2min after
# a turn ends), stop_hook_summary, turn_duration. Trusting file mtime showed a
# finished session as green forever, since nothing later corrects it.
import importlib.machinery as _m, importlib.util as _u
_l = _m.SourceFileLoader("plug0", f"{repo}/plugin/ahem.3s.sh")
plug0 = _u.module_from_spec(_u.spec_from_loader("plug0", _l)); _l.exec_module(plug0)

wdir = pathlib.Path(tempfile.mkdtemp())


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)\
        .strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def transcript(name, entries, mtime=None):
    p = wdir / name
    p.write_text("".join(json.dumps(e) + "\n" for e in entries))
    if mtime:
        os.utime(p, (mtime, mtime))
    return p


T = time.time()
# the exact shape that shipped the bug: work, then the notification, then a recap
p = transcript("recap.jsonl", [
    {"type": "assistant", "timestamp": iso(T - 300)},
    {"type": "system", "subtype": "stop_hook_summary", "timestamp": iso(T - 300)},
    {"type": "system", "subtype": "turn_duration", "timestamp": iso(T - 300)},
    {"type": "system", "subtype": "away_summary", "timestamp": iso(T - 10)},
], mtime=T - 10)
got = plug0.last_work_at(p, after=T - 600)
assert abs(got - (T - 300)) < 2, f"away_summary must not count as work (got {got - T:+.0f}s)"
assert plug0.last_work_at(p, after=T - 60) == 0, "no work since the event -> 0"

# real work after the event does count
p2 = transcript("work.jsonl", [
    {"type": "assistant", "timestamp": iso(T - 300)},
    {"type": "user", "timestamp": iso(T - 5)},
], mtime=T - 5)
assert abs(plug0.last_work_at(p2, after=T - 60) - (T - 5)) < 2

# a work entry with no timestamp falls back to mtime rather than vanishing
p3 = transcript("nostamp.jsonl", [{"type": "assistant"}], mtime=T - 5)
assert abs(plug0.last_work_at(p3, after=T - 60) - (T - 5)) < 2
# unparseable timestamp, same fallback
p4 = transcript("badstamp.jsonl", [{"type": "assistant", "timestamp": "not-a-date"}], mtime=T - 5)
assert abs(plug0.last_work_at(p4, after=T - 60) - (T - 5)) < 2
# a transcript of pure bookkeeping has no work at all
p5 = transcript("sysonly.jsonl", [{"type": "system", "subtype": "ai-title", "timestamp": iso(T)}], mtime=T)
assert plug0.last_work_at(p5, after=T - 600) == 0
assert plug0.last_work_at(wdir / "missing.jsonl") == 0

# end to end: a finished session whose recap just landed must stay red
for f in D.glob("*.json"):
    f.unlink()
fixture("recapped", "needs-you", "Claude is waiting for your input",
        ts=T - 130, transcript=str(p))
out = menu()
assert out.splitlines()[0] == "🔴1", f"recap counted as work:\n{out}"
for f in D.glob("*.json"):
    f.unlink()
shutil.rmtree(wdir)

# --- needs-you must not stick while claude is working ---
# Approving a permission prompt fires no hook. Only the transcript growing tells
# us claude resumed, so a red row whose transcript has moved on must go green.
for f in D.glob("*.json"):
    f.unlink()
tr = D / "transcript.jsonl"
t0 = time.time()

# last work predates the notification -> genuinely waiting on you
tr.write_text(json.dumps({"type": "assistant", "timestamp": iso(t0 - 60)}) + "\n")
os.utime(tr, (t0 - 60, t0 - 60))
fixture("waiting", "needs-you", "Claude is waiting for your input", ts=t0, transcript=str(tr))
assert menu().splitlines()[0] == "🔴1", menu()

# real work after the notification -> claude is working again, not blocked
tr.write_text(json.dumps({"type": "assistant", "timestamp": iso(t0 + 30)}) + "\n")
os.utime(tr, (t0 + 30, t0 + 30))
out = menu()
assert out.splitlines()[0] == "🟢1", f"needs-you stuck while working:\n{out}"
assert "working…" in out and "waiting for your input" not in out, out

# a status file with no transcript recorded stays as reported (old files, walk failed)
fixture("notrans", "needs-you", "x", ts=t0)
assert "🔴1" in menu()
for f in D.glob("*.json"):
    f.unlink()

# --- idle must not stick while subagents are still running ---
# Stop fires when the MAIN agent finishes; background subagents keep going and
# write only to their own transcripts, so the main one goes quiet and the row
# would read idle while four agents are mid-flight.
os.utime(tr, (t0 - 60, t0 - 60))          # main transcript quiet since Stop
subs = D / "transcript" / "subagents"     # <transcript minus .jsonl>/subagents/
subs.mkdir(parents=True)
fixture("subs", "idle", ts=t0, transcript=str(tr))
assert menu().splitlines()[0] == "⚪️", "no subagents yet -> idle"

sub = subs / "agent-abc.jsonl"
sub.write_text(json.dumps({"type": "assistant", "timestamp": iso(t0 + 30)}) + "\n")
os.utime(sub, (t0 + 30, t0 + 30))         # a subagent is working right now
out = menu()
assert out.splitlines()[0] == "🟢1", f"idle stuck while subagents ran:\n{out}"
assert "working…" in out, out

# stale subagent files from an earlier turn must not resurrect a finished session
os.utime(sub, (t0 - 300, t0 - 300))
assert menu().splitlines()[0] == "⚪️", "old subagent files should not mean busy"

# the row is dated from the work, not the stale Stop event
os.utime(sub, (t0 + 30, t0 + 30))
assert "(0s)" in menu() or "(1s)" in menu(), menu()
for f in D.glob("*.json"):
    f.unlink()
shutil.rmtree(D / "transcript")
tr.unlink()

# empty state renders
for f in D.glob("*.json"):
    f.unlink()
assert "No active sessions" in menu()
assert menu().splitlines()[0] == "⚪️"

# --- codex: rollout parsing (pure, no processes involved) ---
import importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader("plug", f"{repo}/plugin/ahem.3s.sh")
spec = importlib.util.spec_from_loader("plug", loader)
plug = importlib.util.module_from_spec(spec)
loader.exec_module(plug)

roll = pathlib.Path(tempfile.mkdtemp())


def rollout(name, types, mtime=None):
    p = roll / name
    p.write_text("".join(json.dumps({"timestamp": "t", "type": "event_msg",
                                     "payload": {"type": t}}) + "\n" for t in types))
    if mtime is not None:
        os.utime(p, (mtime, mtime))
    return p


now = time.time()
# a clean turn boundary means codex is waiting on you
assert plug.rollout_status(rollout("a", ["message", "token_count", "task_complete"])) == "idle"
# mid-turn and actively writing
assert plug.rollout_status(rollout("b", ["message", "token_count"])) == "working"
# interrupted turn: no task_complete ever arrives, so fall back to staleness
assert plug.rollout_status(rollout("c", ["token_count"], mtime=now - 600)) == "idle"
assert plug.rollout_status(rollout("d", ["token_count"], mtime=now - 5)) == "working"
# only the tail is read, so a truncated leading line must not be fatal
big = rollout("e", ["token_count"] * 4000 + ["task_complete"])
assert plug.rollout_status(big) == "idle"
assert plug.last_payload_type(big) == "task_complete"
# unreadable file degrades to idle rather than raising
assert plug.rollout_status(roll / "missing.jsonl") == "idle"
assert plug.last_payload_type(roll / "missing.jsonl") is None
# a rollout with no payload types at all
(roll / "f").write_text('{"nope": 1}\n')
assert plug.last_payload_type(roll / "f") is None

# --- codex: blocked markers (PermissionRequest hook) ---
plug.DIR = D
roll_b = rollout("blocked", ["function_call"], mtime=now - 30)

# no marker -> not blocked
assert plug.blocked_on(4242, roll_b) is None
# marker newer than the rollout: codex is sitting on the prompt, writing nothing
(D / "codex-4242.json").write_text(json.dumps({"ts": now, "msg": "wants: git push"}))
assert plug.blocked_on(4242, roll_b) == "wants: git push"
# rollout advanced past the marker -> approval was answered, marker self-clears
roll_done = rollout("answered", ["function_call"], mtime=now + 60)
(D / "codex-4243.json").write_text(json.dumps({"ts": now, "msg": "x"}))
assert plug.blocked_on(4243, roll_done) is None
assert not (D / "codex-4243.json").exists(), "resolved marker should be removed"
# a marker with no message still blocks
(D / "codex-4244.json").write_text(json.dumps({"ts": now}))
assert plug.blocked_on(4244, roll_b) == "needs approval"
# corrupt marker is not fatal
(D / "codex-4245.json").write_text("{{{")
assert plug.blocked_on(4245, roll_b) is None

# markers must not be mistaken for claude sessions (they share the directory)
rows = plug.claude_rows()
assert rows == [], f"codex markers leaked into claude rows: {rows}"
assert (D / "codex-4242.json").exists(), "claude_rows must not delete codex markers"
for f in D.glob("codex-*.json"):
    f.unlink()

# The hook writes and clears markers, keyed by the codex pid it walks up to. Both
# hooks must run inside ONE fake codex: separate processes would walk to separate
# pids and the clear would target a marker the block never wrote.
env = dict(os.environ, AGENT_STATUS_DIR=str(D))
fake2 = pathlib.Path(tempfile.mkdtemp()) / "codex"
fake2.symlink_to("/bin/zsh")
script = f"""echo $$
{sys.executable} {repo}/hook/status.py codex-blocked <<'J'
{{"tool_name": "shell: rm -rf /"}}
J
cat {D}/codex-$$.json; echo
{sys.executable} {repo}/hook/status.py codex-clear </dev/null
test -f {D}/codex-$$.json && echo STILL_THERE || echo CLEARED
"""
r = subprocess.run([str(fake2), "-c", script], capture_output=True, text=True, env=env)
lines = r.stdout.splitlines()
assert lines, f"fake codex produced nothing: {r.stderr}"
marker = json.loads(lines[1])
assert marker["msg"] == "shell: rm -rf /", marker
assert marker["ts"] > 0
assert lines[-1] == "CLEARED", f"codex-clear should remove the marker: {r.stdout}"
assert not list(D.glob("codex-*.json"))
shutil.rmtree(fake2.parent)

# --- naming ---
# Claude keeps its terminal title set to the current task; that title is the name.
assert plug.clean_title("✳ Fix flaky auth test", "/x/api") == "Fix flaky auth test"
assert plug.clean_title("⠐ Port the CLI to Bun", "/x/tooling") == "Port the CLI to Bun"
# decoration that names no task
assert plug.clean_title("~/code/api", "/x/api") is None, "a shell prompt is not a task"
assert plug.clean_title("/Users/me/code", "/x/code") is None
assert plug.clean_title("⠼ api", "/x/api") is None, "codex titles are just the cwd"
assert plug.clean_title("api", "/x/api") is None
assert plug.clean_title("", "/x/api") is None
assert plug.clean_title(None, "/x/api") is None
# a task that happens to share a word with the dir is still a task
assert plug.clean_title("✳ api deploy pipeline", "/x/api") == "api deploy pipeline"

assert plug.truncate("short") == "short"
assert len(plug.truncate("x" * 100)) == 45
assert plug.truncate("x" * 100).endswith("…")
assert plug.truncate("a prompt\nwith newlines") == "a prompt with newlines", "rows are one line"

# the notification is shortened: the dot already says it needs you
assert plug.short_msg("Claude is waiting for your input") == "waiting for input"
assert plug.short_msg("Claude needs your permission") == "needs permission"
assert plug.short_msg("") == ""
assert plug.short_msg(None) == ""
assert len(plug.short_msg("x" * 80)) == 24

# codex's name is its last prompt -- the newest one, not the first
r = roll / "named.jsonl"
r.write_text("".join(json.dumps(x) + "\n" for x in [
    {"payload": {"type": "user_message", "message": "old prompt"}},
    {"payload": {"type": "agent_message"}},
    {"payload": {"type": "user_message", "message": "what's the link?"}},
    {"payload": {"type": "task_complete"}},
]))
assert plug.codex_name(r) == "what's the link?"
assert plug.codex_name(roll / "missing.jsonl") is None
r.write_text(json.dumps({"payload": {"type": "task_complete"}}) + "\n")
assert plug.codex_name(r) is None, "no prompt in the tail -> no name"

# --- sessions whose window was closed ---
# The process outlives the window, so the row cannot focus anything. Mark it inert
# rather than hiding it: it may still be doing real work.
plug.DIR = D
for f in D.glob("*.json"):
    f.unlink()
plug.ghostty_titles = lambda: {"ttys9": "✳ A real task"}
fixture("gone", "working", ts=time.time())          # fixture tty is ttys1: no surface
rows = plug.load()
assert rows[0]["window"] is False, rows
fixture("here", "working", ts=time.time())
(D / "here.json").write_text(json.dumps({"status": "working", "pid": os.getpid(),
                                         "tty": "ttys9", "cwd": "/tmp/here", "msg": "",
                                         "transcript": "", "ts": time.time()}))
rows = plug.load()
assert [d["window"] for d in rows] == [True, False], "unfocusable rows sort last"
assert rows[0]["name"] == "A real task", "title still resolves for live surfaces"

# the rendered row must not offer an action it cannot perform
import contextlib, io
plug.ghostty_titles = lambda: {"ttys9": "✳ A real task"}
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    plug.main()
out = buf.getvalue()
gone = [l for l in out.splitlines() if "gone" in l][0]
here = [l for l in out.splitlines() if "A real task" in l][0]
assert "no window" in gone and "bash=" not in gone, f"windowless row must be inert: {gone}"
assert "color=" in gone, "and visibly dimmed"
assert "bash=" in here and "no window" not in here, here

# a failed ghostty query must not declare every session windowless
plug.ghostty_titles = lambda: {}
assert all(d["window"] for d in plug.load()), "empty title map means unknown, not gone"
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    plug.main()
assert "no window" not in buf.getvalue(), "unknown must not render as gone"
for f in D.glob("*.json"):
    f.unlink()

# an idle session is still about something: name it, and still say it is idle
plug.ghostty_titles = lambda: {"ttys9": "✳ Draft release notes"}
for f in D.glob("*.json"):
    f.unlink()
(D / "resting.json").write_text(json.dumps({"status": "idle", "pid": os.getpid(),
                                            "tty": "ttys9", "cwd": "/tmp/docs", "msg": "",
                                            "transcript": "", "ts": time.time()}))
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    plug.main()
row = [l for l in buf.getvalue().splitlines() if "bash=" in l][0]
assert "Draft release notes" in row, f"idle rows keep their name: {row}"
assert "docs" in row and "idle" in row, row
for f in D.glob("*.json"):
    f.unlink()

# codex_pids must exclude the app-server children (same name, same tty)
plug.sh = lambda *a: ("  111 ttys3 /opt/homebrew/bin/codex --yolo\n"
                      "  222 ttys3 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://\n"
                      "  333 ttys4 /usr/bin/python3 codex\n")
assert plug.codex_pids() == [("111", "ttys3")], plug.codex_pids()

shutil.rmtree(roll)
print("ok: all checks passed")
EOF
