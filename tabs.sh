#!/usr/bin/env bash
# tabs.sh - install optional Agent OS tabs, one at a time, each with its own gate.
#
# install.sh handles the spine. This handles everything else, on demand.
#
#   ./tabs.sh                    status of every tab
#   ./tabs.sh --list             what each tab needs, costs, and whether it is worth it
#   ./tabs.sh --add <id>         install one tab, with dependency checks and a verify step
#   ./tabs.sh --check <id>       verify one tab without changing anything
#   ./tabs.sh --recommended      install the tabs marked 'take', in order
#   ./tabs.sh --no-prompt        never block on a human step, skip that tab and note it
#
# Every tab checks its prerequisites first and stops rather than half-installing.
# Keys come from the vault (./vault.sh) via ./keys.sh, never entered here.
#
# This script will never enter your card details or log in on your behalf.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

CATALOGUE="$SCRIPT_DIR/tabs.json"
[ -f "$CATALOGUE" ] || die "tabs.json not found next to this script"
have node || die "node is required. Run ./install.sh --stage 0 first."
detect_platform
acquire_lock

MODE="status"; ARG=""; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --add) MODE=add; ARG="${2:-}"; shift 2 ;;
    --check) MODE=check; ARG="${2:-}"; shift 2 ;;
    --recommended) MODE=recommended; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --no-prompt) AOS_NOPROMPT=1; export AOS_NOPROMPT; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

jq_() { node -e "$1" "$CATALOGUE" "${2:-}" "${3:-}" 2>/dev/null; }

tab_field() { # tab_field <id> <field>
  jq_ '
    const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const t=c.tabs.find(x=>x.id===process.argv[2]); if(!t) process.exit(0);
    const v=t[process.argv[3]];
    process.stdout.write(Array.isArray(v)?v.join(" "):String(v??""));
  ' "$1" "$2"
}
tab_req() { # tab_req <id> commands|keys|tabs
  jq_ '
    const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const t=c.tabs.find(x=>x.id===process.argv[2]); if(!t) process.exit(0);
    process.stdout.write((t.requires?.[process.argv[3]]||[]).join(" "));
  ' "$1" "$2"
}
all_ids()   { jq_ 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).tabs.forEach(t=>console.log(t.id))'; }
take_ids()  { jq_ 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).tabs.filter(t=>t.verdict==="take").forEach(t=>console.log(t.id))'; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  is_interactive || { dim "no terminal, declining: $1"; return 1; }
  printf '%s%s [y/N] %s' "$C_YEL" "$1" "$C_RST"; read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
checkpoint() {
  hdr "HUMAN STEP"; say "  $1"; [ -n "${2:-}" ] && dim "  verify: $2"
  is_interactive || { warn "Left for you. This tab stays unverified until it is done."; return 0; }
  printf '%sPress return when done, or Ctrl-C to stop. %s' "$C_YEL" "$C_RST"; read -r _
}

# Tabs that cannot be installed without a human typing something only they know:
# a site domain, a WordPress password, a profile name. In an unattended run they
# are named and skipped, never half-installed.
needs_a_human() { # needs_a_human "what it will ask for"
  is_interactive && return 1
  warn "Skipped: this tab needs $1, and there is no terminal to ask on."
  dim "Run ./tabs.sh --add <id> from a terminal when you are ready."
  return 0
}

# Fetched ONCE via a machine-readable interface. Grepping human-readable output was
# fragile against wording changes, and on an age vault it prompted for the passphrase
# once per key checked.
SET_KEYS=""; SET_KEYS_LOADED=0
load_set_keys() {
  [ "$SET_KEYS_LOADED" = 1 ] && return 0
  [ -x "$SCRIPT_DIR/keys.sh" ] && SET_KEYS="$("$SCRIPT_DIR/keys.sh" --names 2>/dev/null)"
  SET_KEYS_LOADED=1
}
key_present() {
  load_set_keys
  printf '%s\n' "$SET_KEYS" | grep -qx "$1"
}

verify_tab() { # runs the catalogue's verify command quietly
  local cmd; cmd="$(tab_field "$1" verify)"
  [ -z "$cmd" ] && return 1
  bash -c "$cmd" >/dev/null 2>&1
}

