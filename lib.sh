#!/usr/bin/env bash
# lib.sh - shared functions for the Agent OS staged installer.
# Sourced by preflight.sh and install.sh. Not meant to be run directly.
# Targets bash 3.2 (macOS default), so no associative arrays or mapfile.

set -uo pipefail

# ---------- output ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RST=""; C_DIM=""; C_B=""; C_GRN=""; C_RED=""; C_YEL=""; C_BLU=""
fi

say()  { printf '%s\n' "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
ok()   { printf '%s  PASS%s  %s\n' "$C_GRN" "$C_RST" "$*"; }
bad()  { printf '%s  FAIL%s  %s\n' "$C_RED" "$C_RST" "$*"; }
warn() { printf '%s  WARN%s  %s\n' "$C_YEL" "$C_RST" "$*"; }
info() { printf '%s  ..  %s%s\n' "$C_DIM" "$*" "$C_RST"; }
hdr()  { printf '\n%s%s%s\n' "$C_B" "$*" "$C_RST"; }
fix()  { printf '        %sfix:%s %s\n' "$C_BLU" "$C_RST" "$*"; }

die()  { bad "$*"; exit 1; }

# ---------- platform ----------
detect_platform() {
  case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)
      if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        PLATFORM=wsl
      else
        PLATFORM=linux
      fi ;;
    *) PLATFORM=unsupported ;;
  esac
  ARCH="$(uname -m)"
  if have brew;    then PKG=brew
  elif have apt-get; then PKG=apt
  elif have dnf;   then PKG=dnf
  else PKG=none; fi
  export PLATFORM ARCH PKG
}

have() { command -v "$1" >/dev/null 2>&1; }

pkg_install_hint() {
  case "$PKG" in
    brew) echo "brew install $1" ;;
    apt)  echo "sudo apt-get install -y $1" ;;
    dnf)  echo "sudo dnf install -y $1" ;;
    *)    echo "install $1 using your package manager" ;;
  esac
}

total_ram_gb() {
  if [ "$PLATFORM" = macos ]; then
    echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  else
    awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0
  fi
}

# ver_ge "20.19.5" "20" -> 0 if first >= second
ver_ge() {
  local a b
  a="$(printf '%s' "$1" | tr -d 'v' | cut -d. -f1)"
  b="$(printf '%s' "$2" | tr -d 'v' | cut -d. -f1)"
  [ "${a:-0}" -ge "${b:-0}" ] 2>/dev/null
}

ver_ge_minor() { # ver_ge_minor 3.9.6 3 10  -> false
  local maj min
  maj="$(printf '%s' "$1" | cut -d. -f1)"
  min="$(printf '%s' "$1" | cut -d. -f2)"
  [ "${maj:-0}" -gt "$2" ] && return 0
  [ "${maj:-0}" -eq "$2" ] && [ "${min:-0}" -ge "$3" ] && return 0
  return 1
}

# ---------- version ----------
# Sourced before the caller parses arguments, and a sourced script sees the caller's "$@",
# so --version works everywhere without editing every argument loop.
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_VERSION="$(cat "$KIT_DIR/VERSION" 2>/dev/null || echo unknown)"
for __a in "$@"; do
  if [ "$__a" = "--version" ]; then
    printf 'agent-os-plus %s\n' "$KIT_VERSION"
    printf '%s\n' "$(basename "${0:-lib.sh}")"
    exit 0
  fi
done
unset __a

# ---------- misplacement guard ----------
# The pack root has its own README.md, CHANGELOG.md and VERSION. If this toolkit's loose
# files are copied there, all three are overwritten. Detect it and stop, rather than
# running from a state that has already damaged the pack.
check_not_misplaced() {
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -d "$d/source" ] && [ -d "$d/install" ] && [ -f "$d/setup.sh" ]; then
    cat >&2 <<'MISPLACED'

  MISPLACED INSTALL

This toolkit has been copied directly into the Agent OS pack folder.
The pack has its own README.md, CHANGELOG.md and VERSION, so those three
have been overwritten. Nothing else of the pack is affected.

