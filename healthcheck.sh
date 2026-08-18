#!/usr/bin/env bash
# healthcheck.sh - non-interactive health report. Safe to run from cron.
#
#   ./healthcheck.sh              run and print the report
#   ./healthcheck.sh --quiet      write the report, print nothing (cron mode)
#   ./healthcheck.sh --no-vault   do not write into the Obsidian vault
#
# Writes a dated markdown report to:
#   <your vault>/Agentic OS/Health/YYYY-MM-DD.md     if a vault is connected
#   ~/.agent-os-install/health.log                   always
#
# Because the report lands in your vault, Jarvis and any agent reading the vault can
# answer "is anything wrong with the OS today" from real data.
#
# EXIT CODES  0 all good | 1 warnings | 2 something is broken
#
# Never prompts, never blocks, never changes anything. Read-only by design.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

QUIET=0; WRITE_VAULT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|-q) QUIET=1; shift ;;
    --no-vault) WRITE_VAULT=0; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

detect_platform
NO_COLOR=1  # reports are plain text
LOG="$HOME/.agent-os-install/health.log"
mkdir -p "$(dirname "$LOG")"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
STATUS=0
note() { printf '%s\n' "$*" >> "$TMP"; }
bump() { [ "$1" -gt "$STATUS" ] && STATUS="$1"; return 0; }

DATE="$(date '+%Y-%m-%d')"; TIME="$(date '+%H:%M')"

note "# Agent OS health, $DATE $TIME"
note ""
note "Automated check. Read-only, nothing was changed."
note ""

# ---------------------------------------------------------------- spine
note "## Spine"
note ""
note '```'
if SPINE="$("$SCRIPT_DIR/preflight.sh" 2>&1 </dev/null)"; then
  note "$SPINE"
  note '```'
  note ""
  note "All six gates pass."
else
  note "$SPINE"
  note '```'
  note ""
  note "**One or more gates are failing.** Fix the lowest-numbered one first, the rest may"
  note "be failing only as a consequence."
  bump 2
fi
note ""

# ---------------------------------------------------------------- keys
note "## Keys"
note ""
VB="none"; [ -f "$HOME/.agent-os-vault/backend" ] && VB="$(cat "$HOME/.agent-os-vault/backend")"
case "$VB" in
  age)
    # age asks for a passphrase on every read, so it cannot be validated unattended.
    note "Vault backend is \`age\`, which needs a passphrase on each read, so keys cannot be"
    note "validated from an unattended run. Check them by hand now and then:"
    note ""
    note '```'
    note "./keys.sh --check"
    note '```'
    ;;
  none)
    note "No vault configured. Keys are plaintext or absent."
    note ""
    note "Fix with: \`./vault.sh --init\`"
    bump 1
    ;;
  *)
    note '```'
    if K="$("$SCRIPT_DIR/keys.sh" --check 2>&1 </dev/null)"; then
      note "$K"; note '```'; note ""; note "Every key with a validation endpoint responded."
    else
      note "$K"; note '```'; note ""
      note "**A key failed validation.** A 402 means the key is valid but out of credit."
      note "A 401 means it is wrong or revoked."
      bump 2
    fi
    ;;
esac
note ""

# ---------------------------------------------------------------- security
note "## Security"
note ""
note '```'
if A="$("$SCRIPT_DIR/vault.sh" --audit 2>&1 </dev/null)"; then
  note "$A"; note '```'; note ""; note "No plaintext exposure issues."
else
  note "$A"; note '```'; note ""
  note "**Plaintext exposure found.** Each item above has a fix line."
  bump 1
fi
note ""

# ---------------------------------------------------------------- components
note "## Installed components"
note ""
note '```'
note "$("$SCRIPT_DIR/update.sh" 2>&1 </dev/null | sed -n '/Installed components/,/^$/p')"
note '```'
note ""
note "Update everything with \`./update.sh --all\`. The app itself needs a downloaded pack:"
note "\`./update.sh --pack --from /path/to/new/agent-os\`"
note ""

# ---------------------------------------------------------------- disk
note "## Housekeeping"
note ""
BAKS="$(find "$HOME" -maxdepth 3 -name '*.bak-*' -type d 2>/dev/null | head -10)"
if [ -n "$BAKS" ]; then
  note "Old update backups taking up space:"
  note ""
  note '```'
  printf '%s\n' "$BAKS" | while IFS= read -r b; do
    note "$(du -sh "$b" 2>/dev/null | awk '{print $1"\t"$2}')"
  done
  note '```'
  note ""
  note "Delete any you no longer need."
else
  note "No leftover update backups."
fi
note ""

case "$STATUS" in
  0) note "---"; note ""; note "**Result: all clear.**" ;;
  1) note "---"; note ""; note "**Result: warnings.** Nothing is broken, but see the items above." ;;
  2) note "---"; note ""; note "**Result: action needed.** Something in the spine or the keys is failing." ;;
esac

# ---------------------------------------------------------------- output
{ printf '\n===== %s %s (exit %s) =====\n' "$DATE" "$TIME" "$STATUS"; cat "$TMP"; } >> "$LOG"

if [ "$WRITE_VAULT" = 1 ]; then
  VAULT="$(cfg_get vaultRoot 2>/dev/null)"
  if [ -n "$VAULT" ] && [ -d "$VAULT" ]; then
    DEST="$VAULT/Agentic OS/Health"
    mkdir -p "$DEST" 2>/dev/null && cp "$TMP" "$DEST/$DATE.md" 2>/dev/null && \
      [ "$QUIET" = 0 ] && echo "Report written to $DEST/$DATE.md"
  fi
fi

[ "$QUIET" = 0 ] && cat "$TMP"
exit "$STATUS"
