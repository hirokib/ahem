#!/bin/zsh
# Removes symlinks, unwires hooks, drops status files. Leaves the repo alone.
set -e
REPO=${0:A:h}

rm -f "$HOME/bin/ahem" "$HOME/bin/nag" "$HOME/bin/agents"
rm -f "$HOME/.swiftbar/ahem.3s.sh"  # from installs that predate ahem.app
echo "unlinked CLI"

python3 - "$HOME/.claude/settings.json" <<'EOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
if not p.exists():
    sys.exit(0)
d = json.loads(p.read_text())
for ev, arr in list(d.get("hooks", {}).items()):
    for m in list(arr):
        m["hooks"] = [h for h in m.get("hooks", [])
                      if "agent-status.py" not in h.get("command", "")
                      and "hook/status.py" not in h.get("command", "")]
        if not m["hooks"]:
            arr.remove(m)
p.write_text(json.dumps(d, indent=2) + "\n")
print("unwired hooks")
EOF

python3 - "$HOME/.codex/hooks.json" <<'EOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
if not p.exists():
    sys.exit(0)
try:
    d = json.loads(p.read_text())
except Exception:
    sys.exit(0)
for ev, arr in list(d.get("hooks", {}).items()):
    for m in list(arr):
        m["hooks"] = [h for h in m.get("hooks", []) if "hook/status.py" not in h.get("command", "")]
        if not m["hooks"]:
            arr.remove(m)
    if not arr:
        del d["hooks"][ev]
if d.get("hooks"):
    p.write_text(json.dumps(d, indent=2) + "\n")
else:
    p.unlink()  # it was ours alone
print("unwired codex hooks")
EOF

osascript -e 'tell application "ahem" to quit' 2>/dev/null || true
rm -rf "$REPO/build" /Applications/ahem.app
echo "removed ahem.app"

rm -rf "$HOME/.claude/agent-status"
echo "removed status files"
echo "\nOriginal settings (pre-install) remain at ~/.claude/settings.json.bak"