1. Restore the three pack files from your pack zip:

     unzip -o -j <your-pack>.zip 'agent-os/README.md' 'agent-os/CHANGELOG.md' 'agent-os/VERSION' -d .

2. Move this toolkit into its own subfolder:

     mkdir -p agent-os-plus
     mv setup.sh preflight.sh install.sh keys.sh vault.sh tabs.sh update.sh \
        healthcheck.sh schedule.sh uninstall.sh test.sh lib.sh bootstrap.ps1 \
        keys.json tabs.json routing.json LICENSE CONTRIBUTING.md KEYS.md \
        RUNBOOK.md SECURITY.md agent-os-plus/ 2>/dev/null
     cd agent-os-plus && ./setup.sh

Easier next time: use the drop-in zip, or clone the repo into agent-os-plus/.
Both land in their own folder and cannot collide with anything.

MISPLACED
    exit 1
  fi
}
check_not_misplaced

# ---------- state ----------
STATE_DIR="$HOME/.agent-os-install"
STATE_FILE="$STATE_DIR/state"
LOCK_DIR="$STATE_DIR/lock"

# ---------- lock ----------
# Is this pid a process that is genuinely still working?
#
# NOT kill -0. That succeeds on a ZOMBIE: a process that has already exited but whose
# parent has not reaped it yet. A run killed with kill -9 usually leaves one behind for
# a while, so kill -0 reported the owner as alive and the lock could never be reaped.
# You got "Waiting for another run to finish" forever, for a process that was dead.
# ps reports the state letter, and Z means dead.
pid_alive() {
  local st
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$st" ] || return 1            # no such process
  case "$st" in Z*) return 1 ;; esac  # zombie: exited, not yet reaped
  return 0
}

# Age of a path in seconds. Portable across GNU and BSD stat.
path_age_secs() {
  local m now
  m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
  now="$(date +%s)"
  echo $(( now - m ))
}

# mkdir is atomic, so it works as a lock without flock (which macOS lacks).
acquire_lock() {
  mkdir -p "$STATE_DIR"

  # setup.sh takes the lock and then calls install.sh, keys.sh and tabs.sh, which each
  # try to take it too. Without this a run deadlocks against its own parent. The owning
  # process exports its pid, children see it and skip straight through.
  if [ -n "${AOS_LOCK_OWNER:-}" ] && [ "${AOS_LOCK_OWNER}" = "$(cat "$LOCK_DIR/pid" 2>/dev/null)" ]; then
    return 0
  fi

  local tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    local owner age
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo '')"
    age="$(path_age_secs "$LOCK_DIR" 2>/dev/null || echo 0)"

    # No pid file: a run died between taking the lock and writing its pid. Give it a
    # few seconds to be sure, then clear it.
    if [ -z "$owner" ] && [ "${age:-0}" -gt 20 ]; then
      rm -rf "$LOCK_DIR"; continue
    fi

    # The owner is gone or is a zombie. Nothing is running, so take the lock.
    if [ -n "$owner" ] && ! pid_alive "$owner"; then
      rm -rf "$LOCK_DIR"; continue
    fi

    # Backstop: a run that has held the lock for six hours is not coming back.
    if [ "${age:-0}" -gt 21600 ]; then
      warn "Clearing a lock held since $(( age / 3600 ))h ago by pid $owner."
      rm -rf "$LOCK_DIR"; continue
    fi

    tries=$((tries+1))
    if [ "$tries" -gt 3 ]; then
      bad "Another agent-os-plus command is running (pid $owner)."
      say "Wait for it to finish, or clear it with: rm -rf '$LOCK_DIR'"
      exit 1
    fi
    info "Waiting for another run to finish (pid $owner)"
    sleep 2
  done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  # $$ is exported so separate child processes (install.sh, keys.sh) skip acquiring.
  # BASHPID is NOT exported and differs inside ( ) subshells, so only the exact shell
  # that took the lock can release it. install.sh runs builds inside subshells, and
  # without this one of those exiting would unlock a run still in progress.
  AOS_LOCK_OWNER="$$"; export AOS_LOCK_OWNER
  AOS_LOCK_SHELL="${BASHPID:-$$}"
  trap 'release_lock' EXIT INT TERM
}
release_lock() {
  # Only the exact shell that took the lock may release it. A child process or a ( )
  # subshell exiting must leave a run in progress alone.
  [ "${AOS_LOCK_OWNER:-}" = "$$" ] || return 0
  [ "${AOS_LOCK_SHELL:-}" = "${BASHPID:-$$}" ] || return 0
  rm -rf "$LOCK_DIR" 2>/dev/null
}

