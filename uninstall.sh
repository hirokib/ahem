#!/bin/zsh
# Removes the app, unwires hooks, drops status files. Leaves the repo alone.
set -e
REPO=${0:A:h}

"$REPO/bin/ahem" unsetup
rm -f "$HOME/bin/ahem" "$HOME/bin/nag" "$HOME/bin/agents"
rm -f "$HOME/.swiftbar/ahem.3s.sh"  # from installs that predate ahem.app
rm -rf "$REPO/build"
echo "unlinked CLI, removed build/"
echo "\nOriginal settings (pre-install) remain at ~/.claude/settings.json.bak"
