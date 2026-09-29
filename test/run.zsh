#!/bin/zsh
# Test suite for vibe-tabs. Nothing here opens Terminal tabs or tmux sessions:
# the launcher is replaced by capture-args.zsh, and the AppleScript is only
# exercised on paths that fail before it talks to Terminal.
set -uo pipefail

TEST_DIR="${0:A:h}"
PROJECT_ROOT="${TEST_DIR:h}"
VIBE_TABS="$PROJECT_ROOT/bin/vibe-tabs"
VIBE_TAB="$PROJECT_ROOT/bin/vibe-tab"
CAPTURE="$TEST_DIR/capture-args.zsh"

tmp_root="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${tmp_root%/}/vibe-tabs-test.XXXXXX")"
WORK="${WORK:A}"  # /var is a symlink to /private/var on macOS
trap '/bin/rm -rf "$WORK"' EXIT
export VIBE_TABS_TEST_OUTPUT="$WORK/captured.txt"

passed=0
failed=0
OUT=""
STATUS=0

# run CMD... : run with the fake launcher, capture combined output and status.
run() {
  : >"$VIBE_TABS_TEST_OUTPUT"
  OUT="$(VIBE_TABS_SESSION_COMMAND="${LAUNCHER:-$CAPTURE}" "$@" 2>&1)"
  STATUS=$?
}

check() {
  local name=$1 condition=$2
  if eval "$condition"; then
    (( passed += 1 ))
  else
    (( failed += 1 ))
    print -u2 "FAIL: $name"
    print -u2 "  condition: $condition"
    print -u2 "  status: $STATUS"
    print -u2 -- "  output:"
    print -ru2 -- "${OUT//$'\n'/$'\n'    }"
  fi
}

# expect NAME STATUS PATTERN... : last run exited with STATUS and output contains every PATTERN.
expect() {
  local name=$1 want_status=$2 pattern ok=true
  shift 2
  [[ "$STATUS" == "$want_status" ]] || ok=false
  for pattern in "$@"; do
    [[ "$OUT" == *"$pattern"* ]] || ok=false
  done
  check "$name" "$ok"
}

write_config() { print -r -- "$2" >"$WORK/$1"; }
captured_lines() { [[ -s "$VIBE_TABS_TEST_OUTPUT" ]] && wc -l <"$VIBE_TABS_TEST_OUTPUT" | tr -d ' ' || print 0; }

# ---------------------------------------------------------------------------
# Happy path (original behavior)
# ---------------------------------------------------------------------------

run "$VIBE_TABS" "$TEST_DIR/fixtures/config.yml"
expect "valid config opens both sessions" 0 "opened 2 session(s)"
check "two launcher calls" '[[ "$(captured_lines)" == 2 ]]'
first_line="$(sed -n '1p' "$VIBE_TABS_TEST_OUTPUT")"
second_line="$(sed -n '2p' "$VIBE_TABS_TEST_OUTPUT")"
check "first session args" '[[ "$first_line" == --layout\|even-horizontal\|--profile\|Pro\|--new-window\|alpha-test-mac\|/tmp\|* ]]'
check "second session args" '[[ "$second_line" == --layout\|tiled\|--profile\|Ocean\|beta-test-mac\|/tmp\|* ]]'
check "only first session gets --new-window" '[[ "$second_line" != *"--new-window"* ]]'
first_codex="$(print -r -- "$first_line" | tr '|' '\n' | tail -n 1 | sed 's/^vibe-json://')"
second_gemini="$(print -r -- "$second_line" | tr '|' '\n' | sed -n '7p' | sed 's/^vibe-json://')"
check "codex pane inherits dangerous default" 'print -r -- "$first_codex" | base64 -D | jq -e ".agent == \"codex\" and .dangerous == true and .args == \"\"" >/dev/null'
check "gemini pane keeps its args" 'print -r -- "$second_gemini" | base64 -D | jq -e ".agent == \"gemini\" and .dangerous == true and .args == \"--model gemini-2.5-pro\"" >/dev/null'

run "$VIBE_TABS" --check "$TEST_DIR/fixtures/config.yml"
expect "--check lists sessions" 0 "is valid: 2 session(s)" "alpha-test-mac" "panes: claude | codex [dangerous]"
check "--check does not launch" '[[ "$(captured_lines)" == 0 ]]'

run "$VIBE_TABS" --help
expect "--help" 0 "Usage: vibe-tabs"

# ---------------------------------------------------------------------------
# Usage and config file problems
# ---------------------------------------------------------------------------

run "$VIBE_TABS" --bogus
expect "unknown option" 2 "unknown option: --bogus"

