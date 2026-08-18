#!/usr/bin/env bash
# setup.sh - the whole thing, one command, in dependency order.
#
#   ./setup.sh              full guided setup
#   ./setup.sh --minimal    spine only, no optional tabs
#   ./setup.sh --dry-run    show every step, change nothing
#   ./setup.sh --yes        assume yes to safe prompts (still stops for keys and logins)
#
# Runs, in order:
#   1  preflight        where you currently stand
#   2  install stage 0  base packages: node, python, curl, git, lsof, age
#   3  vault init       encrypted key store
#   4  install 1-5      dashboard, memory bus, local brain, routing, executor
#   5  keys            guided, one at a time, stored encrypted and validated live
#   6  tabs             the recommended optional set
#   7  audit            confirm nothing is left in the clear
#
# Safe to re-run. Every step is idempotent and skips what already passes.
# Never enters card details, never logs in on your behalf.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MINIMAL=0; PASS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --minimal) MINIMAL=1; shift ;;
    --dry-run) PASS="$PASS --dry-run"; shift ;;
    --yes|-y)  PASS="$PASS --yes"; shift ;;
    --app-dir) PASS="$PASS --app-dir $2"; shift 2 ;;
    --port)    PASS="$PASS --port $2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

detect_platform
acquire_lock
cd "$SCRIPT_DIR" || exit 1
chmod +x ./*.sh 2>/dev/null || true

banner() {
  printf '\n%s%s%s\n' "$C_B" "================================================================" "$C_RST"
  printf '%s  %s%s\n' "$C_B" "$*" "$C_RST"
  printf '%s%s%s\n' "$C_B" "================================================================" "$C_RST"
}

step() { # step <n> <label> <command...>
  banner "$1/7  $2"
  shift 2
  "$@"
  return $?
}

pause() {
  case "$PASS" in *--yes*|*--dry-run*) return 0 ;; esac
  printf '\n%sPress return to continue, or Ctrl-C to stop here. %s' "$C_YEL" "$C_RST"
  read -r _
}

say "Agent OS complete setup"
dim "platform: $PLATFORM/$ARCH   package manager: $PKG"
say ""
say "This runs the full install in dependency order. It is safe to re-run and will"
say "skip anything already working. It stops and asks whenever a key or a login is"
say "needed, and it never enters card details or logs in for you."
pause

# ---------------------------------------------------------------- 1
step 1 "Preflight, where you currently stand" ./preflight.sh || true
pause

# ---------------------------------------------------------------- 2
banner "2/7  Base packages"
say "node, python3, curl, git, lsof, and age (the vault backend)."
# shellcheck disable=SC2086
./install.sh --stage 0 $PASS || { bad "Base packages failed. Fix the item above and re-run."; exit 1; }

# ---------------------------------------------------------------- 3
banner "3/7  One place for your API keys"
if [ -f "$HOME/.agent-os-vault/backend" ]; then
  ok "Vault already initialised: $(cat "$HOME/.agent-os-vault/backend")"
else
  ./vault.sh --init || warn "Vault not initialised. Keys will fall back to a plaintext file."
fi
[ -f "$HOME/.agent-os-keys.env" ] && [ -f "$HOME/.agent-os-vault/backend" ] && \
  [ "$(cat "$HOME/.agent-os-vault/backend")" != plain ] && {
    say ""
    info "An existing plaintext key file was found."
    ./vault.sh --import || true
  }
pause

# ---------------------------------------------------------------- 4
banner "4/7  The spine, stages 1 to 5"
say "Dashboard, memory bus, free local brain, model routing, executor."
say "Each stage must pass its gate before the next begins."
# shellcheck disable=SC2086
if ! ./install.sh --from 1 $PASS; then
  say ""
  bad "A stage did not pass. Nothing beyond it was attempted."
  say "Fix the item shown above, then re-run ./setup.sh. It resumes where it stopped."
  exit 1
fi

# ---------------------------------------------------------------- 5
banner "5/7  Keys"
say "Guided, one key at a time. Each shows what it costs, what it unlocks, and where"
say "to get it, with [a]dd / [s]kip / [n]ever ask / [q]uit. Nothing is required."
say ""
dim "Every key is optional. Skipping one just leaves that tab quiet."
case "$PASS" in
  *--dry-run*) dim "(dry-run: skipping the interactive key wizard)" ;;
  *) ./keys.sh --setup || true ;;
esac
say ""
./keys.sh --status || true
pause

# ---------------------------------------------------------------- 6
banner "6/7  Optional tabs"
if [ "$MINIMAL" = 1 ]; then
  info "Skipped by --minimal"
  dim "Add them later with: ./tabs.sh --list"
else
  ./tabs.sh --list || true
  say ""
  case "$PASS" in
    *--yes*) ./tabs.sh --recommended --yes || true ;;
    *)
      printf '%sInstall the recommended set now? [y/N] %s' "$C_YEL" "$C_RST"; read -r a
      case "$a" in y|Y|yes|YES) ./tabs.sh --recommended || true ;;
        *) dim "Skipped. Add them any time with ./tabs.sh --add <id>" ;; esac ;;
  esac
fi

# ---------------------------------------------------------------- 7
banner "7/7  Security audit"
./vault.sh --audit || true

# ---------------------------------------------------------------- done
banner "Setup complete"
say ""
./preflight.sh >/dev/null 2>&1 && ok "All six spine gates pass." || warn "Some gates still fail. Run ./preflight.sh for detail."
say ""
say "Open the dashboard:   http://localhost:${PORT:-3737}   (Chrome, http not https)"
say ""
say "Day to day:"
say "  ./preflight.sh          re-verify, especially after a pack update"
say "  ./keys.sh --check       confirm keys are still valid and funded"
say "  ./vault.sh --audit      monthly, or before any handover"
say "  ./tabs.sh               what else is available"
say ""
dim "Read RUNBOOK.md for the mental model, SECURITY.md for the threat model."
dim "Pick four tabs and ignore the rest."
