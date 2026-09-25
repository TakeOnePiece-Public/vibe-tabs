#!/bin/zsh
set -euo pipefail

TEST_DIR="${0:A:h}"
PROJECT_ROOT="${TEST_DIR:h}"
TEST_OUTPUT="$(mktemp)"
INVALID_OUTPUT="$(mktemp)"
trap '/bin/rm -f "$TEST_OUTPUT" "$INVALID_OUTPUT"' EXIT

VIBE_TABS_TEST_OUTPUT="$TEST_OUTPUT" \
  VIBE_TABS_SESSION_COMMAND="$TEST_DIR/capture-args.zsh" \
  "$PROJECT_ROOT/bin/vibe-tabs" "$TEST_DIR/fixtures/config.yml"

[[ "$(wc -l < "$TEST_OUTPUT" | tr -d ' ')" == "2" ]]
first_line="$(sed -n '1p' "$TEST_OUTPUT")"
second_line="$(sed -n '2p' "$TEST_OUTPUT")"

[[ "$first_line" == --layout\|even-horizontal\|--profile\|Pro\|--new-window\|alpha-test-mac\|/tmp\|* ]]
[[ "$second_line" == --layout\|tiled\|--profile\|Ocean\|beta-test-mac\|/tmp\|* ]]
[[ "$second_line" != *"--new-window"* ]]

first_codex="$(print -r -- "$first_line" | tr '|' '\n' | tail -n 1 | sed 's/^vibe-json://')"
second_gemini="$(print -r -- "$second_line" | tr '|' '\n' | sed -n '7p' | sed 's/^vibe-json://')"
print -r -- "$first_codex" | base64 -D | jq -e '.agent == "codex" and .dangerous == true and .args == ""' >/dev/null
print -r -- "$second_gemini" | base64 -D | jq -e '.agent == "gemini" and .dangerous == true and .args == "--model gemini-2.5-pro"' >/dev/null

if VIBE_TABS_SESSION_COMMAND="$TEST_DIR/capture-args.zsh" \
  VIBE_TABS_TEST_OUTPUT="$INVALID_OUTPUT" \
  "$PROJECT_ROOT/bin/vibe-tabs" "$TEST_DIR/fixtures/invalid-dangerous.yml" >"$INVALID_OUTPUT" 2>&1; then
  print -u2 "Expected invalid dangerous-mode configuration to fail"
  exit 1
fi

rg -q 'Invalid session entry' "$INVALID_OUTPUT"

# Named sessions launch alone, with or without the suffix, in config order.
: > "$TEST_OUTPUT"
VIBE_TABS_TEST_OUTPUT="$TEST_OUTPUT" \
  VIBE_TABS_SESSION_COMMAND="$TEST_DIR/capture-args.zsh" \
  "$PROJECT_ROOT/bin/vibe-tabs" "$TEST_DIR/fixtures/config.yml" beta-test-mac alpha
[[ "$(wc -l < "$TEST_OUTPUT" | tr -d ' ')" == "2" ]]
[[ "$(sed -n '1p' "$TEST_OUTPUT")" == *\|--new-window\|alpha-test-mac\|* ]]
[[ "$(sed -n '2p' "$TEST_OUTPUT")" == *\|beta-test-mac\|* ]]

if VIBE_TABS_SESSION_COMMAND="$TEST_DIR/capture-args.zsh" \
  VIBE_TABS_TEST_OUTPUT="$TEST_OUTPUT" \
  "$PROJECT_ROOT/bin/vibe-tabs" "$TEST_DIR/fixtures/config.yml" gamma >"$INVALID_OUTPUT" 2>&1; then
  print -u2 "Expected an unknown session name to fail"
  exit 1
fi
rg -q 'Unknown session: gamma' "$INVALID_OUTPUT"
osacompile -o /tmp/VibeTabTest.scpt "$PROJECT_ROOT/libexec/open-vibe-tab.applescript"
osacompile -o /tmp/VibeTabsAppTest.scpt "$PROJECT_ROOT/libexec/open-vibe-tabs.applescript"
dangerous_args="$(osascript \
  -e 'set testedScript to load script POSIX file "/tmp/VibeTabTest.scpt"' \
  -e "return testedScript's effectiveAgentArgs(\"codex\", true, \"--model gpt\", \"\")")"
[[ "$dangerous_args" == "--model gpt --yolo" ]]

# vibe-tabs add
ADD_CONFIG="$(mktemp -t vibe-tabs-add-config)"
ADD_DIR="$(mktemp -d -t vibe-tabs-add-dir)"
trap '/bin/rm -f "$TEST_OUTPUT" "$INVALID_OUTPUT" "$ADD_CONFIG" "$ADD_CONFIG.bak"; /bin/rm -rf "$ADD_DIR"' EXIT
/bin/cp "$TEST_DIR/fixtures/config.yml" "$ADD_CONFIG"
mkdir -p "$ADD_DIR/Gamma Project"

"$PROJECT_ROOT/bin/vibe-tabs" add --config "$ADD_CONFIG" --panes claude,gemini --layout tiled \
  "$ADD_DIR/Gamma Project" >/dev/null

yq -e '.sessions | length == 3' "$ADD_CONFIG" >/dev/null
yq -e '.sessions[2].name == "gamma-project"' "$ADD_CONFIG" >/dev/null
yq -e '.sessions[2].layout == "tiled"' "$ADD_CONFIG" >/dev/null
yq -o=json '.sessions[2].panes' "$ADD_CONFIG" | jq -e '. == [{"agent": "claude"}, {"agent": "gemini"}]' >/dev/null

# The fixture separates sessions with blank lines; the rewrite must keep them.
[[ "$(grep -c '^$' "$ADD_CONFIG")" -ge 4 ]]
rg -q '^  - name: gamma-project$' "$ADD_CONFIG"

# The added entry must survive the launcher's own validation.
VIBE_TABS_TEST_OUTPUT="$TEST_OUTPUT" \
  VIBE_TABS_SESSION_COMMAND="$TEST_DIR/capture-args.zsh" \
  "$PROJECT_ROOT/bin/vibe-tabs" "$ADD_CONFIG" >/dev/null

add_rejects() {
  if "$PROJECT_ROOT/bin/vibe-tabs" add --config "$ADD_CONFIG" "$@" >/dev/null 2>&1; then
    print -u2 "Expected 'vibe-tabs add $*' to fail"
    exit 1
  fi
}

add_rejects "$ADD_DIR/Gamma Project"
add_rejects --layout sideways "$ADD_DIR"
add_rejects --panes 'claude;rm -rf /' "$ADD_DIR"
add_rejects --name one --name two "$ADD_DIR" "$ADD_DIR/Gamma Project"
add_rejects "$ADD_DIR/does-not-exist"

# A rejected add must leave the config exactly as it was.
yq -e '.sessions | length == 3' "$ADD_CONFIG" >/dev/null

# A home-relative folder is stored with a tilde so it matches hand-written entries.
"$PROJECT_ROOT/bin/vibe-tabs" add --config "$ADD_CONFIG" --name tilde-check "$HOME" >/dev/null
yq -e '.sessions[3].path == "~"' "$ADD_CONFIG" >/dev/null

print "All tests passed"
