#!/bin/zsh
# Idempotent. Symlinks CLI + plugin, wires hooks into ~/.claude/settings.json.
set -e
REPO=${0:A:h}
BIN=$HOME/bin
SETTINGS=$HOME/.claude/settings.json

chmod +x "$REPO"/bin/ahem "$REPO"/hook/status.py "$REPO"/plugin/ahem.3s.sh "$REPO"/uninstall.sh "$REPO"/test.sh

mkdir -p "$BIN"
rm -f "$BIN/agents" "$BIN/nag"  # pre-rename names
ln -sf "$REPO/bin/ahem" "$BIN/ahem"
echo "linked  $BIN/ahem"


python3 - "$SETTINGS" "$REPO" <<'EOF'
import json, pathlib, shutil, sys
settings, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
cmd = f"python3 {repo}/hook/status.py"
EVENTS = ("SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd")

settings.parent.mkdir(parents=True, exist_ok=True)
d = json.loads(settings.read_text()) if settings.exists() else {}
if settings.exists() and not pathlib.Path(str(settings) + ".bak").exists():
    shutil.copy(settings, str(settings) + ".bak")
    print(f"backed up {settings}.bak")

hooks = d.setdefault("hooks", {})
for ev in EVENTS:
    arr = hooks.setdefault(ev, [])
    # drop our own prior entries (incl. the old ~/.claude/hooks path) then re-add
    for m in list(arr):
        # match on the tail, not a full path: this must still find our entries
        # after the project is moved or renamed, or they pile up as duplicates
        m["hooks"] = [h for h in m.get("hooks", [])
                      if "agent-status.py" not in h.get("command", "")
                      and "hook/status.py" not in h.get("command", "")]
        if not m["hooks"]:
            arr.remove(m)
    arr.append({"hooks": [{"type": "command", "command": cmd}]})

settings.write_text(json.dumps(d, indent=2) + "\n")
print("wired   " + ", ".join(EVENTS))
EOF

# superseded by hook/status.py in this repo
rm -f "$HOME/.claude/hooks/agent-status.py"

# Codex: only PermissionRequest is worth a hook (see README). Merge rather than
# overwrite -- and never touch config.toml's `notify`, which may already be spoken for.
if [ -d "$HOME/.codex" ]; then
  python3 - "$HOME/.codex/hooks.json" "$REPO" <<'EOF'
import json, pathlib, shutil, sys
p, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
ours = json.loads((pathlib.Path(repo) / "codex-hooks.json").read_text().replace("REPO", repo))

d = {}
if p.exists():
    try:
        d = json.loads(p.read_text())
    except Exception:
        d = {}
    if not pathlib.Path(str(p) + ".bak").exists():
        shutil.copy(p, str(p) + ".bak")
        print(f"backed up {p}.bak")

hooks = d.setdefault("hooks", {})
for ev, entries in ours["hooks"].items():
    arr = hooks.setdefault(ev, [])
    for m in list(arr):  # drop our own prior entries, keep everyone else's
        m["hooks"] = [h for h in m.get("hooks", []) if "hook/status.py" not in h.get("command", "")]
        if not m["hooks"]:
            arr.remove(m)
    arr.extend(entries)
p.write_text(json.dumps(d, indent=2) + "\n")
print("wired   codex PermissionRequest, Stop -> ~/.codex/hooks.json")
EOF
  echo "        (codex will ask you to trust these hooks on next start -- until then they are skipped)"
fi

# The menu bar app. A bundle, not a script, because UNUserNotificationCenter
# (native clickable banners) refuses to run outside one.
if command -v swiftc >/dev/null; then
  APP=$REPO/build/ahem.app
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc -O "$REPO/app/main.swift" -o "$APP/Contents/MacOS/ahem"
  cp "$REPO/app/Info.plist" "$APP/Contents/"
  echo "$REPO" > "$APP/Contents/Resources/repo-path"
  codesign --sign - --force "$APP" 2>&1 | grep -v 'replacing existing signature' || true
  osascript -e 'tell application "ahem" to quit' 2>/dev/null || true
  rm -rf /Applications/ahem.app
  ditto "$APP" /Applications/ahem.app
  echo "installed /Applications/ahem.app"
  echo "        open it now with: open /Applications/ahem.app"
  echo "        add it to System Settings > Login Items to keep it around"
else
  echo "swiftc not found (xcode-select --install) -- skipped building ahem.app."
  echo "'watch -n2 $REPO/plugin/ahem.3s.sh' works as the view instead."
fi
echo "\nDone. New sessions register automatically; existing ones on their next event."
