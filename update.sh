#!/usr/bin/env bash
# update.sh - update the Agent OS pack and every open-source project behind its tabs.
#
#   ./update.sh                     read-only. What is installed, and what can be updated
#   ./update.sh --all               update everything, asking before each
#   ./update.sh --safe              only the low-risk components (cron-safe)
#   ./update.sh --only <id>         update one component
#   ./update.sh --pack --from DIR   update the Agent OS app from a newly downloaded pack
#   ./update.sh --rollback          restore the app from the most recent backup
#   ./update.sh --dry-run           show every action, change nothing
#   ./update.sh --yes               assume yes (still refuses anything destructive without a backup)
#
# COMPONENTS
#   pack          the Agent OS Next.js app itself
#   models        Ollama models
#   hermes        the Hermes agent
#   opencode      free terminal coding agent
#   omniroute     free multi-provider gateway
#   openseo       self-hosted SEO research (git + docker)
#   python-libs   Pillow, Google API client for the tabs that use them
#   system        ffmpeg, age, and other base packages
#
# WHAT IS ALWAYS PRESERVED across a pack update:
#   ~/.agentic-os/      dashboard settings, vault path, model routing
#   ~/.hermes/          profiles, keys, personas, sessions
#   ~/.fcc/.env         local model routing
#   ~/.agent-os-vault/  your encrypted keys
#   your Obsidian vault
#
# The pack replaces the entire app folder on every update, which is why a tweak made in
# the source files keeps reverting. Put customisations in ~/.agentic-os/config.json.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

detect_platform
acquire_lock
MODE="check"; ONLY=""; FROM=""; DRY=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all; shift ;;
    --safe) MODE=safe; shift ;;
    --only) MODE=only; ONLY="${2:-}"; shift 2 ;;
    --pack) MODE=only; ONLY=pack; shift ;;
    --from) FROM="${2:-}"; shift 2 ;;
    --rollback) MODE=rollback; shift ;;
    --dry-run) DRY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --app-dir) APP_DIR="$2"; export APP_DIR; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

run() { if [ "$DRY" = 1 ]; then dim "would run: $*"; else "$@"; fi; }
runsh() { if [ "$DRY" = 1 ]; then dim "would run: $1"; else bash -c "$1"; fi; }
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  printf '%s%s [y/N] %s' "$C_YEL" "$1" "$C_RST"; read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ================================================================ checks
c_pack() {
  local app bd
  app="$(find_app_dir)"
  [ -z "$app" ] && { info "pack          app folder not found"; return 1; }
  bd="$(node -e '
    try{const p=require(process.argv[1]+"/package.json");process.stdout.write(p.version||"unknown");}catch(e){process.stdout.write("unknown");}
  ' "$app" 2>/dev/null)"
  ok "pack          installed at $app (version $bd)"
  dim "              updates ship weekly. Download the newest pack, then:"
  dim "              ./update.sh --pack --from /path/to/new/agent-os"
}

c_models() {
  have ollama || { info "models        Ollama not installed"; return 1; }
  local list; list="$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | tr '\n' ' ')"
  [ -z "$list" ] && { info "models        Ollama installed, no models pulled"; return 1; }
  ok "models        $list"
}

c_hermes() {
  have hermes || { info "hermes        not installed"; return 1; }
  ok "hermes        $(hermes --version 2>/dev/null | head -1 || echo installed)"
}

c_opencode() { have opencode && ok "opencode      $(opencode --version 2>/dev/null | head -1 || echo installed)" || { info "opencode      not installed"; return 1; }; }
c_omniroute() { have omniroute && ok "omniroute     installed" || { info "omniroute     not installed"; return 1; }; }

c_openseo() {
  [ -d "$HOME/open-seo" ] || { info "openseo       not installed"; return 1; }
  local br; br="$(cd "$HOME/open-seo" && git rev-parse --short HEAD 2>/dev/null || echo "no git")"
  ok "openseo       ~/open-seo at $br"
}

