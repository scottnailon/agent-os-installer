#!/usr/bin/env bash
# install.sh - dependency-ordered, gate-enforced Agent OS installer.
#
# Six stages. Each ends in a gate that must pass before the next begins.
# Idempotent: re-running skips anything already passing.
# Resumable: state lives in ~/.agent-os-install/state
#
# Usage:
#   ./install.sh                    run all stages from the first failing one
#   ./install.sh --from 3           start at stage 3
#   ./install.sh --stage 4          run only stage 4
#   ./install.sh --dry-run          print what it would do, change nothing
#   ./install.sh --yes              assume yes to safe prompts (still stops for keys)
#   ./install.sh --no-hermes        skip stage 5 entirely
#   ./install.sh --fix-claude-tab   remove the empty ANTHROPIC_API_KEY trap and exit
#
# This script will never: enter a password, enter card details, perform a browser
# login on your behalf, or hand-code a replacement for a dashboard tab.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PORT="${PORT:-3737}"
ASSUME_YES=0; DRY=0; ONLY=""; FROM=""; SKIP_HERMES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from)    FROM="$2"; shift 2 ;;
    --stage)   ONLY="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; export APP_DIR; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --no-hermes) SKIP_HERMES=1; shift ;;
    --fix-claude-tab) FIX_CLAUDE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done
export PORT

detect_platform
acquire_lock
[ "$PLATFORM" = unsupported ] && die "Unsupported OS. On Windows, run bootstrap.ps1 first to set up WSL2."

run() { # run <cmd...>  - respects --dry-run
  if [ "$DRY" = 1 ]; then dim "would run: $*"; return 0; fi
  "$@"
}
runsh() { # runsh "shell string"
  if [ "$DRY" = 1 ]; then dim "would run: $1"; return 0; fi
  bash -c "$1"
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  printf '%s%s [y/N] %s' "$C_YEL" "$1" "$C_RST"
  read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# A human checkpoint the script must not automate.
checkpoint() { # checkpoint "what you must do" "how to verify"
  hdr "HUMAN STEP"
  say "  $1"
  [ -n "${2:-}" ] && dim "  verify: $2"
  [ "$DRY" = 1 ] && return 0
  printf '%sPress return when done, or Ctrl-C to stop. %s' "$C_YEL" "$C_RST"
  read -r _
}

# ---------------------------------------------------------------- fix helper
fix_claude_tab() {
  local app envl found=0
  app="$(find_app_dir)"
  for envl in "$app/.env.local" "$app/.env"; do
    [ -f "$envl" ] || continue
    if grep -qE '^ANTHROPIC_API_KEY=[[:space:]]*$' "$envl"; then
      found=1
      info "Removing empty ANTHROPIC_API_KEY from $envl"
      if [ "$DRY" != 1 ]; then
        cp "$envl" "$envl.bak-$(date +%Y%m%d_%H%M%S)"
        # grep -v exits 1 when it filters out every line, so do not chain on success here.
        grep -vE '^ANTHROPIC_API_KEY=[[:space:]]*$' "$envl" > "$envl.tmp" || true
        mv "$envl.tmp" "$envl"
      fi
      if grep -qE '^ANTHROPIC_API_KEY=[[:space:]]*$' "$envl" 2>/dev/null; then
        bad "Could not clear it from $envl. Edit the file by hand and delete that line."
      else
        ok "Cleared from $envl. Restart the dashboard, then run: claude login"
      fi
    fi
  done
  [ "$found" = 0 ] && ok "No empty ANTHROPIC_API_KEY found. Claude tab trap is clear."
}

if [ "${FIX_CLAUDE:-0}" = 1 ]; then fix_claude_tab; exit 0; fi

# ================================================================= STAGE 0
stage_0() {
  hdr "Stage 0 - Prerequisites"
  if ! have node || ! ver_ge "$(node -v 2>/dev/null || echo v0)" 20; then
    say "Node 20+ is required. The dashboard is a Next.js app."
    case "$PKG" in
      brew) confirm "Install Node via Homebrew?" && run brew install node ;;
      apt)  confirm "Install Node 20 via NodeSource?" && \
            runsh "curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs" ;;
      dnf)  confirm "Install Node via dnf?" && run sudo dnf install -y nodejs ;;
      *)    checkpoint "Install Node 20+ from https://nodejs.org" "node -v" ;;
    esac
  fi

  if [ -z "$(best_python)" ] && [ "$SKIP_HERMES" != 1 ]; then
    say ""
    warn "No Python 3.10+ found. This blocks Hermes (stage 5) and nothing else."
    case "$PKG" in
      brew) confirm "Install python@3.12 via Homebrew?" && run brew install python@3.12 ;;
      apt)  confirm "Install python3 + venv via apt?" && run sudo apt-get install -y python3 python3-venv python3-pip ;;
      dnf)  confirm "Install python3 via dnf?" && run sudo dnf install -y python3 python3-pip ;;
      *)    say "Install Python 3.10+ from https://python.org, or skip Hermes with --no-hermes" ;;
    esac
  fi

  # Base packages the rest of this toolkit relies on.
  #   curl  : every health check and installer
  #   git   : optional tab projects
  #   lsof  : port-in-use detection at stage 1
  #   age   : the encrypted vault backend on Linux and WSL
  #   rsync : safe in-place pack updates that preserve your config
  local missing=""
  for c in curl git lsof age rsync; do have "$c" || missing="$missing $c"; done
  if [ -n "$missing" ]; then
    say ""
    say "Missing base packages:$missing"
    case "$missing" in *age*) dim "age is the vault backend on Linux. Without it your keys stay plaintext." ;; esac
    case "$PKG" in
      apt) confirm "Install them via apt?" && { run sudo apt-get update -qq; run sudo apt-get install -y $missing; } ;;
      dnf) confirm "Install them via dnf?" && run sudo dnf install -y $missing ;;
      brew) confirm "Install them via Homebrew?" && run brew install $missing ;;
      *) say "Install these yourself:$missing" ;;
    esac
  fi
  for c in curl git lsof age rsync; do
    have "$c" && ok "$c" || warn "$c still missing"
  done

  gate_prereqs
}