run "$VIBE_TABS" a.yml b.yml
expect "two config files" 2 "only one config file"

run "$VIBE_TABS" "$WORK/nope.yml"
expect "missing config" 2 "config file not found: $WORK/nope.yml"

run "$VIBE_TABS" "$WORK"
expect "config is a folder" 2 "config path is a folder"

ln -s "$WORK/gone.yml" "$WORK/broken-link.yml"
run "$VIBE_TABS" "$WORK/broken-link.yml"
expect "config is a broken symlink" 2 "broken symlink"

write_config unreadable.yml "version: 1"
chmod 000 "$WORK/unreadable.yml"
run "$VIBE_TABS" "$WORK/unreadable.yml"
expect "unreadable config" 2 "not readable (permission denied)"
chmod 644 "$WORK/unreadable.yml"

run env HOME="$WORK/emptyhome" "$VIBE_TABS"
expect "no default config" 2 "no config found" "cp '"

: >"$WORK/empty.yml"
run "$VIBE_TABS" "$WORK/empty.yml"
expect "empty config" 2 "is empty"

write_config comments.yml "# nothing here yet"
run "$VIBE_TABS" "$WORK/comments.yml"
expect "comment-only config" 2 "is empty"

write_config broken.yml $'version: 1\nsessions:\n  - name: x\n    path: /tmp\n  bad: [\n'
run "$VIBE_TABS" "$WORK/broken.yml"
expect "YAML syntax error names the line" 2 "is not valid YAML" "line 4" "hint: Check indentation"

write_config multi.yml $'version: 1\n---\nsessions: []\n'
run "$VIBE_TABS" "$WORK/multi.yml"
expect "multiple YAML documents" 2 "contains 2 YAML documents"

# ---------------------------------------------------------------------------
# Structural validation: every problem is reported, nothing is launched
# ---------------------------------------------------------------------------

write_config list.yml "- a"
run "$VIBE_TABS" "$WORK/list.yml"
expect "top level must be a mapping" 2 "must be a mapping with version, defaults, and sessions"

write_config version.yml $'version: 2\nsessions:\n  - name: a\n    path: /tmp\n'
run "$VIBE_TABS" "$WORK/version.yml"
expect "unsupported version" 2 'unsupported config version 2'

write_config nosessions.yml "version: 1"
run "$VIBE_TABS" "$WORK/nosessions.yml"
expect "missing sessions" 2 "sessions is missing"

write_config emptysessions.yml $'version: 1\nsessions: []\n'
run "$VIBE_TABS" "$WORK/emptysessions.yml"
expect "empty sessions" 2 "sessions is empty"

write_config sessionsmap.yml $'version: 1\nsessions:\n  name: a\n  path: /tmp\n'
run "$VIBE_TABS" "$WORK/sessionsmap.yml"
expect "sessions must be a list" 2 'sessions must be a list (each entry starts with "- name:")'

write_config many.yml $'version: 1\ndefaults:\n  layout: sideways\n  agents: [claude]\nsessions:\n  - name: 2024\n    path: /tmp\n  - path: /tmp\n  - name: c\n    path: /tmp\n    panes: []\n  - name: d\n    path: /tmp\n    panes:\n      - agent: claude\n        dangerous: "yes"\n      - 42\n'
run "$VIBE_TABS" "$WORK/many.yml"
expect "all structural problems reported together" 2 \
  'layout "sideways" is not supported' \
  "defaults.agents must be a mapping" \
  "name must be text, got number 2024; wrap it in quotes" \
  "session #2: name is required" \
  'session "c": panes must list at least one pane' \
  'session "d", pane 1: dangerous must be true or false, got "yes"' \
  'session "d", pane 2 must be an agent name, a command, or a mapping; got number 42' \
  "problem(s)" "nothing was opened"
check "invalid config launches nothing" '[[ "$(captured_lines)" == 0 ]]'

write_config panes.yml $'version: 1\nsessions:\n  - name: a\n    path: /tmp\n    panes:\n      - agent: claude\n        command: ls\n      - title: lonely\n      - agent: unknown-agent\n        dangerous: true\n      - command: make\n        dangerous: true\n'
run "$VIBE_TABS" "$WORK/panes.yml"
expect "pane rules" 2 \
  'pane 1 sets both agent ("claude") and command ("ls")' \
  "pane 2 needs an agent or a command" \
  'pane 3 sets dangerous: true for agent "unknown-agent", which has no built-in dangerous flag' \
  "pane 4 sets dangerous: true on a command pane"

run "$VIBE_TABS" "$TEST_DIR/fixtures/invalid-dangerous.yml"
expect "invalid dangerous fixture" 2 "no built-in dangerous flag"

