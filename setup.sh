#!/usr/bin/env bash
# setup.sh - one command. It finds what is missing, installs it, and moves on.
#
#   ./setup.sh                full run: install everything missing, keep going
#   ./setup.sh --minimal      spine only, no optional tabs
#   ./setup.sh --dry-run      show every step, change nothing
#   ./setup.sh --ask          confirm each install and pause between steps
#   ./setup.sh --stop-on-fail halt at the first failing gate instead of stepping over it
#   ./setup.sh --no-keys      skip the key wizard and every other prompt, unattended
#   ./setup.sh --no-tabs      same as --minimal
#
# What the default run does:
#   Anything already working is detected and left alone. Anything missing is
#   installed without stopping to ask. A step that fails is recorded and stepped
#   over rather than ending the run, so one broken thing no longer hides the rest.
#   You get a single summary at the end: what was already there, what got
#   installed, and what still needs you.
#
# Runs, in order:
#   1  preflight        where you currently stand
#   2  install stage 0  base packages: node, python, curl, git, lsof, age, rsync
#   3  vault init       encrypted key store
#   4  install 1-5      dashboard, memory bus, local brain, routing, executor
#   5  keys             guided, one at a time, stored encrypted and validated live
#   6  tabs             the recommended optional set
#   7  audit            confirm nothing is left in the clear
#
# Safe to re-run. Every step is idempotent and skips what already passes.
# It never enters card details, never logs in on your behalf, and never invents an
# API key. Those stay human steps, and with --no-keys or no terminal attached they
# are named and skipped rather than left blocking on a prompt nobody will answer.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MINIMAL=0; PASS=""; ASK=0; STOP_ON_FAIL=0; DO_KEYS=1; DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --minimal|--no-tabs) MINIMAL=1; shift ;;
    --dry-run) DRY=1; PASS="$PASS --dry-run"; shift ;;
    --ask|--interactive) ASK=1; shift ;;
    --stop-on-fail) STOP_ON_FAIL=1; shift ;;
    --no-keys) DO_KEYS=0; shift ;;
    --yes|-y)  shift ;;   # kept for compatibility, this is now the default
    --app-dir) PASS="$PASS --app-dir $2"; shift 2 ;;
    --port)    PASS="$PASS --port $2"; shift 2 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

# Nobody at the keyboard? Then no prompt can ever be answered, so do not raise one.
# --no-keys says the same thing on purpose: run it through without stopping for me.
if [ ! -t 0 ]; then AOS_NOPROMPT=1; DO_KEYS=0; fi
[ "$DO_KEYS" = 0 ] && AOS_NOPROMPT=1
export AOS_NOPROMPT

# The default is: say yes to anything safe, and step over what fails.
if [ "$ASK" = 0 ]; then
  PASS="$PASS --yes"
  TABS_FLAGS="--recommended --yes"
else
  TABS_FLAGS="--recommended"
fi
[ "$STOP_ON_FAIL" = 0 ] && PASS="$PASS --keep-going"
[ "${AOS_NOPROMPT:-0}" = 1 ] && { PASS="$PASS --no-prompt"; TABS_FLAGS="$TABS_FLAGS --no-prompt"; }

