#!/bin/zsh
# Build build/ahem.app: compile, bundle the scripts, ad-hoc sign.
# Used by install.sh and the Homebrew formula.
set -e
REPO=${0:A:h}
APP=$REPO/build/ahem.app
RES=$APP/Contents/Resources

command -v swiftc >/dev/null || {
  echo "swiftc not found -- install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
swiftc -O "$REPO/app/main.swift" -o "$APP/Contents/MacOS/ahem"
cp "$REPO/app/Info.plist" "$APP/Contents/"

# Self-contained: the app runs these from Resources. The repo layout is
# preserved so the scripts' relative sibling lookups keep working.
cp -R "$REPO/bin" "$REPO/plugin" "$REPO/hook" "$RES/"
cp "$REPO/codex-hooks.json" "$RES/"
rm -rf "$RES"/*/__pycache__
chmod +x "$RES/bin/ahem" "$RES/plugin/ahem.3s.sh" "$RES/hook/status.py"

codesign --sign - --force "$APP" 2>&1 | grep -v 'replacing existing signature' || true
echo "built   $APP"