check_requires() { # returns 1 and explains if anything is missing
  local id="$1" missing=0 c k t
  for c in $(tab_req "$id" commands); do
    have "$c" || { bad "missing command: $c"; fix "$(pkg_install_hint "$c")"; missing=1; }
  done
  for k in $(tab_req "$id" keys); do
    key_present "$k" || { bad "missing key: $k"; fix "./keys.sh --list  then  ./vault.sh --set $k"; missing=1; }
  done
  for t in $(tab_req "$id" tabs); do
    case "$t" in
      hermes) have hermes || { bad "requires Hermes"; fix "./install.sh --stage 5"; missing=1; } ;;
      *) verify_tab "$t" || { bad "requires tab: $t"; fix "./tabs.sh --add $t"; missing=1; } ;;
    esac
  done
  return $missing
}

# ==================================================== per-tab procedures
add_ffmpeg() {
  have ffmpeg && { ok "Already installed"; return 0; }
  case "$PKG" in
    brew) confirm "Install ffmpeg via Homebrew?" && run_ brew install ffmpeg ;;
    apt)  confirm "Install ffmpeg via apt?" && run_ sudo apt-get install -y ffmpeg ;;
    dnf)  confirm "Install ffmpeg via dnf?" && run_ sudo dnf install -y ffmpeg ;;
    *)    checkpoint "Install ffmpeg for your platform" "ffmpeg -version" ;;
  esac
}
run_() { "$@"; }

add_opencode() {
  have opencode && { ok "Already installed"; return 0; }
  say "Installs from https://opencode.ai/install"
  confirm "Run the installer?" || return 1
  bash -c 'curl -fsSL https://opencode.ai/install | bash'
}

add_omniroute() {
  have omniroute || { confirm "npm install -g omniroute?" && npm install -g omniroute; }
  have omniroute || return 1
  ok "Installed. Start the gateway with: omniroute"
  dim "Runs on localhost:20128. It is Anthropic-compatible, so you can point Claude Code at it:"
  dim "  export ANTHROPIC_BASE_URL=http://localhost:20128/v1"
  dim "Slowness is it hunting for a currently-free provider, not a fault."
}

add_seo_research() {
  local cred="$HOME/.agentic-os/gsc-oauth-client.json"
  mkdir -p "$HOME/.agentic-os"
  if [ ! -f "$cred" ]; then
    say "SEO Research reads Search Console properties you already own. Read-only."
    say ""
    say "  1. Open https://console.cloud.google.com/apis/credentials"
    say "     signed in as the account that owns those Search Console properties"
    say "  2. Search for 'Search Console API' and click Enable"
    say "  3. Create Credentials > OAuth client ID > Application type: Desktop app > Create"
    say "  4. Download the JSON and save it as exactly:"
    say "     $cred"
    checkpoint "Do the four steps above" "the file exists at that exact path"
  fi
  [ -f "$cred" ] || { bad "Credential file not found at $cred"; return 1; }
  chmod 600 "$cred"
  ok "Credential file present"

  local py app
  py="$(best_python)"; [ -z "$py" ] && py="$(command -v python3)"
  "$py" -c 'import googleapiclient, google_auth_oauthlib' 2>/dev/null || {
    info "Installing the two Google API client libraries"
    "$py" -m pip install --user google-api-python-client google-auth-oauthlib || {
      bad "pip install failed"; return 1; }
  }

  app="$(find_app_dir)"
  local script="${app%/source}/scripts/gsc-connect.py"
  [ -f "$script" ] || script="$app/../scripts/gsc-connect.py"
  if [ -f "$script" ]; then
    info "Running the connect script. A browser will open for read-only approval."
    "$py" "$script"
  else
    warn "gsc-connect.py not found in the pack. Run it from the Agent OS folder:"
    say  "  python3 scripts/gsc-connect.py"
    return 1
  fi
  [ -f "$HOME/.agentic-os/gsc-token.json" ] && chmod 600 "$HOME/.agentic-os/gsc-token.json"
}

wp_add_site() { # wp_add_site <cfg>
  local cfg="$1" dom wpuser wppw
  printf 'Site domain (e.g. example.com): '; read -r dom
  [ -z "$dom" ] && { bad "No domain entered"; return 1; }
  printf 'WordPress username: '; read -r wpuser
  printf 'Application password (input hidden): '
  stty -echo 2>/dev/null; IFS= read -r wppw; stty echo 2>/dev/null; printf '\n'
  [ -z "$wppw" ] && { bad "No password entered"; return 1; }
  node -e '
    const fs=require("fs");
    const [f,dom,user,pw]=process.argv.slice(1);
    const c=JSON.parse(fs.readFileSync(f,"utf8"));
    c.sites=c.sites||{};
    c.sites[dom]={base:`https://${dom}/wp-json/wp/v2`,user,app_pw:pw,category:null};
    if(!c.default) c.default=dom;
    fs.writeFileSync(f,JSON.stringify(c,null,2)+"\n");
  ' "$cfg" "$dom" "$wpuser" "$wppw"
  chmod 600 "$cfg"; unset wppw
  ok "Added $dom"
  curl -fsS --max-time 10 "https://$dom/wp-json/wp/v2/types" >/dev/null 2>&1 \
    && ok "REST API reachable" || warn "Could not reach https://$dom/wp-json/"
}