# ================================================================= STAGE 1
stage_1() {
  hdr "Stage 1 - Dashboard"
  local app
  app="$(find_app_dir)"
  if [ -z "$app" ]; then
    bad "Cannot find the Agent OS source folder."
    say ""
    say "Download the newest pack from the AGENT OS System! lesson, unzip it somewhere"
    say "permanent (not inside the zip, not in Downloads), then run this script from"
    say "inside that folder, or pass --app-dir /path/to/agent-os/source"
    return 1
  fi
  ok "App at $app"

  if curl -fsS --max-time 4 "http://localhost:$PORT" >/dev/null 2>&1; then
    ok "Already running on :$PORT"
    gate_dashboard; return $?
  fi

  if command -v lsof >/dev/null 2>&1 && lsof -i ":$PORT" >/dev/null 2>&1; then
    bad "Port $PORT is in use by something else."
    fix "close it, or re-run with --port 3738"
    return 1
  fi

  if [ ! -d "$app/node_modules" ]; then
    info "First run: npm install (2 to 5 minutes)"
    ( cd "$app" && run npm install ) || { bad "npm install failed. Check 'node -v' is 20+ and try again."; return 1; }
  fi
  if [ ! -d "$app/.next" ]; then
    info "Building"
    ( cd "$app" && PORT="$PORT" run npm run build ) || { bad "Build failed."; return 1; }
  fi

  if [ "$DRY" = 1 ]; then dim "would start the dashboard and poll :$PORT"; return 0; fi

  info "Starting dashboard in the background (log: $STATE_DIR/dashboard.log)"
  mkdir -p "$STATE_DIR"
  ( cd "$app" && PORT="$PORT" nohup npm start >"$STATE_DIR/dashboard.log" 2>&1 & echo $! > "$STATE_DIR/dashboard.pid" )

  local i=0
  while [ $i -lt 60 ]; do
    curl -fsS --max-time 2 "http://localhost:$PORT" >/dev/null 2>&1 && break
    sleep 2; i=$((i+1))
  done
  gate_dashboard
}