write_config dupes.yml $'version: 1\ndefaults:\n  session_suffix: mac\nsessions:\n  - name: my app\n    path: /tmp\n  - name: my-app\n    path: /tmp\n'
run "$VIBE_TABS" "$WORK/dupes.yml"
expect "duplicate session names" 2 "both become tmux session 'my-app-mac'"

write_config noname.yml $'version: 1\nsessions:\n  - name: "!!!"\n    path: /tmp\n'
run "$VIBE_TABS" "$WORK/noname.yml"
expect "session name without letters" 2 "must contain at least one letter or number"

write_config typo.yml $'version: 1\nsesions: []\nsessions:\n  - name: a\n    path: /tmp\n    layuot: tiled\n'
run "$VIBE_TABS" "$WORK/typo.yml"
expect "unknown keys warn but still launch" 0 \
  'warning:' 'unknown key "sesions" is ignored' 'unknown key "layuot" is ignored' "opened 1 session(s)"

# ---------------------------------------------------------------------------
# Per-session problems: skip that session, open the rest, exit 1
# ---------------------------------------------------------------------------

mkdir -p "$WORK/projects/real" && : >"$WORK/projects/afile"
write_config paths.yml $'version: 1\nsessions:\n  - name: missing\n    path: projects/nope\n  - name: relative\n    path: projects/real\n  - name: file\n    path: projects/afile\n  - name: tilde-user\n    path: ~root/x\n'
run "$VIBE_TABS" "$WORK/paths.yml"
expect "bad paths are skipped, others open" 1 \
  "missing: skipped, project folder does not exist: $WORK/projects/nope" \
  "file: skipped, project path is a file, not a folder" \
  "uses ~user, which is not supported" \
  "opened 1 of 4 session(s); 3 failed"
check "relative path resolved from config folder and gets --new-window" \
  'grep -q -- "--new-window|relative|$WORK/projects/real" "$VIBE_TABS_TEST_OUTPUT"'

run "$VIBE_TABS" --check "$WORK/paths.yml"
expect "--check reports skipped sessions" 1 "3 session(s) would be skipped"

print -r -- $'#!/bin/zsh\n[[ "$*" == *second* ]] && { print -u2 "boom"; exit 3; }\nexit 0' >"$WORK/flaky-launcher.zsh"
chmod +x "$WORK/flaky-launcher.zsh"
write_config flaky.yml $'version: 1\nsessions:\n  - name: first\n    path: /tmp\n  - name: second\n    path: /tmp\n  - name: third\n    path: /tmp\n'
LAUNCHER="$WORK/flaky-launcher.zsh" run "$VIBE_TABS" "$WORK/flaky.yml"
expect "launcher failure does not stop later sessions" 1 \
  "boom" "second: could not be opened (launcher exited with status 3" "opened 2 of 3 session(s); 1 failed"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

run env VIBE_TABS_YQ="$WORK/no-yq" "$VIBE_TABS" "$TEST_DIR/fixtures/config.yml"
expect "missing yq" 2 "yq is not installed" "brew install yq"

print -r -- $'#!/bin/zsh\nprint "yq 0.0.0"' >"$WORK/python-yq"
chmod +x "$WORK/python-yq"
run env VIBE_TABS_YQ="$WORK/python-yq" "$VIBE_TABS" "$TEST_DIR/fixtures/config.yml"
expect "wrong yq flavor" 2 "is not mikefarah/yq version 4"

run env VIBE_TABS_JQ="$WORK/no-jq" "$VIBE_TABS" "$TEST_DIR/fixtures/config.yml"
expect "missing jq" 2 "jq is not installed" "brew install jq"

LAUNCHER="$WORK/no-launcher" run "$VIBE_TABS" "$TEST_DIR/fixtures/config.yml"
expect "missing launcher" 2 "the session launcher is missing"

# ---------------------------------------------------------------------------
# vibe-tab: argument errors and AppleScript error translation
# ---------------------------------------------------------------------------

OUT="$("$VIBE_TAB" 2>&1)"; STATUS=$?
expect "vibe-tab without arguments prints usage" 1 "Usage: vibe-tab"

OUT="$("$VIBE_TAB" demo "$WORK/does-not-exist" 2>&1)"; STATUS=$?
expect "vibe-tab missing folder" 1 "vibe-tab: error: Project folder does not exist: $WORK/does-not-exist"

OUT="$("$VIBE_TAB" demo "$WORK/projects/afile" 2>&1)"; STATUS=$?
expect "vibe-tab path is a file" 1 "Project path is a file, not a folder"