c_python_libs() {
  local py; py="$(best_python)"; [ -z "$py" ] && py="$(command -v python3)"
  [ -z "$py" ] && { info "python-libs   no python found"; return 1; }
  local have_pil have_g
  "$py" -c 'import PIL' 2>/dev/null && have_pil="Pillow" || have_pil=""
  "$py" -c 'import googleapiclient' 2>/dev/null && have_g="google-api-client" || have_g=""
  if [ -z "$have_pil$have_g" ]; then info "python-libs   none installed"; return 1; fi
  ok "python-libs   $have_pil $have_g"
}

c_system() {
  local s=""
  for c in ffmpeg age node npm docker; do have "$c" && s="$s $c"; done
  ok "system       $s"
}

# ================================================================ updates
u_pack() {
  local app new
  app="$(find_app_dir)"
  [ -z "$app" ] && { bad "Cannot find the installed app folder"; return 1; }

  if [ -z "$FROM" ]; then
    say "Download the newest pack from the AGENT OS System! lesson and unzip it, then:"
    say "  ${C_B}./update.sh --pack --from /path/to/new/agent-os${C_RST}"
    say ""
    dim "The path is the folder containing 'source/', not the zip and not the source folder itself."
    return 1
  fi
  FROM="${FROM/#\~/$HOME}"
  new="$FROM/source"
  [ -d "$new" ] || new="$FROM"
  [ -f "$new/package.json" ] || { bad "No package.json under $new. Point --from at the unzipped agent-os folder."; return 1; }

  hdr "Updating the app"
  say "  from: $new"
  say "  to:   $app"
  say ""
  say "Preserved: ~/.agentic-os, ~/.hermes, ~/.fcc, ~/.agent-os-vault, your vault,"
  say "and any .env files inside the app folder."
  confirm "Proceed?" || return 1

  # stop the running dashboard if we started it
  if [ -f "$STATE_DIR/dashboard.pid" ]; then
    local pid; pid="$(cat "$STATE_DIR/dashboard.pid")"
    if kill -0 "$pid" 2>/dev/null; then
      info "Stopping the running dashboard (pid $pid)"
      run kill "$pid" 2>/dev/null || true
      sleep 2
    fi
  fi

  mkdir -p "$STATE_DIR"
  local bak="$app.bak-$(date +%Y%m%d_%H%M%S)"
  info "Backing up to $bak"
  run cp -r "$app" "$bak" || { bad "Backup failed. Nothing changed."; return 1; }
  [ "$DRY" != 1 ] && printf '%s\n' "$bak" > "$STATE_DIR/last-backup"

  info "Syncing new source"
  if have rsync; then
    runsh "rsync -a --delete \
      --exclude node_modules --exclude .next --exclude .git \
      --exclude '.env' --exclude '.env.*' --exclude 'agentic-os.config.json' \
      '$new/' '$app/'"
  else
    # Fallback with no rsync: preserve the excluded paths, replace everything else.
    warn "rsync not found, using a tar-based fallback"
    dim "  ($(pkg_install_hint rsync) is faster and safer if you update often)"
    local keep; keep="$(mktemp -d)"
    local f
    for f in node_modules .next .git agentic-os.config.json; do
      [ -e "$app/$f" ] && run cp -r "$app/$f" "$keep/" 2>/dev/null
    done
    if [ "$DRY" != 1 ]; then
      find "$app" -maxdepth 1 -name '.env*' -exec cp {} "$keep/" \; 2>/dev/null || true
      find "$app" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
      ( cd "$new" && tar cf - . ) | ( cd "$app" && tar xf - ) || { bad "Copy failed"; return 1; }
      cp -r "$keep"/. "$app"/ 2>/dev/null || true
      rm -rf "$keep"
    fi
  fi

  info "Reinstalling and rebuilding (2 to 5 minutes)"
  runsh "cd '$app' && npm install && PORT=${PORT:-3737} npm run build" || {
    bad "Build failed after the update."
    say "Roll back with:  ${C_B}./update.sh --rollback${C_RST}"
    return 1
  }

  ok "App updated"
  say ""
  warn "Updates move things. Re-verify before you trust it:"
  say "  ./preflight.sh"
  say "  ./keys.sh --check"
  say ""
  dim "Backup kept at $bak. Delete it once you are happy."
  copy_docs_to_vault
}