# ================================================================= STAGE 2
stage_2() {
  hdr "Stage 2 - Memory bus (Obsidian vault)"
  say "This is the spine. Memory, Jarvis recall, Journal, Notebook and Pipeline all"
  say "read and write here, so they come alive once a vault is connected."
  say ""

  local v cand
  v="$(cfg_get vaultRoot)"
  if [ -n "$v" ] && [ -d "$v" ]; then ok "Already connected: $v"; gate_vault; return $?; fi

  for cand in "$HOME/Documents/Obsidian Vault" "$HOME/Obsidian Vault" "$HOME/Obsidian"; do
    if [ -d "$cand" ]; then
      info "Found vault at $cand"
      if confirm "Use this as the memory bus?"; then
        run cfg_set vaultRoot "$cand"; ok "Set vaultRoot"; gate_vault; return $?
      fi
    fi
  done

  info "Searching for .obsidian folders (this takes a moment)"
  if [ "$DRY" != 1 ]; then
    find "$HOME" -maxdepth 4 -name ".obsidian" -type d 2>/dev/null | head -5 | while IFS= read -r d; do
      say "  candidate: $(dirname "$d")"
    done
  fi

  say ""
  say "No vault auto-detected. Either:"
  say "  a) install Obsidian (free, https://obsidian.md), create a vault in Documents, re-run"
  say "  b) enter the full path to an existing vault now"
  [ "$DRY" = 1 ] && return 1
  printf 'Vault path (blank to skip): '
  read -r v
  [ -z "$v" ] && { warn "Skipped. Stages above will work, but memory-backed features will not."; return 1; }
  v="${v/#\~/$HOME}"
  [ -d "$v" ] || { bad "No such folder: $v"; return 1; }
  cfg_set vaultRoot "$v"
  ok "Set vaultRoot to $v"
  info "Restart the dashboard, then open the Memory tab. Your notes should render as a star map."
  gate_vault
}

# ================================================================= STAGE 3
stage_3() {
  hdr "Stage 3 - Free local brain (Ollama)"
  say "Costs nothing, runs entirely on this machine, and unlocks Agent Factory,"
  say "Game Studio and Agent Kanban."
  say ""

  if ! have ollama; then
    case "$PKG" in
      brew) confirm "Install Ollama via Homebrew?" && run brew install ollama ;;
      apt|dnf) confirm "Install Ollama via the official script?" && runsh "curl -fsSL https://ollama.com/install.sh | sh" ;;
      *) checkpoint "Install Ollama from https://ollama.com" "ollama --version" ;;
    esac
  fi
  have ollama || { bad "Ollama still not on PATH"; return 1; }

  if ! curl -fsS --max-time 4 http://localhost:11434/api/tags >/dev/null 2>&1; then
    info "Starting ollama serve in the background"
    [ "$DRY" != 1 ] && ( nohup ollama serve >"$STATE_DIR/ollama.log" 2>&1 & )
    sleep 3
  fi

  local ram model
  ram="$(total_ram_gb)"
  if [ "$ram" -ge 16 ]; then model="qwen2.5-coder:14b"; else model="gemma2"; fi
  say "Detected ${ram}GB RAM, suggesting: $model"
  dim "gemma2 is better at animation and generative art. qwen2.5-coder is sharper at full apps."

  if [ -z "$(ollama list 2>/dev/null | tail -n +2 | head -1)" ]; then
    confirm "Pull $model now (roughly 5GB)?" && run ollama pull "$model"
  else
    ok "Models already present"
    model="$(ollama list 2>/dev/null | tail -n +2 | head -1 | awk '{print $1}')"
  fi

  if [ ! -f "$HOME/.fcc/.env" ]; then
    info "Writing ~/.fcc/.env"
    if [ "$DRY" != 1 ]; then
      mkdir -p "$HOME/.fcc"
      printf 'MODEL="ollama/%s"\n' "$model" > "$HOME/.fcc/.env"
      secure_file "$HOME/.fcc/.env"
    fi
  else
    ok "~/.fcc/.env exists, leaving it alone"
  fi
  gate_local_brain
}

# ================================================================= STAGE 4
stage_4() {
  hdr "Stage 4 - Model routing"
  say "The stage worth slowing down for. Every tab talks to its own model, and there is"
  say "no shared pipeline, so each one is set independently."
  say ""
  say "  free on-device building  ->  a small local model      ~/.fcc/.env"
  say "  coding agents            ->  Claude, or a named :free  ~/.fcc/.env"
  say "  Hermes (and so Jarvis)   ->  a capable OpenRouter model  ~/.hermes/profiles/main/config.yaml"
  say "  video authoring          ->  a strong model            per tool"
  say ""
  warn "Keep small local models to the on-device builder, and watch for an assistant"
  warn "trying to unify everything onto one model for tidiness."
  say ""

  fix_claude_tab

  if have claude; then
    if ! claude --version >/dev/null 2>&1; then
      checkpoint "Run 'claude login' in another terminal (browser OAuth, uses your Claude plan)" "claude --version"
    else
      ok "Claude CLI responding"
    fi
  fi

  gate_routing
}