OUT="$("$VIBE_TAB" --layout sideways demo /tmp 2>&1)"; STATUS=$?
expect "vibe-tab bad layout" 1 'Unsupported tmux layout "sideways"'

OUT="$("$VIBE_TAB" --bogus demo /tmp 2>&1)"; STATUS=$?
expect "vibe-tab unknown option" 1 "Unknown option: --bogus"

OUT="$(cd "$WORK" && "$VIBE_TAB" demo projects/missing-too 2>&1)"; STATUS=$?
expect "vibe-tab resolves relative folders from the current folder" 1 "Project folder does not exist: $WORK/projects/missing-too"

print -r -- $'#!/bin/zsh\nprint -u2 "vibe-tab: a log line"\nprint -u2 "/x/open-vibe-tab.applescript:10:20: execution error: Terminal got an error: Not authorized to send Apple events to Terminal. (while opening a Terminal tab for demo) (-1743)"\nexit 1' >"$WORK/fake-osascript"
chmod +x "$WORK/fake-osascript"
OUT="$(VIBE_TAB_OSASCRIPT="$WORK/fake-osascript" "$VIBE_TAB" demo /tmp 2>&1)"; STATUS=$?
expect "Automation error is explained" 1 \
  "vibe-tab: a log line" \
  "vibe-tab: error: Terminal got an error: Not authorized to send Apple events to Terminal. (while opening a Terminal tab for demo) [AppleScript error -1743]" \
  "Privacy & Security > Automation"

print -r -- $'#!/bin/zsh\nprint -u2 "/x/open-vibe-tab.applescript:1:2: execution error: System Events got an error: osascript is not allowed to send keystrokes. (1002)"\nexit 1' >"$WORK/fake-osascript"
OUT="$(VIBE_TAB_OSASCRIPT="$WORK/fake-osascript" "$VIBE_TAB" demo /tmp 2>&1)"; STATUS=$?
expect "Accessibility error is explained" 1 "[AppleScript error 1002]" "Privacy & Security > Accessibility"

print -r -- $'#!/bin/zsh\nprint -u2 "/x/open-vibe-tab.applescript:5:9: syntax error: Expected end of line. (-2741)"\nexit 1' >"$WORK/fake-osascript"
OUT="$(VIBE_TAB_OSASCRIPT="$WORK/fake-osascript" "$VIBE_TAB" demo /tmp 2>&1)"; STATUS=$?
expect "damaged AppleScript is explained" 1 "failed to compile" "reinstall vibe-tabs"

# ---------------------------------------------------------------------------
# AppleScript handlers
# ---------------------------------------------------------------------------

check "open-vibe-tab.applescript compiles" 'osacompile -o "$WORK/VibeTab.scpt" "$PROJECT_ROOT/libexec/open-vibe-tab.applescript" 2>/dev/null'
check "open-vibe-tabs.applescript compiles" 'osacompile -o "$WORK/VibeTabsApp.scpt" "$PROJECT_ROOT/libexec/open-vibe-tabs.applescript" 2>/dev/null'

applescript_call() {
  osascript -e "set testedScript to load script POSIX file \"$WORK/VibeTab.scpt\"" -e "try" -e "return testedScript's $1" -e "on error errorMessage" -e "return \"ERROR: \" & errorMessage" -e "end try" 2>&1
}

OUT="$(applescript_call 'effectiveAgentArgs("codex", true, "--model gpt", "")')"; STATUS=0
check "dangerous args appended" '[[ "$OUT" == "--model gpt --yolo" ]]'
OUT="$(applescript_call 'codexResumeOptions("resume --last --yolo")')"
check "codex resume options drop resume and --last" '[[ "$OUT" == "--yolo" ]]'
mkdir -p "$WORK/codex-home/.codex/sessions/2026/09/10" "$WORK/codex-home/.codex/archived_sessions"
: >"$WORK/codex-home/.codex/sessions/2026/09/10/rollout-2026-09-10T08-49-17-kept-thread.jsonl"
OUT="$(applescript_call "codexRolloutExists(\"$WORK/codex-home\", \"kept-thread\")")"
check "codex thread with a rollout is resumable" '[[ "$OUT" == "true" ]]'
OUT="$(applescript_call "codexRolloutExists(\"$WORK/codex-home\", \"pruned-thread\")")"
check "codex thread without a rollout starts fresh" '[[ "$OUT" == "false" ]]'
OUT="$(applescript_call "codexRolloutExists(\"$WORK/codex-home\", \"\")")"
check "empty codex thread id is not resumable" '[[ "$OUT" == "false" ]]'
OUT="$(applescript_call 'absoluteProjectPath("~/code", "/Users/me")')"
check "~/ expands" '[[ "$OUT" == "/Users/me/code" ]]'
OUT="$(applescript_call 'findExecutable("definitely-not-a-command-xyz", {"/nonexistent/x"})')"
check "findExecutable returns empty when missing" '[[ -z "$OUT" ]]'
OUT="$(applescript_call 'resolveExecutable("definitely-not-a-command-xyz", {"/nonexistent/x"})')"
check "resolveExecutable explains what is missing" '[[ "$OUT" == "ERROR: Required command not found: definitely-not-a-command-xyz. Looked in your login shell PATH and in /nonexistent/x."* ]]'
OUT="$(applescript_call 'commandLabel("", 3)')"
check "commandLabel falls back for empty commands" '[[ "$OUT" == "pane-3" ]]'