u_models() {
  have ollama || { info "Ollama not installed, skipping"; return 0; }
  local m
  for m in $(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}'); do
    confirm "Re-pull $m?" && run ollama pull "$m"
  done
}

u_hermes() {
  have hermes || { info "Hermes not installed, skipping"; return 0; }
  if have pipx && pipx list 2>/dev/null | grep -q hermes; then
    confirm "Upgrade hermes-agent via pipx?" && run pipx upgrade hermes-agent
  elif [ -x "$STATE_DIR/hermes-venv/bin/pip" ]; then
    confirm "Upgrade hermes-agent in its venv?" && runsh "'$STATE_DIR/hermes-venv/bin/pip' install --upgrade hermes-agent"
  else
    local py; py="$(best_python)"; [ -z "$py" ] && py="$(command -v python3)"
    confirm "Upgrade hermes-agent via pip --user?" && run "$py" -m pip install --user --upgrade hermes-agent
  fi
  say ""
  warn "After upgrading, confirm your profile model is still set correctly:"
  dim "  ./preflight.sh    (stage 4 checks routing)"
}

u_opencode() {
  have opencode || { info "opencode not installed, skipping"; return 0; }
  confirm "Re-run the opencode installer to get the latest?" && \
    runsh 'curl -fsSL https://opencode.ai/install | bash'
}

u_omniroute() {
  have omniroute || { info "omniroute not installed, skipping"; return 0; }
  confirm "npm update -g omniroute?" && run npm update -g omniroute
}

u_openseo() {
  [ -d "$HOME/open-seo" ] || { info "OpenSEO not installed, skipping"; return 0; }
  have docker || { bad "Docker not found"; return 1; }
  confirm "git pull and rebuild the OpenSEO containers?" || return 0
  runsh "cd '$HOME/open-seo' && git pull --ff-only"
  runsh "cd '$HOME/open-seo' && docker compose pull && docker compose up -d"
  dim "Your DataForSEO credentials in ~/open-seo/.env are untouched."
}

u_python_libs() {
  local py; py="$(best_python)"; [ -z "$py" ] && py="$(command -v python3)"
  [ -z "$py" ] && { info "No python found, skipping"; return 0; }
  local pkgs=""
  "$py" -c 'import PIL' 2>/dev/null && pkgs="$pkgs Pillow"
  "$py" -c 'import googleapiclient' 2>/dev/null && pkgs="$pkgs google-api-python-client google-auth-oauthlib"
  [ -z "$pkgs" ] && { info "No relevant python libs installed, skipping"; return 0; }
  # shellcheck disable=SC2086
  confirm "Upgrade$pkgs?" && run "$py" -m pip install --user --upgrade $pkgs
}

u_system() {
  case "$PKG" in
    apt)  confirm "apt update and upgrade ffmpeg, age, curl, git, lsof?" && \
          runsh "sudo apt-get update -qq && sudo apt-get install -y --only-upgrade ffmpeg age curl git lsof" ;;
    dnf)  confirm "dnf upgrade ffmpeg, age, curl, git, lsof?" && \
          run sudo dnf upgrade -y ffmpeg age curl git lsof ;;
    brew) confirm "brew upgrade ffmpeg, age?" && run brew upgrade ffmpeg age ;;
    *)    info "No supported package manager, skipping system packages" ;;
  esac
}

# The pro tip from the pack's own docs: keep the install guides inside your vault so your
# agents can read the real setup steps as context when troubleshooting.
copy_docs_to_vault() {
  local vault app
  vault="$(cfg_get vaultRoot)"
  [ -z "$vault" ] || [ ! -d "$vault" ] && return 0
  app="$(find_app_dir)"
  local guides="${app%/source}/install"
  [ -d "$guides" ] || return 0
  local dest="$vault/Agent OS/Install"
  confirm "Refresh the install guides in your vault at $dest?" || return 0
  run mkdir -p "$dest"
  runsh "cp '$guides'/*.md '$dest'/ 2>/dev/null || true"
  runsh "cp '$SCRIPT_DIR'/RUNBOOK.md '$SCRIPT_DIR'/routing.json '$dest'/ 2>/dev/null || true"
  ok "Guides refreshed in your vault. Your agents can now read the real setup steps."
}

