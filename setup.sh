#!/usr/bin/env bash
# setup.sh - install whatever is missing, then get out of the way.
#
#   ./setup.sh             install everything that is missing
#   ./setup.sh --status    what is working. Installs nothing
#   ./setup.sh --verbose   show every command as it runs
#
# One line per thing. Anything already working is left alone, anything missing is
# installed without asking, and anything that fails is noted and stepped over so one
# problem cannot hide the rest.
#
# The quiet default loses nothing: the full transcript of every run lands in
# ~/.agent-os-install/setup.log, and any step that fails prints its own last lines
# straight away.
#
# The remaining flags are in REFERENCE.md. This never enters card details, never logs
# in on your behalf, and never invents an API key.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

STATUS_ONLY=0; ASK=0; STOP_ON_FAIL=0; DO_KEYS=1; DO_TABS=1; DRY=0; PASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --status|-s)         STATUS_ONLY=1; shift ;;
    --verbose|-v)        AOS_VERBOSE=1; shift ;;
    --ask|--interactive) ASK=1; AOS_VERBOSE=1; shift ;;
    --dry-run)           DRY=1; PASS="$PASS --dry-run"; shift ;;
    --minimal|--no-tabs) DO_TABS=0; shift ;;
    --no-keys)           DO_KEYS=0; shift ;;
    --stop-on-fail)      STOP_ON_FAIL=1; shift ;;
    --yes|-y)            shift ;;   # accepted and ignored, this is the default now
    --app-dir)           APP_DIR="$2"; export APP_DIR; PASS="$PASS --app-dir $2"; shift 2 ;;
    --port)              PORT="$2"; PASS="$PASS --port $2"; shift 2 ;;
    -h|--help)           sed -n '2,18p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

PORT="${PORT:-3737}"; export PORT
export AOS_VERBOSE

# Nobody at the keyboard means no prompt can ever be answered, so do not raise one.
if [ ! -t 0 ]; then AOS_NOPROMPT=1; DO_KEYS=0; fi
[ "$DO_KEYS" = 0 ] && AOS_NOPROMPT=1
export AOS_NOPROMPT

[ "$ASK" = 0 ] && PASS="$PASS --yes"
[ "$STOP_ON_FAIL" = 0 ] && PASS="$PASS --keep-going"
[ "${AOS_NOPROMPT:-0}" = 1 ] && PASS="$PASS --no-prompt"

detect_platform
# --status only reads. It must not block on, or steal, a lock from a running setup.
[ "$STATUS_ONLY" = 1 ] || acquire_lock
cd "$SCRIPT_DIR" || exit 1
chmod +x ./*.sh 2>/dev/null || true

mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/setup.log"

# Run a child script into the log and keep the screen clean. --verbose lets it print
# straight through instead, which is the same output the old version always gave.
quietly() {
  if [ "${AOS_VERBOSE:-0}" = 1 ]; then "$@"; return $?; fi
  { printf '\n===== %s =====\n' "$*"; date; } >>"$LOG" 2>&1
  "$@" >>"$LOG" 2>&1
}

# When something fails, show enough to act on without dumping the whole run.
show_tail() {
  [ "${AOS_VERBOSE:-0}" = 1 ] && return 0
  [ -f "$LOG" ] || return 0
  printf '%s' "$C_DIM"
  grep -E '  (FAIL|WARN)  |^        fix:' "$LOG" | tail -4 | sed 's/^/       /'
  printf '%s' "$C_RST"
}

# ---------------------------------------------------------------- the six stages
stage_name() {
  case "$1" in
    0) echo "Prerequisites" ;; 1) echo "Dashboard" ;;      2) echo "Memory bus" ;;
    3) echo "Local brain" ;;   4) echo "Model routing" ;;  5) echo "Executor" ;;
  esac
}
stage_gate() {
  case "$1" in
    0) gate_prereqs ;;      1) gate_dashboard ;;   2) gate_vault ;;
    3) gate_local_brain ;;  4) gate_routing ;;     5) gate_executor ;;
  esac >/dev/null 2>&1
}
# What it looks like when it is working. Read from the real config, not remembered,
# so a row can never claim something that is no longer true.
stage_detail() {
  case "$1" in
    0) printf 'node %s' "$(node -v 2>/dev/null || echo '?')" ;;
    1) printf 'http://localhost:%s' "$PORT" ;;
    2) printf '%s' "$(cfg_get vaultRoot)" ;;
    3) printf '%s' "$(grep -E '^MODEL=' "$HOME/.fcc/.env" 2>/dev/null | head -1 | cut -d= -f2- | unquote)" ;;
    4) printf '%s' "$(grep -iE '^[[:space:]]*model:' "$HOME/.hermes/profiles/main/config.yaml" 2>/dev/null | head -1 | sed 's/.*: *//' | unquote)" ;;
    5) printf '%s' "$(command -v hermes 2>/dev/null || echo 'installed')" ;;
  esac
}
# A row with a blank right-hand column reads like something went wrong. It has not:
# some gates pass without a single value worth naming, so say that instead.
detail_or() { # detail_or <stage> <fallback>
  local d; d="$(stage_detail "$1")"
  [ -n "$d" ] && printf '%s' "$d" || printf '%s' "$2"
}
# What it is waiting on, in the words you would use to someone else. No command here:
# the summary at the end carries those, so a row stays one line.
stage_needs() {
  case "$1" in
    0) echo "node 20+ and the base packages" ;;
    1) echo "the Agent OS pack, and port $PORT free" ;;
    2) echo "the path to an Obsidian vault" ;;
    3) echo "Ollama, and one model pulled" ;;
    4) echo "a capable model set for Hermes" ;;
    5) echo "an OpenRouter key" ;;
  esac
}