# ---------- expected-absent stages ----------
# A stage you deliberately skipped should not report as breakage forever, or the daily
# health check cries wolf every morning and you stop reading it.
EXPECTED_FILE="$STATE_DIR/expected-absent"
is_expected_absent() { [ -f "$EXPECTED_FILE" ] && grep -qx "$1" "$EXPECTED_FILE" 2>/dev/null; }
mark_expected_absent() {
  mkdir -p "$STATE_DIR"
  is_expected_absent "$1" || printf '%s\n' "$1" >> "$EXPECTED_FILE"
}
unmark_expected_absent() {
  [ -f "$EXPECTED_FILE" ] || return 0
  grep -vx "$1" "$EXPECTED_FILE" > "$EXPECTED_FILE.tmp" 2>/dev/null || true
  mv "$EXPECTED_FILE.tmp" "$EXPECTED_FILE"
}

state_set() { # state_set stage_1 pass
  mkdir -p "$STATE_DIR"
  touch "$STATE_FILE"
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}
state_get() {
  [ -f "$STATE_FILE" ] || { echo ""; return; }
  grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# ---------- config.json helpers (node is a hard prerequisite anyway) ----------
CONFIG_JSON="$HOME/.agentic-os/config.json"

cfg_get() { # cfg_get vaultRoot
  have node || { echo ""; return; }
  node -e '
    const fs=require("fs");
    const f=process.argv[1], k=process.argv[2];
    try { const d=JSON.parse(fs.readFileSync(f,"utf8")||"{}"); process.stdout.write(String(d[k]??"")); }
    catch(e){ process.stdout.write(""); }
  ' "$CONFIG_JSON" "$1" 2>/dev/null
}

cfg_set() { # cfg_set vaultRoot "/path"
  have node || die "node is required to write config.json"
  mkdir -p "$(dirname "$CONFIG_JSON")"
  node -e '
    const fs=require("fs");
    const f=process.argv[1], k=process.argv[2], v=process.argv[3];
    let d={};
    try { if (fs.existsSync(f)) d=JSON.parse(fs.readFileSync(f,"utf8")||"{}"); } catch(e){ d={}; }
    d[k]=v;
    fs.writeFileSync(f, JSON.stringify(d,null,2)+"\n");
  ' "$CONFIG_JSON" "$1" "$2"
}

secure_file() { [ -f "$1" ] && chmod 600 "$1" 2>/dev/null || true; }

# ---------- app directory ----------
find_app_dir() {
  if [ -n "${APP_DIR:-}" ] && [ -f "$APP_DIR/package.json" ]; then echo "$APP_DIR"; return; fi
  local here candidates c
  here="$(pwd)"
  candidates="
$here/source
$here/../source
$HOME/Agentic OS/agentic-os
$HOME/agent-os/source
$HOME/Desktop/agent-os/source
$HOME/Documents/agent-os/source
"
  printf '%s\n' "$candidates" | while IFS= read -r c; do
    [ -z "$c" ] && continue
    [ -f "$c/package.json" ] && { echo "$c"; return; }
  done
}

# Quote stripping with no backslash anywhere: a double quote needs no escape inside
# single quotes, and a single quote needs none inside double quotes. Written this way on
# purpose. The escaped-literal form is easy to mangle in transit into something that
# still parses but strips the wrong characters, which a syntax check cannot catch.
# test-regressions.sh asserts what this does, not what it says.
AOS_DQ='"'
AOS_SQ="'"
unquote() { tr -d "$AOS_DQ$AOS_SQ "; }

# ---------- gates ----------
# Each gate is read-only, re-runnable, and prints its own findings.
# Return 0 = pass, 1 = fail.

gate_prereqs() {
  local rc=0 nodev pyv pybin
  if have node; then
    nodev="$(node -v 2>/dev/null)"
    if ver_ge "$nodev" 20; then ok "Node $nodev"; else bad "Node $nodev is below v20"; fix "$(pkg_install_hint node)"; rc=1; fi
  else
    bad "Node not installed"; fix "$(pkg_install_hint node)"; rc=1
  fi

  have npm || { bad "npm not on PATH"; rc=1; }

  pybin="$(best_python)"
  if [ -n "$pybin" ]; then
    pyv="$("$pybin" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)"
    ok "Python $pyv at $pybin (Hermes-capable)"
  else
    pyv="$(python3 -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo none)"
    warn "No Python 3.10+ found (system python3 is $pyv). Blocks Hermes only."
    fix "$(pkg_install_hint python@3.12)"
  fi

  if [ "$PLATFORM" = unsupported ]; then bad "Unsupported OS"; rc=1; fi
  return $rc
}

best_python() { # echo path to a python >= 3.10, else empty
  local c v
  for c in python3.13 python3.12 python3.11 python3.10 python3; do
    have "$c" || continue
    v="$("$c" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)" || continue
    if ver_ge_minor "$v" 3 10; then echo "$(command -v "$c")"; return; fi
  done
  echo ""
}

gate_dashboard() {
  local app
  app="$(find_app_dir)"
  if [ -z "$app" ]; then
    bad "Agent OS source folder not found"
    fix "run this from inside the unzipped agent-os folder, or pass --app-dir /path/to/agent-os/source"
    return 1
  fi
  ok "App found at $app"
  if curl -fsS --max-time 4 "http://localhost:${PORT:-3737}" >/dev/null 2>&1; then
    ok "Dashboard responding on http://localhost:${PORT:-3737}"
    return 0
  fi
  bad "Nothing responding on port ${PORT:-3737}"
  fix "cd '$app' && PORT=${PORT:-3737} npm start"
  return 1
}

gate_vault() {
  local v
  v="$(cfg_get vaultRoot)"
  if [ -n "$v" ] && [ -d "$v" ]; then
    ok "Vault connected: $v"
    [ -d "$v/.obsidian" ] || warn "No .obsidian folder there. Path may not be a real vault."
    return 0
  fi
  if [ -n "$v" ]; then bad "vaultRoot set to '$v' but that folder does not exist"
  else bad "No vaultRoot in $CONFIG_JSON"; fi
  fix "run ./install.sh --stage 2"
  return 1
}

gate_local_brain() {
  local rc=0
  if ! have ollama; then
    bad "Ollama not installed"; fix "https://ollama.com  (or $(pkg_install_hint ollama))"; return 1
  fi
  if ! curl -fsS --max-time 4 http://localhost:11434/api/tags >/dev/null 2>&1; then
    bad "Ollama not running"; fix "ollama serve  (or open the Ollama app)"; rc=1
  else
    ok "Ollama running on :11434"
  fi
  if [ -z "$(ollama list 2>/dev/null | tail -n +2 | head -1)" ]; then
    bad "No Ollama models pulled"; fix "ollama pull gemma2"; rc=1
  else
    ok "Models: $(ollama list 2>/dev/null | tail -n +2 | awk '{printf "%s ", $1}')"
  fi
  if [ -f "$HOME/.fcc/.env" ]; then
    ok "Agent Factory pointed at: $(grep -E '^MODEL=' "$HOME/.fcc/.env" | head -1 | cut -d= -f2- | unquote)"
  else
    bad "~/.fcc/.env missing"; fix "mkdir -p ~/.fcc && echo 'MODEL=ollama/gemma2' > ~/.fcc/.env"; rc=1
  fi
  return $rc
}

# --- routing gate: matches each job to the right class of model ---
# Patterns come from routing.json so that editing that file actually changes behaviour.
# Hardcoded values below are a fallback only, used if the file is missing or unreadable.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTING_JSON="$LIB_DIR/routing.json"

STEALTH_PAT='(-alpha|^sonoma|^owl-|-cloaked|stealth)'
SMALL_PAT='(gemma2|gemma-2|qwen2\.5-coder|phi3|llama3\.2|tinyllama)'

load_routing_patterns() {
  [ -f "$ROUTING_JSON" ] || return 0
  have node || return 0
  local sm st
  sm="$(node "$LIB_DIR/.routing-parse.js" "$ROUTING_JSON" small 2>/dev/null)"
  st="$(node "$LIB_DIR/.routing-parse.js" "$ROUTING_JSON" stealth 2>/dev/null)"
  [ -n "$sm" ] && SMALL_PAT="$sm"
  [ -n "$st" ] && STEALTH_PAT="$st"
}
load_routing_patterns

gate_routing() {
  local rc=0 fcc hcfg m
  fcc="$HOME/.fcc/.env"
  hcfg="$HOME/.hermes/profiles/main/config.yaml"

  # 1. Agent Factory / Free Claude Code
  if [ -f "$fcc" ]; then
    m="$(grep -E '^MODEL=' "$fcc" | head -1 | cut -d= -f2- | unquote)"
    if printf '%s' "$m" | grep -qiE "$STEALTH_PAT"; then
      bad "fcc MODEL '$m' looks like a stealth/alpha model. These are withdrawn without warning."
      fix "use a named :free model, or ollama/gemma2"
      rc=1
    elif printf '%s' "$m" | grep -q '^open_router/' && ! printf '%s' "$m" | grep -q ':free$'; then
      warn "fcc MODEL '$m' is an OpenRouter model without a :free suffix. This will bill you."
    else
      ok "Local build routing: $m"
    fi
  else
    warn "No ~/.fcc/.env, local building not routed yet"
  fi

  # 2. Hermes needs a model that can drive its tool loop
  if [ -f "$hcfg" ]; then
    m="$(grep -iE '^[[:space:]]*model:' "$hcfg" | head -1 | sed 's/.*: *//' | unquote)"
    if [ -z "$m" ]; then
      bad "No model set in $hcfg"; rc=1
    elif printf '%s' "$m" | grep -qiE "$SMALL_PAT|^ollama/"; then
      bad "Hermes is pointed at '$m'. Small local models are not built to drive the Hermes tool loop."
      fix "set an OpenRouter model in $hcfg, e.g. anthropic/claude-haiku-4.5"
      rc=1
    elif printf '%s' "$m" | grep -qiE "$STEALTH_PAT"; then
      bad "Hermes model '$m' is a stealth/alpha model"; rc=1
    else
      ok "Hermes routing: $m  (Jarvis inherits this)"
    fi
  else
    warn "No Hermes profile config yet. Hermes, Jarvis, Loop and Mastermind stay offline."
  fi

  # 3. The Claude tab and API keys
  local app envl
  app="$(find_app_dir)"
  for envl in "$app/.env.local" "$app/.env"; do
    [ -f "$envl" ] || continue
    if grep -qE '^ANTHROPIC_API_KEY=[[:space:]]*$' "$envl" 2>/dev/null; then
      bad "Empty ANTHROPIC_API_KEY in $envl. This takes precedence over 'claude login', so the tab asks for a key."
      fix "./install.sh --fix-claude-tab"
      rc=1
    fi
  done
  if [ -z "${ANTHROPIC_API_KEY+x}" ]; then :; elif [ -z "$ANTHROPIC_API_KEY" ]; then
    bad "ANTHROPIC_API_KEY is exported but empty in this shell. Same effect."
    fix "unset ANTHROPIC_API_KEY  (and remove it from your shell profile)"
    rc=1
  fi

  # 4. Global default sanity
  if [ -n "${AGENTIC_OS_CLAUDE_MODEL:-}" ] && printf '%s' "$AGENTIC_OS_CLAUDE_MODEL" | grep -qiE "$SMALL_PAT"; then
    bad "AGENTIC_OS_CLAUDE_MODEL is a small local model. Keep those to the on-device builder."
    rc=1
  fi

  return $rc
}

gate_executor() {
  local rc=0 env
  if have claude; then ok "Claude CLI present (needs 'claude login', never an API key)"
  else warn "Claude CLI not on PATH"; fi

  if ! have hermes; then
    warn "Hermes not installed. Optional, but Jarvis, Loop, Radar and Mastermind depend on it."
    fix "./install.sh --stage 5"
    return 1
  fi
  ok "Hermes at $(command -v hermes)"

  env="$HOME/.hermes/profiles/main/.env"
  if [ ! -f "$env" ]; then
    bad "No $env"; fix "./install.sh --stage 5"; rc=1
  elif ! grep -qE '^OPENROUTER_API_KEY=.+' "$env"; then
    bad "OPENROUTER_API_KEY missing from $env"
    fix "get one at https://openrouter.ai/keys then re-run ./install.sh --stage 5"
    rc=1
  else
    ok "OpenRouter key present"
    grep -qE '^ELEVENLABS_API_KEY=.+' "$env" && ok "ElevenLabs key present (Jarvis can speak)" \
      || info "No ElevenLabs key. Jarvis listens but will not speak."
  fi
  return $rc
}

# ---------- interaction mode --------------------------------------------------
# AOS_NOPROMPT=1 means nobody is sitting in front of this. Every blocking prompt
# returns empty and every human checkpoint prints its instruction and moves on,
# instead of waiting forever on a read that will never be answered.
#
# It is opt-in. setup.sh sets it when you pass --no-keys, and when stdin is not a
# terminal (cron, CI, a pipe), so an unattended run cannot hang.
AOS_NOPROMPT="${AOS_NOPROMPT:-0}"

is_interactive() { [ "${AOS_NOPROMPT:-0}" != 1 ]; }

ask_line() { # ask_line "prompt: "  -> echoes the answer, empty when non-interactive
  local a=""
  if is_interactive; then
    printf '%s' "$1" >&2
    read -r a || a=""
  fi
  printf '%s' "$a"
}

# ---------- compact status rows ------------------------------------------------
# Two voices, on purpose.
#
#   ok/bad/warn/fix (above) are the DETAIL voice: preflight.sh uses them to explain
#   one thing thoroughly, with the command that fixes it.
#
#   the rows below are the OVERVIEW voice: one aligned line per thing, no fix lines,
#   no headers. setup.sh uses these so a normal run is a short list you can read at a
#   glance instead of several screens of other scripts talking.
#
# AOS_VERBOSE=1 turns the overview back into the detail, by letting child scripts
# print straight through instead of into a log.
AOS_VERBOSE="${AOS_VERBOSE:-0}"

_row() { # _row <mark> <colour> <label> [detail]
  printf '  %s%-4s%s  %-19s %s%s%s\n' "$2" "$1" "$C_RST" "$3" "$C_DIM" "${4:-}" "$C_RST"
}
row_ok()   { _row 'ok'   "$C_GRN" "$1" "${2:-}"; }
row_todo() { _row 'todo' "$C_YEL" "$1" "${2:-}"; }
row_fail() { _row 'fail' "$C_RED" "$1" "${2:-}"; }

# A row that is replaced in place once the work finishes, so a long install shows what
# it is doing without leaving a trail of half-finished lines behind. Non-terminal output
# (a pipe, a log, CI) gets both lines instead, because there is no cursor to move.
row_working() {
  if [ -t 1 ]; then
    printf '  %s..  %s  %-19s %s%s%s' "$C_DIM" "$C_RST" "$1" "$C_DIM" "${2:-}" "$C_RST"
  else
    _row '..' "$C_DIM" "$1" "${2:-}"
  fi
}
row_done() { # row_done ok|todo|fail <label> [detail]
  [ -t 1 ] && printf '\r\033[K'
  case "$1" in
    ok)   row_ok   "$2" "${3:-}" ;;
    todo) row_todo "$2" "${3:-}" ;;
    *)    row_fail "$2" "${3:-}" ;;
  esac
}
