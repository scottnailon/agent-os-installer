#!/usr/bin/env bash
# schedule.sh - put the health check (and optionally safe updates) on a schedule.
#
#   ./schedule.sh --status      what is currently scheduled
#   ./schedule.sh --install     daily health check at 07:00. Safe, read-only
#   ./schedule.sh --updates     ALSO add weekly safe updates on Sunday at 08:00
#   ./schedule.sh --remove      remove everything this script added
#   ./schedule.sh --time HH:MM  choose the hour (default 07:00)
#
# WHAT IS AND IS NOT AUTOMATED, and why
#
#   Daily health check       AUTOMATED. Read-only. Cannot break anything.
#   Weekly safe updates      OPT-IN. System packages and python libraries only.
#   The Agent OS app itself  NEVER AUTOMATED.
#
# The pack ships breaking changes weekly with no tests and no rollback of its own. An
# unattended update means some mornings you would sit down to a system that broke at 3am
# with no clue which of eight components did it. It also needs a manually downloaded zip,
# so it could not be fully automated regardless. Run it deliberately:
#
#   ./update.sh --pack --from /path/to/new/agent-os
#   ./update.sh --rollback        if it goes wrong
#
# Ollama models and Hermes are excluded from the automated set too, because re-pulling a
# model or bumping the agent can change behaviour, and you want to be watching when it does.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
detect_platform

MODE="status"; AT="07:00"; WITH_UPDATES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --install) MODE=install; shift ;;
    --updates) MODE=install; WITH_UPDATES=1; shift ;;
    --remove) MODE=remove; shift ;;
    --status) MODE=status; shift ;;
    --time) AT="${2:-07:00}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

TAG="# agent-os-plus"
# Recognise the pre-rename tag as well, so an existing schedule stays removable.
OLD_TAG="# agent-os-installer"
HC="$SCRIPT_DIR/healthcheck.sh"
UP="$SCRIPT_DIR/update.sh"

# Check what YOU typed before checking what the machine has. A typo in --time is your
# mistake to hear about, and hearing "crontab not found" instead sends you off
# installing cron only to be told the time was wrong anyway. It also made the
# out-of-range test fail on any machine without cron, which is most CI runners.
HH="${AT%%:*}"; MM="${AT##*:}"
case "$HH" in ''|*[!0-9]*) die "Bad --time '$AT'. Use HH:MM, e.g. 07:00" ;; esac
case "$MM" in ''|*[!0-9]*) die "Bad --time '$AT'. Use HH:MM, e.g. 07:00" ;; esac
HH="$((10#$HH))"; MM="$((10#$MM))"
[ "$HH" -ge 0 ] && [ "$HH" -le 23 ] || die "Hour must be 0-23, got $HH"
[ "$MM" -ge 0 ] && [ "$MM" -le 59 ] || die "Minute must be 0-59, got $MM"

have crontab || die "crontab not found. Install cron ($(pkg_install_hint cron)) or schedule these yourself."

current() { crontab -l 2>/dev/null || true; }
without_ours() { current | grep -v "$TAG" | grep -v "$OLD_TAG" || true; }

do_status() {
  hdr "Scheduled jobs"
  local ours; ours="$(current | grep -e "$TAG" -e "$OLD_TAG" || true)"
  if [ -z "$ours" ]; then
    info "Nothing scheduled by this installer."
    fix "./schedule.sh --install"
  else
    printf '%s\n' "$ours" | while IFS= read -r l; do ok "$l"; done
  fi
  say ""
  local log="$HOME/.agent-os-install/health.log"
  if [ -f "$log" ]; then
    ok "Log: $log  ($(wc -l < "$log" | tr -d ' ') lines)"
    dim "Last run: $(grep -E '^===== ' "$log" | tail -1)"
  else
    info "No health log yet. Run ./healthcheck.sh once to create it."
  fi
  local vault; vault="$(cfg_get vaultRoot 2>/dev/null)"
  [ -n "$vault" ] && [ -d "$vault/Agentic OS/Health" ] && \
    ok "Reports in vault: $(ls -1 "$vault/Agentic OS/Health" 2>/dev/null | wc -l | tr -d ' ') file(s)"
}

do_install() {
  hdr "Scheduling"
  [ -x "$HC" ] || chmod +x "$HC" 2>/dev/null
  [ -x "$HC" ] || die "healthcheck.sh is not executable"

  # cron runs with a minimal PATH, so set one explicitly.
  local pathline="PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
  [ "$PLATFORM" = macos ] && pathline="$pathline:/opt/homebrew/bin"

  # Hour 24 is not valid in cron, so wrap.
  local UPHH=$(( (HH + 1) % 24 ))
  local lines=""
  lines="$lines$pathline $TAG
"
  lines="$lines$MM $HH * * * $pathline; \"$HC\" --quiet </dev/null >/dev/null 2>&1 $TAG
"
  say "Daily health check at $(printf '%02d:%02d' "$HH" "$MM")."
  dim "  Read-only. Writes a dated report into your vault and to ~/.agent-os-install/health.log"

  if [ "$WITH_UPDATES" = 1 ]; then
    lines="$lines$MM $UPHH * * 0 $pathline; \"$UP\" --safe --yes </dev/null >>\"$HOME/.agent-os-install/update.log\" 2>&1 $TAG
"
    say ""
    say "Weekly safe updates on Sunday at $(printf '%02d:%02d' "$UPHH" "$MM")."
    dim "  System packages and python libraries only."
    warn "  The app, Ollama models and Hermes are NEVER auto-updated. Run those yourself."
  fi

  say ""
  printf '%sInstall these cron entries? [y/N] %s' "$C_YEL" "$C_RST"; read -r a
  case "$a" in y|Y|yes|YES) ;; *) info "Cancelled"; return 0 ;; esac

  { without_ours; printf '%s' "$lines"; } | crontab -
  ok "Scheduled"
  say ""
  do_status
  say ""
  dim "Test it right now without waiting:  ./healthcheck.sh"
}

do_remove() {
  hdr "Removing scheduled jobs"
  local ours; ours="$(current | grep -e "$TAG" -e "$OLD_TAG" || true)"
  [ -z "$ours" ] && { info "Nothing to remove."; return 0; }
  printf '%s\n' "$ours" | while IFS= read -r l; do say "  $l"; done
  say ""
  printf '%sRemove these? [y/N] %s' "$C_YEL" "$C_RST"; read -r a
  case "$a" in y|Y|yes|YES) ;; *) info "Cancelled"; return 0 ;; esac
  without_ours | crontab -
  ok "Removed. Logs and vault reports are left in place."
}

case "$MODE" in
  status) do_status ;; install) do_install ;; remove) do_remove ;;
esac