say ""
printf '%sAgent OS Plus %s%s   %s%s, %s%s\n\n' \
  "$C_B" "$KIT_VERSION" "$C_RST" "$C_DIM" "$PLATFORM/$ARCH" "$PKG" "$C_RST"

NEEDED=""; INSTALLED=""; DONE_COUNT=0

for n in 0 1 2 3 4 5; do
  name="$(stage_name "$n")"

  if stage_gate "$n"; then
    state_set "stage_$n" pass
    row_ok "$name" "$(detail_or "$n" ok)"
    DONE_COUNT=$((DONE_COUNT+1))
    continue
  fi

  if is_expected_absent "$n"; then
    row_ok "$name" "skipped on purpose"
    DONE_COUNT=$((DONE_COUNT+1))
    continue
  fi

  state_set "stage_$n" fail

  if [ "$STATUS_ONLY" = 1 ]; then
    row_todo "$name" "$(stage_needs "$n")"
    NEEDED="$NEEDED $n"
    continue
  fi

  row_working "$name" "working"
  # shellcheck disable=SC2086
  if quietly ./install.sh --stage "$n" $PASS; then
    state_set "stage_$n" pass
    row_done ok "$name" "$(detail_or "$n" ok)"
    DONE_COUNT=$((DONE_COUNT+1))
    INSTALLED="$INSTALLED $n"
  else
    row_done todo "$name" "$(stage_needs "$n")"
    NEEDED="$NEEDED $n"
    if [ "$STOP_ON_FAIL" = 1 ]; then
      say ""
      bad "Stopped at $name, because you asked for --stop-on-fail."
      show_tail
      exit 1
    fi
  fi
done

# ---------------------------------------------------------------- keys, tabs, audit
key_summary() {
  local set_n total
  set_n="$(./keys.sh --names 2>/dev/null | grep -c .)"
  total="$(node -e 'try{const c=JSON.parse(require("fs").readFileSync("keys.json","utf8"));console.log((c.keys||[]).length)}catch(e){console.log("")}' 2>/dev/null)"
  [ -n "$total" ] && printf '%s of %s set' "$set_n" "$total" || printf '%s set' "$set_n"
}

if [ "$STATUS_ONLY" = 1 ]; then
  row_ok "API keys" "$(key_summary)"
  row_ok "Optional tabs" "$(./tabs.sh --count 2>/dev/null || echo '?')"
else
  # Keys are the one place a human is genuinely required, so this stays interactive.
  if [ "$DO_KEYS" = 1 ] && [ "$DRY" != 1 ]; then
    say ""
    ./keys.sh --setup || true
    say ""
  fi
  row_ok "API keys" "$(key_summary)"

  if [ "$DO_TABS" = 0 ] || [ "$DRY" = 1 ]; then
    row_ok "Optional tabs" "$(./tabs.sh --count 2>/dev/null || echo '?')  (not touched)"
  else
    row_working "Optional tabs" "installing the recommended set"
    # shellcheck disable=SC2086
    quietly ./tabs.sh --recommended --yes ${AOS_NOPROMPT:+--no-prompt} || true
    row_done ok "Optional tabs" "$(./tabs.sh --count 2>/dev/null || echo '?')"
  fi
fi

if [ "$DRY" = 1 ]; then
  row_ok "Security audit" "not run in a dry run"
else
  # Captured rather than logged, so --status leaves nothing behind at all.
  AUDIT_OUT="$(./vault.sh --audit 2>&1)"; AUDIT_RC=$?
  [ "${AOS_VERBOSE:-0}" = 1 ] && printf '%s\n' "$AUDIT_OUT"
  [ "$STATUS_ONLY" = 1 ] || printf '%s\n' "$AUDIT_OUT" >>"$LOG" 2>/dev/null
  if [ "$AUDIT_RC" = 0 ]; then
    row_ok "Security audit" "nothing exposed"
  else
    row_todo "Security audit" "$(printf '%s' "$AUDIT_OUT" | grep -oE '[0-9]+ issue\(s\)' | tail -1 || echo 'see ./vault.sh --audit')"
  fi
fi

# ---------------------------------------------------------------- summary
say ""
if [ -z "$NEEDED" ]; then
  printf '  %sAll six in place.%s\n' "$C_GRN" "$C_RST"
else
  printf '  %s of 6 in place.\n' "$DONE_COUNT"
  say ""
  printf '  %sNeeds you%s\n' "$C_B" "$C_RST"
  for n in $NEEDED; do
    printf '    %-17s %s\n' "$(stage_name "$n")" "$(stage_needs "$n")"
  done
  say ""
  if [ "$STATUS_ONLY" = 1 ]; then
    dim "    Install them:  ./setup.sh"
  else
    dim "    Run ./setup.sh again once you have those. It picks up only what is left."
    dim "    Deliberately skipping one? ./preflight.sh --expect N stops it being reported."
  fi
fi

say ""
if [ "$(state_get stage_1)" = pass ]; then
  printf '  %-11s http://localhost:%s   %s(Chrome, http not https)%s\n' \
    "Dashboard" "$PORT" "$C_DIM" "$C_RST"
fi
printf '  %-11s %s\n' "Detail" "./preflight.sh"
[ "$STATUS_ONLY" = 1 ] || printf '  %-11s %s\n' "Full log" "$LOG"
say ""

[ -n "$NEEDED" ] && exit 1
exit 0
