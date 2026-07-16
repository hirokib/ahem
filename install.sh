#!/bin/zsh
# Dev install: build the app, install it, wire the hooks. Idempotent.
# (Homebrew users: the formula builds, then `ahem setup` does the rest.)
set -e
REPO=${0:A:h}

chmod +x "$REPO"/bin/ahem "$REPO"/hook/status.py "$REPO"/plugin/ahem.3s.sh \
         "$REPO"/build.sh "$REPO"/uninstall.sh "$REPO"/test.sh

mkdir -p "$HOME/bin"
rm -f "$HOME/bin/agents" "$HOME/bin/nag"  # pre-rename names
ln -sf "$REPO/bin/ahem" "$HOME/bin/ahem"
echo "linked  $HOME/bin/ahem"

"$REPO/build.sh"
"$REPO/bin/ahem" setup