detect_platform
acquire_lock
cd "$SCRIPT_DIR" || exit 1
chmod +x ./*.sh 2>/dev/null || true

banner() {
  printf '\n%s%s%s\n' "$C_B" "================================================================" "$C_RST"
  printf '%s  %s%s\n' "$C_B" "$*" "$C_RST"
  printf '%s%s%s\n' "$C_B" "================================================================" "$C_RST"
}

# In --ask mode this is the old "press return between steps". By default it is a
# no-op, because the whole point of one command is that it does not need shepherding.
pause() {
  [ "$ASK" = 1 ] || return 0
  [ "$DRY" = 1 ] && return 0
  is_interactive || return 0
  printf '\n%sPress return to continue, or Ctrl-C to stop here. %s' "$C_YEL" "$C_RST"
  read -r _
}

PROBLEMS=""
note_problem() { PROBLEMS="$PROBLEMS
  - $1"; }

# Snapshot of the six gates before anything runs, so the summary can say what this
# run actually changed rather than just what is true now.
BEFORE_STATE=""
snapshot_before() {
  local n
  for n in 0 1 2 3 4 5; do
    BEFORE_STATE="$BEFORE_STATE $n:$(state_get "stage_$n")"
  done
}
was_passing() { case "$BEFORE_STATE" in *" $1:pass"*) return 0 ;; *) return 1 ;; esac; }

say "Agent OS complete setup"
dim "platform: $PLATFORM/$ARCH   package manager: $PKG"
say ""
if [ "$ASK" = 1 ]; then
  say "Guided mode: it confirms each install and pauses between steps."
else
  say "It checks what is already working, installs whatever is missing without"
  say "asking, and carries on past anything that fails so one problem cannot hide"
  say "the rest. A summary at the end lists anything still needing you."
fi
[ "${AOS_NOPROMPT:-0}" = 1 ] && dim "unattended: no prompts will be raised, human steps get named and skipped"
say ""
pause

# ---------------------------------------------------------------- 1
banner "1/7  Preflight, where you currently stand"
./preflight.sh || true
snapshot_before
pause

# ---------------------------------------------------------------- 2
banner "2/7  Base packages"
say "node, python3, curl, git, lsof, rsync, and age (the vault backend)."
# shellcheck disable=SC2086
if ! ./install.sh --stage 0 $PASS; then
  note_problem "Base packages incomplete. Run: ./install.sh --stage 0"
  if [ "$STOP_ON_FAIL" = 1 ]; then bad "Base packages failed."; exit 1; fi
  warn "Some base packages are still missing. Carrying on, later steps may fail."
fi

# ---------------------------------------------------------------- 3
banner "3/7  One place for your API keys"
if [ "$DRY" = 1 ]; then
  dim "(dry-run: not touching the vault)"
elif [ -f "$HOME/.agent-os-vault/backend" ]; then
  ok "Vault already initialised: $(cat "$HOME/.agent-os-vault/backend")"
else
  ./vault.sh --init || { warn "Vault not initialised. Keys will fall back to a plaintext file."; \
    note_problem "Vault not initialised. Run: ./vault.sh --init"; }
fi
[ "$DRY" != 1 ] && [ -f "$HOME/.agent-os-keys.env" ] && [ -f "$HOME/.agent-os-vault/backend" ] && \
  [ "$(cat "$HOME/.agent-os-vault/backend")" != plain ] && {
    say ""
    info "An existing plaintext key file was found."
    ./vault.sh --import || true
  }
pause

# ---------------------------------------------------------------- 4
banner "4/7  The spine, stages 1 to 5"
say "Dashboard, memory bus, free local brain, model routing, executor."
say "Anything already in place is skipped. Anything missing gets installed."
# shellcheck disable=SC2086
if ! ./install.sh --from 1 $PASS; then
  say ""
  if [ "$STOP_ON_FAIL" = 1 ]; then
    bad "A stage did not pass. Nothing beyond it was attempted."
    say "Fix the item shown above, then re-run ./setup.sh. It resumes where it stopped."
    exit 1
  fi
  warn "One or more stages did not pass. The rest of setup carried on regardless."
fi

# ---------------------------------------------------------------- 5
banner "5/7  Keys"
if [ "$DO_KEYS" = 0 ]; then
  info "Skipped. Nothing here can be guessed, and it needs you at the keyboard."
  dim "Add them any time with: ./keys.sh --setup"
elif [ "$DRY" = 1 ]; then
  dim "(dry-run: skipping the interactive key wizard)"
else
  say "Guided, one key at a time. Each shows what it costs, what it unlocks, and where"
  say "to get it, with [a]dd / [s]kip / [n]ever ask / [q]uit. Nothing is required."
  say ""
  dim "Every key is optional. Skipping one just leaves that tab quiet."
  ./keys.sh --setup || true
fi
say ""
./keys.sh --status || true
pause

# ---------------------------------------------------------------- 6
banner "6/7  Optional tabs"
if [ "$MINIMAL" = 1 ]; then
  info "Skipped by --minimal"
  dim "Add them later with: ./tabs.sh --list"
elif [ "$DRY" = 1 ]; then
  ./tabs.sh --list || true
  dim "(dry-run: not installing tabs)"
elif [ "$ASK" = 1 ]; then
  ./tabs.sh --list || true
  say ""
  printf '%sInstall the recommended set now? [y/N] %s' "$C_YEL" "$C_RST"; read -r a
  case "$a" in
    y|Y|yes|YES) ./tabs.sh $TABS_FLAGS || true ;;
    *) dim "Skipped. Add them any time with ./tabs.sh --add <id>" ;;
  esac
else
  say "Installing everything marked 'take' that is not already there."
  # shellcheck disable=SC2086
  ./tabs.sh $TABS_FLAGS || true
fi

# ---------------------------------------------------------------- 7
banner "7/7  Security audit"
./vault.sh --audit || true

# ---------------------------------------------------------------- done
banner "Setup complete"
say ""

CHANGED=""; STILL=""
for n in 0 1 2 3 4 5; do
  now="$(state_get "stage_$n")"
  if [ "$now" = pass ]; then
    was_passing "$n" || CHANGED="$CHANGED $n"
  else
    is_expected_absent "$n" || STILL="$STILL $n"
  fi
done

[ -n "$CHANGED" ] && ok "Installed this run, stages:$CHANGED"
[ -z "$CHANGED" ] && [ -z "$STILL" ] && ok "Everything was already in place. Nothing needed installing."

if [ -n "$STILL" ]; then
  warn "Still failing, stages:$STILL"
  first="$(printf '%s' "$STILL" | tr ' ' '\n' | grep -v '^$' | head -1)"
  say ""
  say "  ${C_B}./install.sh --from $first${C_RST}"
  dim "       fix the lowest number first, the rest may be failing only because of it"
  say "  ${C_B}./preflight.sh${C_RST}"
  dim "       see exactly what each gate is asking for"
  say "  ${C_B}./preflight.sh --expect $first${C_RST}"
  dim "       if you are skipping that stage on purpose, so it stops being reported"
else
  ok "All six spine gates pass."
fi

if [ -n "$PROBLEMS" ]; then
  say ""
  warn "Worth a look:"
  printf '%s\n' "$PROBLEMS"
fi

say ""
say "Open the dashboard:   http://localhost:${PORT:-3737}   (Chrome, http not https)"
say ""
say "Day to day:"
say "  ./setup.sh              re-run any time, it only installs what is missing"
say "  ./preflight.sh          re-verify, especially after a pack update"
say "  ./keys.sh --check       confirm keys are still valid and funded"
say "  ./vault.sh --audit      monthly, or before any handover"
say "  ./tabs.sh               what else is available"
say ""
dim "Read RUNBOOK.md for the mental model, SECURITY.md for the threat model."
dim "Pick four tabs and ignore the rest."

[ -n "$STILL" ] && exit 1
exit 0