# ---------------------------------------------------------------------------
# Named sessions
# ---------------------------------------------------------------------------

run "$VIBE_TABS" "$TEST_DIR/fixtures/config.yml" beta-test-mac alpha
expect "named sessions open alone" 0 "opened 2 session(s)"
check "named sessions keep config order" '[[ "$(sed -n 1p "$VIBE_TABS_TEST_OUTPUT")" == *\|--new-window\|alpha-test-mac\|* && "$(sed -n 2p "$VIBE_TABS_TEST_OUTPUT")" == *\|beta-test-mac\|* ]]'

run "$VIBE_TABS" "$TEST_DIR/fixtures/config.yml" beta
expect "one named session" 0 "opened 1 session(s)"
check "a lone named session gets its own window" '[[ "$(captured_lines)" == 1 && "$(cat "$VIBE_TABS_TEST_OUTPUT")" == *\|--new-window\|beta-test-mac\|* ]]'

run "$VIBE_TABS" "$TEST_DIR/fixtures/config.yml" gamma
expect "unknown session name" 2 "unknown session: gamma" "sessions in" "alpha beta"
check "unknown session opens nothing" '[[ "$(captured_lines)" == 0 ]]'

# ---------------------------------------------------------------------------
# vibe-tabs add
# ---------------------------------------------------------------------------

ADD_CONFIG="$WORK/add-config.yml"
ADD_DIR="$WORK/add-dir"
/bin/cp "$TEST_DIR/fixtures/config.yml" "$ADD_CONFIG"
mkdir -p "$ADD_DIR/Gamma Project"

run "$VIBE_TABS" add --config "$ADD_CONFIG" --panes claude,gemini --layout tiled "$ADD_DIR/Gamma Project"
check "add appends a session" '[[ "$STATUS" == 0 ]] && yq -e ".sessions | length == 3" "$ADD_CONFIG" >/dev/null'
check "add derives the name from the folder" 'yq -e ".sessions[2].name == \"gamma-project\"" "$ADD_CONFIG" >/dev/null'
check "add stores the layout" 'yq -e ".sessions[2].layout == \"tiled\"" "$ADD_CONFIG" >/dev/null'
check "add stores the panes" 'yq -o=json ".sessions[2].panes" "$ADD_CONFIG" | jq -e ". == [{\"agent\": \"claude\"}, {\"agent\": \"gemini\"}]" >/dev/null'
check "add keeps blank lines between sessions" '[[ "$(grep -c "^$" "$ADD_CONFIG")" -ge 4 ]] && rg -q "^  - name: gamma-project$" "$ADD_CONFIG"'

run "$VIBE_TABS" --check "$ADD_CONFIG"
expect "added entry passes the launcher's validation" 0 "is valid: 3 session(s)"

add_rejects() {
  run "$VIBE_TABS" add --config "$ADD_CONFIG" "$@"
  check "add rejects: $*" '[[ "$STATUS" != 0 ]]'
}
add_rejects "$ADD_DIR/Gamma Project"
add_rejects --layout sideways "$ADD_DIR"
add_rejects --panes 'claude;rm -rf /' "$ADD_DIR"
add_rejects "$ADD_DIR/does-not-exist"
add_rejects --name one --name two "$ADD_DIR" "$ADD_DIR/Gamma Project"
check "rejected adds leave the config alone" 'yq -e ".sessions | length == 3" "$ADD_CONFIG" >/dev/null'

run "$VIBE_TABS" add --config "$ADD_CONFIG" --name tilde-check "$HOME"
check "home folder is stored as ~" 'yq -e ".sessions[3].path == \"~\"" "$ADD_CONFIG" >/dev/null'

print ""
if (( failed > 0 )); then
  print -u2 "$failed test(s) failed, $passed passed"
  exit 1
fi
print "All $passed tests passed"