# ================================================================ rollback
do_rollback() {
  hdr "Rollback"
  local bak app
  [ -f "$STATE_DIR/last-backup" ] || { bad "No recorded backup"; return 1; }
  bak="$(cat "$STATE_DIR/last-backup")"
  [ -d "$bak" ] || { bad "Backup folder is gone: $bak"; return 1; }
  app="$(find_app_dir)"
  [ -z "$app" ] && { bad "Cannot find the app folder"; return 1; }

  say "Restore:  $bak"
  say "     to:  $app"
  warn "This discards the current app folder. Settings and keys are untouched."
  confirm "Proceed?" || return 1

  run rm -rf "$app.rollback-tmp"
  run mv "$app" "$app.rollback-tmp"
  run cp -r "$bak" "$app"
  runsh "cd '$app' && npm install && npm run build" || warn "Rebuild after rollback failed"
  ok "Rolled back"
  dim "The failed version is at $app.rollback-tmp. Delete it once you are happy."
}

# ================================================================ driver
COMPONENTS="pack models hermes opencode omniroute openseo python-libs system"

do_check() {
  hdr "Installed components"
  c_pack; c_models; c_hermes; c_opencode; c_omniroute; c_openseo; c_python_libs; c_system
  say ""
  hdr "How to update"
  say "  ./update.sh --all                     everything, asking before each"
  say "  ./update.sh --only models             just one component"
  say "  ./update.sh --pack --from DIR         the Agent OS app, from a new pack"
  say "  ./update.sh --rollback                undo the last pack update"
  say ""
  dim "Components: $COMPONENTS"
  say ""
  warn "After ANY update, re-verify. Updates move things."
  dim "  ./preflight.sh      six spine gates, including model routing"
  dim "  ./keys.sh --check   are the keys still valid and funded"
}

run_one() {
  case "$1" in
    pack) u_pack ;; models) u_models ;; hermes) u_hermes ;;
    opencode) u_opencode ;; omniroute) u_omniroute ;; openseo) u_openseo ;;
    python-libs) u_python_libs ;; system) u_system ;;
    docs) copy_docs_to_vault ;;
    *) bad "Unknown component: $1"; say "Valid: $COMPONENTS docs"; return 1 ;;
  esac
}

# Components safe to update unattended. Deliberately excludes the app, Ollama models and
# Hermes, because each of those can change behaviour and you want to be watching.
SAFE_COMPONENTS="system python-libs"

case "$MODE" in
  check) do_check ;;
  safe)
    hdr "Safe updates only"
    dim "System packages and python libraries. The app, models and Hermes are excluded."
    for c in $SAFE_COMPONENTS; do say ""; hdr "$c"; run_one "$c" || warn "$c did not complete"; done
    say ""
    hdr "Post-update verification"
    "$SCRIPT_DIR/preflight.sh" || warn "Some gates now fail."
    ;;
  rollback) do_rollback ;;
  only) hdr "Updating: $ONLY"; run_one "$ONLY" ;;
  all)
    hdr "Updating everything"
    dim "The app itself needs a downloaded pack, so it is skipped unless --from is given."
    for c in $COMPONENTS; do
      [ "$c" = pack ] && [ -z "$FROM" ] && { info "pack skipped (no --from)"; continue; }
      say ""; hdr "$c"; run_one "$c" || warn "$c did not complete"
    done
    say ""
    hdr "Post-update verification"
    "$SCRIPT_DIR/preflight.sh" || warn "Some gates now fail. See above."
    say ""
    "$SCRIPT_DIR/keys.sh" --check || true
    ;;
esac
