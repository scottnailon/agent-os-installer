#!/usr/bin/env bash
# preflight.sh - read-only health check for an Agent OS install.
# Zero side effects. Safe to run at any time, including before anything is installed.
# Usage: ./preflight.sh [--app-dir /path/to/agent-os/source] [--port 3737]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PORT="${PORT:-3737}"
while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --expect)  mark_expected_absent "$2"; echo "Stage $2 marked as intentionally absent."; exit 0 ;;
    --unexpect) unmark_expected_absent "$2"; echo "Stage $2 will be reported as a failure again."; exit 0 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done
export PORT

detect_platform

printf '%s\n' "Agent OS preflight"
dim "platform: $PLATFORM/$ARCH   package manager: $PKG   ram: $(total_ram_gb)GB"

FAILED=""; EXPECTED=""
run_gate() { # run_gate <n> <label> <fn>
  hdr "Stage $1 - $2"
  if "$3"; then
    state_set "stage_$1" pass
    is_expected_absent "$1" && { info "(was marked intentionally absent, but now passes)"; unmark_expected_absent "$1"; }
  else
    state_set "stage_$1" fail
    if is_expected_absent "$1"; then
      info "Marked as intentionally absent, not counted as a failure."
      EXPECTED="$EXPECTED $1"
    else
      FAILED="$FAILED $1"
    fi
  fi
}

run_gate 0 "Prerequisites"          gate_prereqs
run_gate 1 "Dashboard"              gate_dashboard
run_gate 2 "Memory bus (vault)"     gate_vault
run_gate 3 "Free local brain"       gate_local_brain
run_gate 4 "Model routing"          gate_routing
run_gate 5 "Executor (Hermes)"      gate_executor

hdr "Summary"
[ -n "$EXPECTED" ] && dim "Intentionally absent, ignored:$EXPECTED   (undo with --unexpect N)"
if [ -z "$FAILED" ]; then
  ok "Every gate you care about passes. The system is wired correctly."
  dim "Optional extras (Thumbnails, OpenSEO, Video) are per-tab and not gated here."
  exit 0
fi

first="$(printf '%s' "$FAILED" | tr ' ' '\n' | grep -v '^$' | head -1)"
bad "Failing gates:$FAILED"
say ""
say "Stages are dependency-ordered. Fix the lowest number first, everything above it may"
say "be failing only as a consequence."
say ""
say "  ${C_B}./install.sh --from $first${C_RST}"
say ""
dim "install.sh is idempotent. It re-checks each gate and skips anything already passing."
dim "Deliberately skipping a stage? Mark it so it stops being reported:"
dim "  ./preflight.sh --expect $first"
exit 1
