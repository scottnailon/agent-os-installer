#!/usr/bin/env bash
# test-regressions.sh - guards the bug classes that are easy to reintroduce.
#
# Kept separate from test.sh so the file stays small enough to read in one sitting.
#
#   ./test-regressions.sh            run them
#   ./test-regressions.sh --verbose  show why a failure happened
#
# Runs in a sandboxed HOME. Your real config is never touched.

set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; B=""; N=""
fi

PASS=0; FAIL=0; FAILED_NAMES=""

sandbox() {   # a throwaway HOME plus a copy of the kit, so nothing real is touched
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/home" "$SANDBOX/pack/agent-os-plus" "$SANDBOX/pack/source"
  cp "$KIT"/*.sh "$KIT"/*.json "$KIT"/VERSION "$SANDBOX/pack/agent-os-plus/" 2>/dev/null
  cp "$KIT"/.routing-parse.js "$KIT"/.strip-json-keys.js "$SANDBOX/pack/agent-os-plus/" 2>/dev/null
  echo '{"name":"agentic-os"}' > "$SANDBOX/pack/source/package.json"
  chmod +x "$SANDBOX/pack/agent-os-plus"/*.sh 2>/dev/null
  export HOME="$SANDBOX/home"
  K="$SANDBOX/pack/agent-os-plus"
}
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }

t() {  # t "name" function
  local name="$1" fn="$2" out rc
  sandbox
  out="$("$fn" 2>&1)"; rc=$?
  cleanup
  if [ "$rc" = 0 ]; then
    printf '%s  PASS%s  %s\n' "$G" "$N" "$name"; PASS=$((PASS+1))
  else
    printf '%s  FAIL%s  %s\n' "$R" "$N" "$name"; FAIL=$((FAIL+1))
    FAILED_NAMES="$FAILED_NAMES
  $name"
    [ "$VERBOSE" = 1 ] && printf '%s\n' "$out"
  fi
}

# --------------------------------------------------------------------- locking
# setup.sh takes the lock, then calls install.sh, keys.sh and tabs.sh, each of which
# also locks. Without the inherit check this deadlocks against its own parent, and the
# run stops at step 2 of 7 with "Another agent-os-plus command is running".
test_nested_run_inherits_lock() {
  local out
  # vault.sh calls acquire_lock, so it is a genuine child contending for the same lock.
  # Do not truncate its output: the deadlock message is the LAST thing it prints, after
  # three "waiting" lines, so a head -n here would hide the very thing being tested.
  out="$(cd "$K" && bash -c '
    . ./lib.sh
    acquire_lock
    ./vault.sh --status 2>&1
    ./tabs.sh --list 2>&1
  ' 2>&1)"
  case "$out" in
    *"Another agent-os-plus command is running"*|*"Waiting for another run to finish"*)
      echo "a child contended for its own parent's lock"
      echo "$out"
      return 1 ;;
  esac
  return 0
}

# A ( ) subshell sees the same $$ as its parent, so without a BASHPID check an exiting
# subshell would unlock a run still in progress. install.sh runs builds in subshells.
test_child_exit_keeps_parent_lock() {
  # Call release_lock directly inside a ( ) subshell. Going through acquire_lock would
  # hit the inherit check first and never set a trap, so the guard being tested here
  # would never be reached and the test would pass regardless.
  cd "$K" && bash -c '
    . ./lib.sh
    acquire_lock
    ( release_lock )                  # a subshell exiting must not unlock the parent
    if [ ! -d "$LOCK_DIR" ]; then
      echo "a subshell released the parent lock"
      exit 1
    fi
    release_lock                      # the owning shell still can
    if [ -d "$LOCK_DIR" ]; then
      echo "the owning shell could not release its own lock"
      exit 1
    fi
  '
}

# ------------------------------------------------------------------- transport
# The quote-stripping expression was mangled twice while being published, each time
# into something that stayed valid bash but behaved differently. One version also
# stripped backslashes; the other also stripped digits, so ollama/gemma2 was read as
# ollama/gemma. A syntax check cannot see either, so this asserts the behaviour.
test_unquote_strips_only_quotes_and_spaces() {
  local out
  # AOS_DQ is a double quote, defined by lib.sh. Using it keeps this test itself free
  # of backslashes, which is the property being tested.
  out="$(cd "$K" && bash -c '. ./lib.sh >/dev/null 2>&1; printf "%s" "${AOS_DQ}ollama/gemma2${AOS_DQ} " | unquote')"
  if [ "$out" != "ollama/gemma2" ]; then
    echo "unquote returned [$out], expected [ollama/gemma2]"
    return 1
  fi
  return 0
}

# A model value written with surrounding quotes must still be read correctly, since
# that is how earlier versions of install.sh wrote ~/.fcc/.env.
test_routing_reads_a_quoted_model_value() {
  local out
  mkdir -p "$HOME/.fcc"
  cd "$K" && bash -c '. ./lib.sh >/dev/null 2>&1; printf "MODEL=%sollama/gemma2%s\n" "$AOS_DQ" "$AOS_DQ" > "$HOME/.fcc/.env"'
  out="$(cd "$K" && bash -c '. ./lib.sh; detect_platform; gate_routing' 2>&1)"
  case "$out" in
    *"Local build routing: ollama/gemma2"*) return 0 ;;
    *) echo "expected 'Local build routing: ollama/gemma2', got:"; echo "$out"; return 1 ;;
  esac
}


# ------------------------------------------------------- one command, no blocking
# The whole promise of setup.sh is one command that installs what is missing and
# moves on. Three things break that promise, and all three are one careless edit
# away, so each is asserted rather than assumed.

# 1. An unattended run must never sit on a read() nobody will answer. A prompt that
#    slips back in shows up as a cron job that hangs until it is killed, which is
#    invisible until someone notices the health check stopped arriving.
test_unattended_setup_never_blocks() {
  local out rc
  # No stdin, and a short timeout. A blocking prompt cannot survive both.
  out="$(cd "$K" && timeout 120 bash ./setup.sh --dry-run --no-keys </dev/null 2>&1)"; rc=$?
  if [ "$rc" = 124 ]; then
    echo "setup.sh --dry-run --no-keys blocked and had to be killed"
    printf '%s\n' "$out" | tail -20
    return 1
  fi
  case "$out" in
    *"Setup complete"*) return 0 ;;
    *) echo "setup.sh did not reach the end. Last lines:"; printf '%s\n' "$out" | tail -20; return 1 ;;
  esac
}

# 2. A failing stage must not end the run. The old behaviour exited at the first
#    failure, so a missing Obsidian vault at stage 2 hid whether stages 3, 4 and 5
#    would have worked, and you found out one re-run at a time.
test_a_failing_stage_does_not_end_the_run() {
  local out
  # Nothing is installed in the sandbox, so stage 2 onwards all fail. Every one of
  # them must still be attempted.
  out="$(cd "$K" && timeout 120 bash ./install.sh --from 2 --yes --dry-run --keep-going --no-prompt </dev/null 2>&1)"
  case "$out" in
    *"Stage 5"*) : ;;
    *) echo "install.sh --keep-going stopped before stage 5:"; printf '%s\n' "$out" | tail -20; return 1 ;;
  esac
  case "$out" in
    *"Still failing"*) return 0 ;;
    *) echo "no summary of failing stages was printed"; printf '%s\n' "$out" | tail -20; return 1 ;;
  esac
}

# 3. Without --keep-going the old halt must still be available, because a scripted
#    caller that wants to stop at the first failure has no other way to say so.
test_stop_on_fail_still_halts() {
  local out
  out="$(cd "$K" && timeout 120 bash ./install.sh --from 2 --yes --dry-run --no-prompt </dev/null 2>&1)"
  case "$out" in
    *"Stage 5"*) echo "install.sh carried on past a failure without --keep-going:"; printf '%s\n' "$out" | tail -20; return 1 ;;
    *) return 0 ;;
  esac
}

# 4. A stage whose gate already passes must be skipped, not re-run. This is what
#    makes a second ./setup.sh cheap, and what stops it re-downloading a 5GB model.
test_a_passing_gate_skips_its_stage() {
  local out
  # Stage 0's gate passes in the sandbox (node and python are present in CI), so the
  # driver should say so rather than walking the package installs again.
  out="$(cd "$K" && timeout 120 bash ./install.sh --yes --dry-run --keep-going --no-prompt </dev/null 2>&1)"
  case "$out" in
    *"already in place, skipping"*) return 0 ;;
    *) echo "no stage was reported as already in place:"; printf '%s\n' "$out" | head -30; return 1 ;;
  esac
}

printf '\n%sRegressions%s\n' "$B" "$N"
t "a nested run inherits the parent lock"    test_nested_run_inherits_lock
t "a child exit keeps the parent lock"       test_child_exit_keeps_parent_lock
t "unquote strips only quotes and spaces"    test_unquote_strips_only_quotes_and_spaces
t "routing reads a quoted model value"       test_routing_reads_a_quoted_model_value
t "an unattended setup never blocks"         test_unattended_setup_never_blocks
t "a failing stage does not end the run"     test_a_failing_stage_does_not_end_the_run
t "without --keep-going it still halts"      test_stop_on_fail_still_halts
t "a passing gate skips its stage"           test_a_passing_gate_skips_its_stage

printf '\n%s================================%s\n' "$B" "$N"
printf '%s%s passed%s' "$G" "$PASS" "$N"
[ "$FAIL" -gt 0 ] && printf ', %s%s FAILED%s' "$R" "$FAIL" "$N"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '%sFailed:%s%s\n' "$R" "$N" "$FAILED_NAMES"
  printf '\nRe-run with --verbose to see why.\n'
  exit 1
fi
exit 0