wp_bulk_import() { # wp_bulk_import <cfg>
  local cfg="$1" csv n=0 dom user pw
  say "CSV format, one site per line, no header:"
  dim "  example.com,editor,xxxx xxxx xxxx xxxx"
  warn "That file contains live credentials. Delete it when the import finishes."
  printf 'Path to CSV: '; read -r csv
  csv="${csv/#\~/$HOME}"
  [ -f "$csv" ] || { bad "No such file: $csv"; return 1; }
  while IFS=, read -r dom user pw; do
    dom="$(printf '%s' "$dom" | tr -d ' \r')"
    user="$(printf '%s' "$user" | sed 's/^ *//; s/ *$//; s/\r//')"
    pw="$(printf '%s' "$pw" | sed 's/^ *//; s/ *$//; s/\r//')"
    [ -z "$dom" ] || [ -z "$user" ] || [ -z "$pw" ] && continue
    case "$dom" in \#*) continue ;; esac
    node -e '
      const fs=require("fs");
      const [f,dom,user,pw]=process.argv.slice(1);
      const c=JSON.parse(fs.readFileSync(f,"utf8"));
      c.sites=c.sites||{};
      c.sites[dom]={base:`https://${dom}/wp-json/wp/v2`,user,app_pw:pw,category:null};
      if(!c.default) c.default=dom;
      fs.writeFileSync(f,JSON.stringify(c,null,2)+"\n");
    ' "$cfg" "$dom" "$user" "$pw" && { ok "added $dom"; n=$((n+1)); }
  done < "$csv"
  chmod 600 "$cfg"
  say ""; ok "$n site(s) imported into $cfg"
  warn "Now delete $csv - it holds application passwords in plaintext."
  dim "  shred -u '$csv'   (or rm -P on macOS)"
}

add_wordpress() {
  needs_a_human "your site domain, username and application password" && return 1
  local cfg="$HOME/.agentic-os/wordpress.json"
  mkdir -p "$HOME/.agentic-os"
  if [ -f "$cfg" ]; then
    chmod 600 "$cfg"
    ok "Config exists with $(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(c.sites||{}).length)' "$cfg") site(s)"
    say ""
    say "  1  add another site"
    say "  2  bulk import from CSV (domain,username,app_password per line)"
    say "  3  leave it alone"
    printf 'Choice [3]: '; read -r ch
    case "$ch" in
      1) wp_add_site "$cfg"; return $? ;;
      2) wp_bulk_import "$cfg"; return $? ;;
      *) dim "Unchanged."; return 0 ;;
    esac
  fi

  say "Publishes via the WordPress REST API using an application password."
  say ""
  warn "Use an APPLICATION PASSWORD, never your admin password."
  dim "In WP admin: Users > Profile > Application Passwords > add a new one."
  dim "It is per-site, revocable, and cannot be used to log in to wp-admin."
  say ""
  confirm "Set up the first site now?" || return 1

  printf 'Site domain (e.g. example.com): '; read -r dom
  [ -z "$dom" ] && { bad "No domain entered"; return 1; }
  printf 'WordPress username: '; read -r wpuser
  printf 'Application password (input hidden): '
  stty -echo 2>/dev/null; IFS= read -r wppw; stty echo 2>/dev/null; printf '\n'
  [ -z "$wppw" ] && { bad "No password entered"; return 1; }
  printf 'Author name for the bio block (blank to skip): '; read -r author

  node -e '
    const fs=require("fs");
    const [f,dom,user,pw,author]=process.argv.slice(1);
    const cfg={
      default: dom,
      sites: { [dom]: { base:`https://${dom}/wp-json/wp/v2`, user, app_pw: pw, category: null } },
      profile: author ? { author, bio:[], ctas:[], footerHtml:"" } : undefined
    };
    fs.writeFileSync(f, JSON.stringify(cfg,null,2)+"\n");
  ' "$cfg" "$dom" "$wpuser" "$wppw" "$author"
  chmod 600 "$cfg"
  unset wppw
  ok "Wrote $cfg (mode 600)"

  info "Testing the REST endpoint"
  if curl -fsS --max-time 10 "https://$dom/wp-json/wp/v2/types" >/dev/null 2>&1; then
    ok "REST API reachable at https://$dom/wp-json/"
  else
    warn "Could not reach https://$dom/wp-json/. Check the REST API is not disabled by a"
    warn "security plugin, and that permalinks are not set to Plain."
  fi
  say ""
  dim "To add more sites, edit $cfg and add another entry under 'sites'."
  dim "Never paste an application password into a chat window."
}