# ================================================================= STAGE 5
stage_5() {
  hdr "Stage 5 - Executor (Hermes)"
  if [ "$SKIP_HERMES" = 1 ]; then
    info "Skipped by --no-hermes"
    mark_expected_absent 5
    dim "Stage 5 recorded as intentionally absent, so the daily health check will not"
    dim "report it as breakage. Undo with: ./preflight.sh --unexpect 5"
    return 0
  fi
  say "Optional, but Jarvis, Loop, Radar, Goal Mode and Mastermind all sit on top of it."
  say ""

  local py
  py="$(best_python)"
  if [ -z "$py" ]; then
    bad "Hermes needs Python 3.10+. Go back to stage 0, or skip with --no-hermes."
    return 1
  fi

  if ! have hermes; then
    if have pipx; then
      confirm "Install hermes-agent via pipx?" && run pipx install hermes-agent
    else
      say "Installing into an isolated venv at ~/.agent-os-install/hermes-venv"
      if confirm "Proceed?"; then
        run "$py" -m venv "$STATE_DIR/hermes-venv"
        runsh "'$STATE_DIR/hermes-venv/bin/pip' install --upgrade pip hermes-agent"
        run mkdir -p "$HOME/.local/bin"
        [ "$DRY" != 1 ] && ln -sf "$STATE_DIR/hermes-venv/bin/hermes" "$HOME/.local/bin/hermes"
        case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) warn "Add ~/.local/bin to your PATH" ;; esac
      fi
    fi
  else
    ok "Hermes already installed at $(command -v hermes)"
  fi

  local env="$HOME/.hermes/profiles/main/.env"
  local cfg="$HOME/.hermes/profiles/main/config.yaml"
  [ "$DRY" != 1 ] && mkdir -p "$(dirname "$env")"

  if [ ! -f "$env" ] || ! grep -qE '^OPENROUTER_API_KEY=.+' "$env" 2>/dev/null; then
    say ""
    say "Hermes needs an OpenRouter key. Get one at https://openrouter.ai/keys"
    dim "Many models are free. With no credit you get 50 requests/day; \$5 of credit raises that to 1,000."
    dim "This script will never enter your card. Create the key yourself and paste it below."
    if [ "$DRY" != 1 ]; then
      printf 'OpenRouter key (blank to skip): '
      read -r k
      if [ -n "$k" ]; then
        touch "$env"
        grep -v '^OPENROUTER_API_KEY=' "$env" > "$env.tmp" 2>/dev/null || true
        printf 'OPENROUTER_API_KEY=%s\n' "$k" >> "$env.tmp"
        mv "$env.tmp" "$env"
        secure_file "$env"
        ok "Key written to $env"
      else
        warn "Skipped. Hermes, Jarvis, Loop and Mastermind stay offline until you add it."
        return 1
      fi
    fi
  else
    ok "OpenRouter key already set"
  fi

  if [ ! -f "$cfg" ]; then
    info "Writing a starter Hermes config with a fast, cheap model"
    [ "$DRY" != 1 ] && cat > "$cfg" <<'YAML'
# Hermes profile: main
# Jarvis is only ever as smart as this model. Subagents inherit it.
# Do NOT point this at a small local model - it cannot drive the tool loop.
model: anthropic/claude-haiku-4.5
YAML
    ok "Wrote $cfg"
  else
    ok "$cfg exists, leaving it alone"
  fi

  gate_executor
}

# ================================================================= driver
say "Agent OS staged installer"
dim "platform: $PLATFORM/$ARCH   pkg: $PKG   port: $PORT   dry-run: $DRY"

start=0
if [ -n "$FROM" ]; then start="$FROM"; fi

for n in 0 1 2 3 4 5; do
  if [ -n "$ONLY" ] && [ "$n" != "$ONLY" ]; then continue; fi
  if [ -z "$ONLY" ] && [ "$n" -lt "$start" ]; then continue; fi

  if "stage_$n"; then
    state_set "stage_$n" pass
  else
    state_set "stage_$n" fail
    say ""
    bad "Stage $n did not pass its gate."
    say "Stages are dependency-ordered, so there is no point continuing past a failure."
    say "Fix the item above, then re-run:"
    say ""
    say "  ${C_B}./install.sh --from $n${C_RST}"
    say ""
    exit 1
  fi
done

hdr "Done"
ok "Every stage attempted has passed its gate."
say ""
say "Next:"
say "  1. Open http://localhost:$PORT in Chrome"
say "  2. Run ./preflight.sh any time to re-verify"
say "  3. Start with four tabs and add more as you need them"
say ""
dim "If a tab looks unstyled or missing, that feature is in a newer release. Download"
dim "the newest pack and update, rather than having an AI rebuild the tab."
