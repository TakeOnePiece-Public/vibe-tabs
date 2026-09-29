#!/bin/zsh
# Install vibe-tab, vibe-tabs, and the Vibe Tabs app from this checkout.
set -euo pipefail

SCRIPT_PATH="${0:A}"
PROJECT_ROOT="${SCRIPT_PATH:h}"
BIN_DIR="$HOME/bin"
APP_DIR="$HOME/Applications"
APP_PATH="$APP_DIR/Vibe Tabs.app"

fail() {
  print -u2 "install.sh: error: $1"
  shift
  local line
  for line in "$@"; do print -u2 "  hint: $line"; done
  exit 1
}
# Name the step that failed instead of exiting silently under set -e.
current_step="starting"
TRAPZERR() { print -u2 "install.sh: error: failed while $current_step (command exited with status $?)"; }

[[ "$OSTYPE" == darwin* ]] || fail "Vibe Tabs only runs on macOS; this system is $OSTYPE"

current_step="checking the checkout"
for required in bin/vibe-tab bin/vibe-tabs libexec/open-vibe-tab.applescript libexec/open-vibe-tabs.applescript assets/VibeTabs.icns .vibe-tabs.yml.example; do
  [[ -e "$PROJECT_ROOT/$required" ]] || fail "missing $required in $PROJECT_ROOT" "Run install.sh from a complete checkout (git status should be clean)"
done

missing_tools=()
for tool in yq jq tmux; do
  whence -p "$tool" >/dev/null || missing_tools+=("$tool")
done
if (( ${#missing_tools} > 0 )); then
  print -u2 "install.sh: warning: not installed yet: ${missing_tools[*]}"
  print -u2 "  hint: brew install ${missing_tools[*]}"
fi

current_step="creating $BIN_DIR and $APP_DIR"
mkdir -p "$BIN_DIR" "$APP_DIR"

current_step="linking the commands into $BIN_DIR"
chmod +x "$PROJECT_ROOT/bin/vibe-tab" "$PROJECT_ROOT/bin/vibe-tabs"
ln -sfn "$PROJECT_ROOT/bin/vibe-tab" "$BIN_DIR/vibe-tab"
ln -sfn "$PROJECT_ROOT/bin/vibe-tabs" "$BIN_DIR/vibe-tabs"
ln -sfn "$PROJECT_ROOT/bin/vibe-tabs-add" "$BIN_DIR/vibe-tabs-add"

if [[ ! -e "$HOME/.vibe-tabs.yml" && ! -e "$HOME/.vibe-tabs.yaml" ]]; then
  current_step="creating ~/.vibe-tabs.yml from the example"
  cp "$PROJECT_ROOT/.vibe-tabs.yml.example" "$HOME/.vibe-tabs.yml"
  print "Created ~/.vibe-tabs.yml from the example"
fi

current_step="compiling the app (osacompile)"
/usr/bin/osacompile -o "$APP_PATH" "$PROJECT_ROOT/libexec/open-vibe-tabs.applescript"
current_step="setting the app icon and bundle id"
cp "$PROJECT_ROOT/assets/VibeTabs.icns" "$APP_PATH/Contents/Resources/VibeTabs.icns"
/usr/bin/plutil -replace CFBundleIconFile -string VibeTabs "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -remove CFBundleIconName "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
/usr/bin/plutil -replace CFBundleIdentifier -string com.takeonepiece.vibetabs "$APP_PATH/Contents/Info.plist"
# Accept dropped folders so a project can be added by dragging it onto the icon.
/usr/bin/plutil -replace CFBundleDocumentTypes -json '[{"CFBundleTypeName":"Project Folder","CFBundleTypeRole":"Editor","LSHandlerRank":"None","LSItemContentTypes":["public.folder"]}]' "$APP_PATH/Contents/Info.plist"
/usr/bin/touch "$APP_PATH"
current_step="signing the app (codesign)"
/usr/bin/codesign --force --deep --sign - "$APP_PATH" >/dev/null

print "Installed commands:"
print "  $BIN_DIR/vibe-tab"
print "  $BIN_DIR/vibe-tabs"
print "  $BIN_DIR/vibe-tabs-add"
print "Installed app:"
print "  $APP_PATH"
print "Config:"
print "  $HOME/.vibe-tabs.yml"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  print -u2 "install.sh: warning: $BIN_DIR is not in PATH; add it to use vibe-tabs from a shell"
fi
print "Check your config with: vibe-tabs --check"