add_agent_kanban() {
  if ! curl -fsS --max-time 4 http://localhost:11434/api/tags >/dev/null 2>&1; then
    bad "Ollama is not running"; fix "./install.sh --stage 3"; return 1
  fi
  [ -n "$(ollama list 2>/dev/null | tail -n +2 | head -1)" ] || {
    bad "No Ollama models pulled"; fix "ollama pull gemma2"; return 1; }
  ok "Nothing to install. Agent Kanban runs on the local Ollama you already have."
  dim "Open the Agent Kanban tab and give it a well-scoped goal."
  dim "Vague goals produce vague cards. That is more true here than anywhere else in the pack."
}

add_thumbnails() {
  local dir="$HOME/.claude/skills/youtube-thumbnails"
  mkdir -p "$dir/scripts"
  local src
  for src in "$SCRIPT_DIR/../extras/thumbnail-generator" "$(dirname "$(find_app_dir)")/extras/thumbnail-generator"; do
    if [ -d "$src" ]; then cp "$src"/*.py "$dir/scripts/" 2>/dev/null && ok "Copied generator scripts from the pack"; break; fi
  done
  if [ ! -f "$dir/scripts/generate.py" ]; then
    bad "generate.py not found in the pack's extras/thumbnail-generator folder"
    fix "run this from inside the unzipped pack folder so it can find extras/"
    return 1
  fi
  local py; py="$(best_python)"; [ -z "$py" ] && py="$(command -v python3)"
  "$py" -c 'import PIL' 2>/dev/null || { info "Installing Pillow"; "$py" -m pip install --user Pillow; }
  "$py" -c 'import PIL' 2>/dev/null || { bad "Pillow still not importable"; return 1; }
  ok "Pillow present"
  "$SCRIPT_DIR/keys.sh" --apply >/dev/null 2>&1
  [ -f "$dir/.env" ] && chmod 600 "$dir/.env"
  ok "Key written from the vault"
  say ""
  warn "The OpenAI API is prepaid and separate from ChatGPT Plus."
  dim "An 'insufficient_quota' error means an empty API balance, not a broken tool."
  dim "Verify the key works now:  ./keys.sh --check"
}

add_astros() {
  have hermes || { bad "Requires Hermes"; fix "./install.sh --stage 5"; return 1; }
  ok "Nothing to install. Astros ships built in and works keyless off channel RSS."
  dim "Open Hermes > Astros, add the channels and keywords you want watched, hit scan."
  dim "If the tab is missing, that feature is in a newer release. Update the pack rather than rebuilding it."
}

add_video_editor() {
  have ffmpeg || { bad "Requires ffmpeg"; fix "./tabs.sh --add ffmpeg"; return 1; }
  have claude || warn "No Claude CLI found. The Video Editor needs a coding agent to drive edits."
  ok "ffmpeg present"
  dim "The tab also needs the video-use skill installed for your coding agent."
  dim "If a render comes back wrong, tell the agent what looked wrong. That iteration is the interface."
}

add_openseo() {
  have docker || { bad "Docker is required"; fix "https://www.docker.com/products/docker-desktop"; return 1; }
  docker info >/dev/null 2>&1 || { bad "Docker is installed but not running. Start Docker Desktop."; return 1; }
  ok "Docker running"
  local dir="$HOME/open-seo"
  if [ ! -d "$dir" ]; then
    warn "OpenSEO is a separate project and is not bundled with the pack."
    say "Clone it into $dir first, then re-run this."
    return 1
  fi
  "$SCRIPT_DIR/keys.sh" --apply >/dev/null 2>&1
  [ -f "$dir/.env" ] && chmod 600 "$dir/.env" && ok "DataForSEO credentials written from the vault"
  ( cd "$dir" && docker compose up -d ) || { bad "docker compose failed"; return 1; }
  info "Waiting for the container"
  local i=0; while [ $i -lt 20 ]; do curl -fsS --max-time 2 http://localhost:3001 >/dev/null 2>&1 && break; sleep 2; i=$((i+1)); done
  dim "Your data stays local. Only the DataForSEO calls leave, billed to your account."
}

add_hermes_profile() {
  needs_a_human "a profile name you choose" && return 1
  have hermes || { bad "Requires Hermes"; fix "./install.sh --stage 5"; return 1; }
  say "Each profile is an isolated instance: its own model, persona, memory and thread."
  printf 'Profile name (e.g. a client or a role): '; read -r pname
  [ -z "$pname" ] && { bad "No name entered"; return 1; }
  if confirm "Clone your working key and model into it?"; then
    hermes profile create "$pname" --clone
  else
    hermes profile create "$pname"
  fi
  hermes profile list
  say ""
  dim "Set its persona in ~/.hermes/profiles/$pname/SOUL.md"
  warn "Check its model in ~/.hermes/profiles/$pname/config.yaml. A small local model cannot"
  warn "drive the Hermes tool loop. Run ./preflight.sh to confirm routing."
}

add_paperclip() {
  have npx || { bad "npx is required"; return 1; }
  warn "This is a demo. It has real agents that make real model calls."
  confirm "Run 'npx paperclipai onboard --yes'? First run takes a few minutes." || return 1
  npx paperclipai onboard --yes
  say ""
  warn "Before you wake any agent, set a MONTHLY BUDGET per agent so nothing runs away."
  dim "For Hermes agents, set the command to the full path from 'which hermes' ($(command -v hermes 2>/dev/null || echo 'not installed')),"
  dim "not the bare name. That is the single most common Paperclip failure."
  dim "Do not wake all agents at once on a small machine."
}

add_radar() {
  warn "Radar requires an X Premium+ / SuperGrok subscription. That is a real monthly cost."
  say "Check at https://x.com/i/premium"
  confirm "Continue?" || return 1
  have grok || { bad "Grok CLI not installed"; fix "install the Grok CLI, then: grok login --device-auth"; return 1; }
  checkpoint "Run 'grok login --device-auth' in another terminal" "grok --version"
  have hermes || { bad "Radar reads X through Hermes"; fix "./install.sh --stage 5"; return 1; }
  ok "Prerequisites met"
  dim "Radar auto-logs every sweep to your vault under AI News/."
  dim "For publishing, set up the WordPress config first: ./tabs.sh --add wordpress"
}

add_parasite_seo() {
  ok "Nothing to install. Parasite SEO ships built in, inside the SEO tab."
  dim "Take a query you already rank for, then recreate it platform-native everywhere else."
  dim "If the sub-tab is missing, that feature is in a newer release. Update the pack rather than rebuilding it."
}
add_deepseek_coder() {
  "$SCRIPT_DIR/keys.sh" --apply >/dev/null 2>&1
  [ -f "$HOME/.fcc/.env" ] && chmod 600 "$HOME/.fcc/.env"
  ok "Key written to ~/.fcc/.env from the vault."
  dim "Confirm it works:  ./keys.sh --check"
}
add_jcode() {
  have jcode && { ok "Already installed"; return 0; }
  say "jcode is an open-source Rust coding agent (~28MB RAM)."
  say "Install it from https://github.com/1jehuang/jcode, then re-run this."
  checkpoint "Install jcode following its own README" "jcode --version"
}
add_prime_agent() {
  have prime-agent && { ok "Already installed"; return 0; }
  say "Installs from https://app.primeintellect.ai/prime-agent/install.sh"
  confirm "Run the installer?" || return 1
  runsh_t 'curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | bash'
}
runsh_t() { bash -c "$1"; }
add_muse_code() {
  "$SCRIPT_DIR/keys.sh" --apply >/dev/null 2>&1
  ok "Uses your existing OpenRouter key. Nothing else to install."
  dim "Open the Muse Code tab. If it is missing, update your pack."
}
add_higgsfield() {
  have hermes || { bad "Requires Hermes"; fix "./install.sh --stage 5"; return 1; }
  ok "Driven through Hermes, which is already set up."
  dim "Add your Higgsfield credentials in the tab itself."
}
add_openmausbot() {
  ok "Nothing to install here. OpenMausBot is a separate macOS app."
  dim "See https://github.com/milind-soni/OpenMausBot"
}

# ==================================================== dispatch
do_add() {
  [ -n "$ARG" ] || die "Usage: ./tabs.sh --add <id>   (see ./tabs.sh --list)"
  local label; label="$(tab_field "$ARG" label)"
  [ -z "$label" ] && { bad "Unknown tab: $ARG"; say "Available:"; all_ids | sed 's/^/  /'; return 1; }

  hdr "$label"
  local verdict note
  verdict="$(tab_field "$ARG" verdict)"; note="$(tab_field "$ARG" note)"
  say "cost: $(tab_field "$ARG" cost)    verdict: $verdict"
  [ -n "$note" ] && { say ""; dim "$note"; }
  say ""
  if [ "$verdict" = skip ] && [ "$ASSUME_YES" != 1 ]; then
    confirm "This is marked 'skip' for your stack. Install anyway?" || return 0
  fi

  if verify_tab "$ARG"; then
    if [ "$(tab_field "$ARG" rerunnable)" != "true" ]; then
      ok "Already installed and verifying"; return 0
    fi
    dim "Already set up. This tab supports being run again to add more."
  fi
  check_requires "$ARG" || { say ""; bad "Prerequisites missing. Nothing was changed."; return 1; }

  case "$ARG" in
    ffmpeg) add_ffmpeg ;; opencode) add_opencode ;; omniroute) add_omniroute ;;
    seo-research) add_seo_research ;; wordpress) add_wordpress ;;
    agent-kanban) add_agent_kanban ;; thumbnails) add_thumbnails ;;
    astros) add_astros ;; video-editor) add_video_editor ;; openseo) add_openseo ;;
    hermes-profile) add_hermes_profile ;; paperclip) add_paperclip ;; radar) add_radar ;;
    parasite-seo) add_parasite_seo ;; deepseek-coder) add_deepseek_coder ;;
    jcode) add_jcode ;; prime-agent) add_prime_agent ;; muse-code) add_muse_code ;;
    higgsfield) add_higgsfield ;; openmausbot) add_openmausbot ;;
    *) bad "No procedure defined for $ARG"; return 1 ;;
  esac

  say ""
  if verify_tab "$ARG"; then ok "Verified: $label"; else
    warn "Install ran but the verify check did not pass yet."
    dim "Some tabs need the dashboard restarted before they appear."
  fi
}

do_check() {
  [ -n "$ARG" ] || die "Usage: ./tabs.sh --check <id>"
  if verify_tab "$ARG"; then ok "$(tab_field "$ARG" label)"; else
    bad "$(tab_field "$ARG" label) not verifying"; fix "./tabs.sh --add $ARG"; fi
}

do_status() {
  hdr "Optional tabs"
  local id v
  for id in $(all_ids); do
    v="$(tab_field "$id" verdict)"
    if verify_tab "$id"; then
      ok "$(printf '%-16s %-7s %s' "$id" "[$v]" "$(tab_field "$id" label)")"
    else
      info "$(printf '%-16s %-7s %s' "$id" "[$v]" "$(tab_field "$id" label)")"
    fi
  done
  say ""
  dim "./tabs.sh --list for detail, --add <id> to install, --recommended for the 'take' set."
}

do_list() {
  jq_ '
    const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    for(const v of ["take","maybe","skip"]){
      const ts=c.tabs.filter(t=>t.verdict===v); if(!ts.length) continue;
      console.log("\n"+v.toUpperCase()+" - "+c.verdicts[v]+"\n");
      for(const t of ts){
        console.log("  "+t.id);
        console.log("     "+t.label+"   ["+t.cost+"]");
        const r=t.requires||{};
        const need=[...(r.commands||[]),...(r.keys||[]),...(r.tabs||[])];
        if(need.length) console.log("     needs:   "+need.join(", "));
        console.log("     "+t.note);
        console.log("");
      }
    }
  '
}

do_recommended() {
  hdr "Installing the recommended set"
  dim "Everything marked 'take'. Anything already verifying is left alone, anything"
  dim "missing is installed, and a tab that cannot be finished is skipped, not fatal."
  local id skipped=""
  for id in $(take_ids); do
    ARG="$id"; say ""
    if ! do_add; then warn "Skipped $id"; skipped="$skipped $id"; fi
  done
  say ""
  [ -n "$skipped" ] && { warn "Not installed:$skipped"; dim "Add any of them later with ./tabs.sh --add <id>"; say ""; }
  do_status
  return 0
}

case "$MODE" in
  status) do_status ;; list) do_list ;; add) do_add ;;
  check) do_check ;; recommended) do_recommended ;;
esac
