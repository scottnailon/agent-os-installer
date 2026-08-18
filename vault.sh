#!/usr/bin/env bash
# vault.sh - the key store, the security audit, and session mode.
#
# WHAT THIS IS FOR, honestly. Two things, and encryption is the lesser one.
#
#   1. ONE PLACE FOR YOUR KEYS. You enter each key once. keys.sh --apply then writes it
#      to all eight scattered files Agent OS reads keys from. That is the convenience
#      the whole toolkit is built around.
#
#   2. THE AUDIT. --audit finds keys pasted into shell history and .env files sitting
#      inside git repos. That is how keys actually leak, and it is the single most
#      useful thing in this file.
#
# WHAT IT IS NOT. It does not keep your keys encrypted while you use Agent OS. The eight
# destination files must stay plaintext, because Hermes and the rest read them directly
# and have no vault support. Encrypting the master copy protects it in backups and sync,
# and on a locked machine, and that is all.
#
# The store does make one real thing possible: because there is a spare copy,
# --session-end can strip the plaintext destinations without you losing your keys.
# Full-disk encryption is worth more than all of this combined.
#
#   ./vault.sh --init         pick and set up the best available backend
#   ./vault.sh --status       which backend, how many secrets, what is exposed
#   ./vault.sh --set KEY      store a secret (typed, never shown, never in argv)
#   ./vault.sh --rm KEY       delete a secret
#   ./vault.sh --list         secret NAMES only, never values
#   ./vault.sh --import       pull in an existing ~/.agent-os-keys.env, then shred it
#   ./vault.sh --audit        find plaintext keys lying around this machine
#   ./vault.sh --purge        remove keys from destination files (locks the system down)
#   ./vault.sh --session-start / --session-end   write keys only while you are working
#
# BACKENDS for the master copy, in order of preference:
#   op        1Password CLI, if installed and signed in
#   keychain  macOS Keychain. Hardware-backed on Apple Silicon, unlocks with your login
#   age       encrypted file with a passphrase. Cross-platform, good on Linux and WSL
#   plain     the original mode-600 file. Explicitly insecure, offered only as a fallback
#
# WHAT THIS DOES NOT PROTECT. Read SECURITY.md. The destination files that Hermes,
# Thumbnail Studio and the rest actually read must remain plaintext, because those
# tools have no vault support. This shrinks the plaintext window, it does not close it.
#
# Secrets are never passed as command arguments, because argv is visible to every
# process on the machine via ps. They are always read from the terminal.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# $USER is unset in cron and many non-login shells, and `set -u` makes that fatal.
VAULT_USER="${USER:-${LOGNAME:-$(id -un 2>/dev/null || echo user)}}"

VAULT_DIR="$HOME/.agent-os-vault"
VAULT_CONF="$VAULT_DIR/backend"
AGE_FILE="$VAULT_DIR/keys.age"
PLAIN_FILE="$HOME/.agent-os-keys.env"
KC_SERVICE_PREFIX="agent-os"
OP_VAULT="${OP_VAULT:-Agent OS}"

# Files the tabs actually read. Verified against the agent-os-pack-2026-08-16 source.
DEST_FILES="
$HOME/.hermes/profiles/main/.env
$HOME/.hermes/profiles/glm-5-2/.env
$HOME/.hermes/profiles/sakana-fugu/.env
$HOME/.claude/skills/youtube-thumbnails/.env
$HOME/open-seo/.env
$HOME/.agentic-os/heygen.env
$HOME/.agentic-os/suno.env
$HOME/.agentic-os/gemini.env
$HOME/.agentic-os/indexceptional.env
$HOME/.fcc/.env
"

detect_platform
acquire_lock

MODE="status"; ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --init) MODE=init; shift ;;
    --status) MODE=status; shift ;;
    --set) MODE=set; ARG="${2:-}"; shift 2 ;;
    --get-quiet) MODE=getq; ARG="${2:-}"; shift 2 ;;
    --dump) MODE=dump; shift ;;
    --set-stdin) MODE=setstdin; ARG="${2:-}"; shift 2 ;;
    --rm) MODE=rm; ARG="${2:-}"; shift 2 ;;
    --list) MODE=list; shift ;;
    --import) MODE=import; shift ;;
    --audit) MODE=audit; shift ;;
    --purge) MODE=purge; shift ;;
    --session-start) MODE=sesstart; shift ;;
    --session-end) MODE=sessend; shift ;;
    --backend) FORCE_BACKEND="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

backend() {
  [ -n "${FORCE_BACKEND:-}" ] && { echo "$FORCE_BACKEND"; return; }
  [ -f "$VAULT_CONF" ] && { cat "$VAULT_CONF"; return; }
  echo "none"
}

best_backend() {
  if have op && op account list >/dev/null 2>&1; then echo op; return; fi
  if [ "$PLATFORM" = macos ] && have security; then echo keychain; return; fi
  if have age; then echo age; return; fi
  echo none
}

# ---------------------------------------------------------------- backends
# Each implements: vb_set NAME (value on stdin), vb_get NAME, vb_rm NAME, vb_list

vb_set() {
  local n="$1" v
  v="$(cat)"   # value arrives on stdin, never argv
  [ -z "$v" ] && { bad "Empty value, nothing stored"; return 1; }
  case "$(backend)" in
    keychain)
      security add-generic-password -U -a "$VAULT_USER" -s "$KC_SERVICE_PREFIX:$n" \
        -D "Agent OS API key" -w "$v" >/dev/null 2>&1 || return 1 ;;
    op)
      if op item get "$n" --vault "$OP_VAULT" >/dev/null 2>&1; then
        op item edit "$n" --vault "$OP_VAULT" "credential=$v" >/dev/null 2>&1 || return 1
      else
        op item create --category "API Credential" --title "$n" --vault "$OP_VAULT" \
          "credential=$v" >/dev/null 2>&1 || return 1
      fi ;;
    age)
      local tmp cur
      cur="$(age_read)" || return 1
      tmp="$(printf '%s\n' "$cur" | grep -vE "^$n=" || true)"
      printf '%s\n%s=%s\n' "$tmp" "$n" "$v" | grep -vE '^$' | age_write || return 1 ;;
    plain)
      touch "$PLAIN_FILE"; chmod 600 "$PLAIN_FILE"
      grep -vE "^[[:space:]]*$n=" "$PLAIN_FILE" > "$PLAIN_FILE.tmp" 2>/dev/null || true
      printf '%s=%s\n' "$n" "$v" >> "$PLAIN_FILE.tmp"
      mv "$PLAIN_FILE.tmp" "$PLAIN_FILE"; chmod 600 "$PLAIN_FILE" ;;
    *) bad "No vault initialised. Run ./vault.sh --init"; return 1 ;;
  esac
}

vb_get() { # prints value to stdout. Callers must not log it.
  local n="$1"
  case "$(backend)" in
    keychain) security find-generic-password -a "$VAULT_USER" -s "$KC_SERVICE_PREFIX:$n" -w 2>/dev/null ;;
    op)       op read "op://$OP_VAULT/$n/credential" 2>/dev/null ;;
    age)      age_read 2>/dev/null | grep -E "^$n=" | tail -1 | cut -d= -f2- ;;
    plain)    [ -f "$PLAIN_FILE" ] && grep -E "^[[:space:]]*$n=" "$PLAIN_FILE" 2>/dev/null | tail -1 | cut -d= -f2- ;;
    *) echo "" ;;
  esac
}

vb_rm() {
  local n="$1"
  case "$(backend)" in
    keychain) security delete-generic-password -a "$VAULT_USER" -s "$KC_SERVICE_PREFIX:$n" >/dev/null 2>&1 ;;
    op)       op item delete "$n" --vault "$OP_VAULT" >/dev/null 2>&1 ;;
    age)      age_read | grep -vE "^$n=" | age_write ;;
    plain)    [ -f "$PLAIN_FILE" ] && { grep -vE "^[[:space:]]*$n=" "$PLAIN_FILE" > "$PLAIN_FILE.tmp" || true; mv "$PLAIN_FILE.tmp" "$PLAIN_FILE"; } ;;
  esac
}

vb_list() { # NAMES only
  case "$(backend)" in
    keychain) security dump-keychain 2>/dev/null | grep -o "\"$KC_SERVICE_PREFIX:[A-Z_]*\"" | tr -d '"' | sed "s/$KC_SERVICE_PREFIX://" | sort -u ;;
    op)       op item list --vault "$OP_VAULT" --format json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{JSON.parse(s).forEach(i=>console.log(i.title))}catch(e){}})' ;;
    age)      age_read 2>/dev/null | grep -E '^[A-Z_]+=' | cut -d= -f1 | sort -u ;;
    plain)    [ -f "$PLAIN_FILE" ] && grep -E '^[[:space:]]*[A-Z_]+=.+' "$PLAIN_FILE" | cut -d= -f1 | tr -d ' ' | sort -u ;;
  esac
}

age_read() {
  [ -f "$AGE_FILE" ] || { echo ""; return 0; }
  age -d "$AGE_FILE" 2>/dev/null || { bad "Could not decrypt (wrong passphrase?)"; return 1; }
}
age_write() {
  mkdir -p "$VAULT_DIR"; chmod 700 "$VAULT_DIR"
  age -p -o "$AGE_FILE.tmp" || return 1
  mv "$AGE_FILE.tmp" "$AGE_FILE"; chmod 600 "$AGE_FILE"
}

file_mode() { # portable octal mode. GNU stat -c and BSD stat -f differ, and on Linux
              # 'stat -f' silently means FILESYSTEM stat, so validate the output.
  local m
  m="$(stat -c '%a' "$1" 2>/dev/null)"
  case "${m:-x}" in ''|*[!0-7]*) m="$(stat -f '%A' "$1" 2>/dev/null)" ;; esac
  case "${m:-x}" in ''|*[!0-7]*) m="?" ;; esac
  printf '%s' "$m"
}

read_secret() { # prompt on tty, no echo, never touches history or argv
  local prompt="$1" v
  printf '%s' "$prompt" > /dev/tty
  stty -echo 2>/dev/null
  IFS= read -r v < /dev/tty
  stty echo 2>/dev/null
  printf '\n' > /dev/tty
  printf '%s' "$v"
}

# ---------------------------------------------------------------- init
do_init() {
  hdr "Secrets vault"
  local b cur
  cur="$(backend)"
  [ "$cur" != none ] && { ok "Vault already initialised: $cur"; dim "Re-run with --backend <name> to switch."; return 0; }

  b="${FORCE_BACKEND:-$(best_backend)}"
  say "Available on this machine:"
  have op && op account list >/dev/null 2>&1 && say "  op        1Password CLI, signed in" || dim "  op        not available (install 1Password CLI and sign in)"
  [ "$PLATFORM" = macos ] && say "  keychain  macOS Keychain, hardware-backed on Apple Silicon" || dim "  keychain  macOS only"
  have age && say "  age       encrypted file, passphrase protected" || dim "  age       not installed ($(pkg_install_hint age))"
  say "  plain     mode-600 file. Insecure. Fallback only."
  say ""

  if [ "$b" = none ] && [ "$PKG" != none ]; then
    warn "No encrypted backend available."
    say ""
    printf '%sInstall age now (%s)? [Y/n] %s' "$C_YEL" "$(pkg_install_hint age)" "$C_RST"
    read -r a
    case "$a" in
      n|N|no|NO) : ;;
      *)
        case "$PKG" in
          apt)  sudo apt-get update -qq && sudo apt-get install -y age ;;
          dnf)  sudo dnf install -y age ;;
          brew) brew install age ;;
        esac
        if have age; then ok "age installed"; b=age; fi ;;
    esac
  fi

  if [ "$b" = none ]; then
    say "Install an encrypted backend, then re-run:"
    say "  $(pkg_install_hint age)"
    say ""
    printf 'Fall back to plaintext for now? [y/N] '
    read -r a
    case "$a" in y|Y|yes|YES) b=plain ;; *) return 1 ;; esac
  fi

  mkdir -p "$VAULT_DIR"; chmod 700 "$VAULT_DIR"
  printf '%s\n' "$b" > "$VAULT_CONF"
  ok "Backend set to: $b"

  case "$b" in
    keychain) dim "Secrets live in your login keychain, unlocked by your macOS login." ;;
    age)      dim "Secrets live encrypted at $AGE_FILE. You are asked for the passphrase once per run." ;;
    op)       dim "Secrets live in the '$OP_VAULT' 1Password vault." ;;
    plain)    warn "Plaintext. Anything running as your user can read these. Fix this when you can." ;;
  esac

  say ""
  if [ -f "$PLAIN_FILE" ] && [ "$b" != plain ]; then
    say "Found an existing plaintext key file. Import it now with:"
    say "  ${C_B}./vault.sh --import${C_RST}"
  else
    say "Add secrets one at a time:"
    say "  ${C_B}./vault.sh --set OPENROUTER_API_KEY${C_RST}"
    dim "Or run the guided wizard:  ./keys.sh --setup"
  fi
}

# ---------------------------------------------------------------- status
do_status() {
  hdr "Vault status"
  local b n
  b="$(backend)"
  if [ "$b" = none ]; then
    bad "No vault initialised. Keys are plaintext or absent."
    fix "./vault.sh --init"
  else
    case "$b" in
      plain) warn "Backend: plain (mode 600 file, NOT encrypted)" ;;
      *)     ok   "Backend: $b" ;;
    esac
    n="$(vb_list | grep -c . 2>/dev/null || echo 0)"
    ok "$n secret(s) stored"
  fi

  say ""
  if [ -f "$PLAIN_FILE" ] && [ "$b" != plain ]; then
    bad "Plaintext key file still present: $PLAIN_FILE"
    fix "./vault.sh --import   (imports then securely deletes it)"
  fi
  dim "Run ./vault.sh --audit for a full plaintext exposure report."
}

# ---------------------------------------------------------------- set / rm / list
do_set() {
  [ -n "$ARG" ] || die "Usage: ./vault.sh --set KEY_NAME"
  [ "$(backend)" = none ] && die "No vault. Run ./vault.sh --init first."
  case "$ARG" in
    ANTHROPIC_API_KEY) die "Refused. The Claude tab uses 'claude login'. Setting this key breaks it." ;;
  esac
  local v
  v="$(read_secret "Value for $ARG (input hidden): ")"
  [ -z "$v" ] && die "Nothing entered."
  printf '%s' "$v" | vb_set "$ARG" && ok "Stored $ARG in $(backend)" || bad "Failed to store $ARG"
  unset v
  say ""
  dim "Now write it out to where the tabs read it:  ./keys.sh --apply"
}

do_rm() {
  [ -n "$ARG" ] || die "Usage: ./vault.sh --rm KEY_NAME"
  vb_rm "$ARG" && ok "Removed $ARG from $(backend)"
  warn "This does NOT remove it from destination files. Run ./vault.sh --purge for that."
}

do_list() {
  hdr "Stored secrets  (names only, never values)"
  local n found=0
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    ok "$n"; found=1
  done <<EOF
$(vb_list)
EOF
  [ "$found" = 0 ] && info "No secrets stored yet."
}

# ---------------------------------------------------------------- import
do_import() {
  [ "$(backend)" = none ] && die "No vault. Run ./vault.sh --init first."
  [ "$(backend)" = plain ] && die "Backend is 'plain', so there is nothing to import into."
  [ -f "$PLAIN_FILE" ] || { ok "No plaintext file to import."; return 0; }

  hdr "Importing $PLAIN_FILE"
  local n v line count=0
  while IFS= read -r line; do
    case "$line" in \#*|"") continue ;; esac
    n="${line%%=*}"; v="${line#*=}"
    n="$(printf '%s' "$n" | tr -d ' ')"
    v="$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')"
    [ -z "$n" ] || [ -z "$v" ] && continue
    case "$n" in ANTHROPIC_API_KEY) warn "Skipping ANTHROPIC_API_KEY (blocked by design)"; continue ;; esac
    printf '%s' "$v" | vb_set "$n" && { ok "imported $n"; count=$((count+1)); }
  done < "$PLAIN_FILE"

  say ""
  ok "$count secret(s) imported into $(backend)"
  say ""
  warn "The plaintext file still exists and should now be destroyed."
  printf 'Securely delete %s ? [y/N] ' "$PLAIN_FILE"
  read -r a
  case "$a" in
    y|Y|yes|YES)
      if have shred; then shred -u "$PLAIN_FILE" 2>/dev/null
      elif [ "$PLATFORM" = macos ]; then rm -P "$PLAIN_FILE" 2>/dev/null || rm -f "$PLAIN_FILE"
      else rm -f "$PLAIN_FILE"; fi
      [ -f "$PLAIN_FILE" ] && bad "Could not delete it, remove by hand" || ok "Deleted"
      dim "Note: backups (Time Machine, cloud sync) may still hold older plaintext copies."
      ;;
    *) warn "Left in place. Your keys remain readable by anything running as you." ;;
  esac
}

# ---------------------------------------------------------------- audit
do_audit() {
  hdr "Plaintext exposure audit"
  dim "Where API keys can currently be read on this machine, in the clear."
  local issues=0 f p hits g

  # 1. destination files (these MUST be plaintext, but should be locked down)
  # A pipe creates a subshell, so a counter incremented inside it is lost. Build the
  # list first, then loop in this shell.
  say ""
  say "Destination files (plaintext by necessity, the tabs read them directly):"
  local existing; existing="$(printf '%s\n' "$DEST_FILES" | while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
    done)"
  if [ -n "$existing" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      p="$(file_mode "$f")"
      if [ "$p" = 600 ]; then
        ok "$(printf '%-52s mode %s' "${f/#$HOME/~}" "$p")"
      else
        bad "$(printf '%-52s mode %s  TOO OPEN' "${f/#$HOME/~}" "$p")"
        fix "chmod 600 '$f'"
        issues=$((issues+1))
      fi
    done <<EOF
$existing
EOF
  else
    info "No destination files written yet"
  fi

  # 2. the master plaintext file
  say ""
  if [ -f "$PLAIN_FILE" ]; then
    if [ "$(backend)" = plain ]; then
      warn "Master file is plaintext by choice: $PLAIN_FILE"
      fix "install age or use keychain, then: ./vault.sh --init && ./vault.sh --import"
    else
      bad "Master plaintext file still present despite a vault being configured"
      fix "./vault.sh --import"
    fi
    issues=$((issues+1))
  else
    ok "No plaintext master file"
  fi

  # 3. shell history
  say ""
  for f in "$HOME/.bash_history" "$HOME/.zsh_history"; do
    [ -f "$f" ] || continue
    hits=$(grep -cE '(sk-[A-Za-z0-9_-]{16,}|sk-or-v1-|xi-api-key|API_KEY=[A-Za-z0-9_-]{12,})' "$f" 2>/dev/null || echo 0)
    if [ "${hits:-0}" -gt 0 ]; then
      bad "$hits possible secret(s) in ${f/#$HOME/~}"
      fix "review and remove those lines, then: history -c"
      issues=$((issues+1))
    else
      ok "No secrets found in ${f/#$HOME/~}"
    fi
  done

  # 4. git exposure
  say ""
  for f in "$HOME/.hermes/profiles/main/.env" "$HOME/open-seo/.env" "$HOME/.fcc/.env"; do
    [ -f "$f" ] || continue
    g="$(cd "$(dirname "$f")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
    [ -z "$g" ] && continue
    if (cd "$(dirname "$f")" && git check-ignore -q "$(basename "$f")" 2>/dev/null); then
      ok "${f/#$HOME/~} is inside a git repo but gitignored"
    else
      bad "${f/#$HOME/~} is inside git repo $g and NOT ignored"
      fix "echo '$(basename "$f")' >> '$g/.gitignore'"
      issues=$((issues+1))
    fi
  done

  # 5. environment leakage
  say ""
  if [ -n "${OPENROUTER_API_KEY:-}${OPENAI_API_KEY:-}${ELEVENLABS_API_KEY:-}" ]; then
    warn "API keys are exported in this shell. Every child process inherits them,"
    warn "including any AI agent you launch from here."
    issues=$((issues+1))
  else
    ok "No API keys exported in this shell"
  fi
  if [ -z "${ANTHROPIC_API_KEY+x}" ]; then
    ok "ANTHROPIC_API_KEY not set (correct)"
  else
    bad "ANTHROPIC_API_KEY is set. This overrides 'claude login' and breaks the Claude tab."
    issues=$((issues+1))
  fi

  say ""
  if [ -f "$STATE_DIR/session-open" ]; then
    warn "A key session has been open since $(cat "$STATE_DIR/session-open")."
    dim "  Keys are currently written to their destination files in plaintext."
    dim "  Close it when you finish working:  ./vault.sh --session-end"
  fi
  say ""
  if [ "$issues" = 0 ]; then
    ok "No plaintext exposure issues found."
  else
    bad "$issues issue(s). Each has a fix line above."
  fi
  say ""
  dim "Remember: destination files must stay plaintext because the tools read them"
  dim "directly. A vault protects the master copy. See SECURITY.md."
  [ "$issues" = 0 ]
}

# ---------------------------------------------------------------- purge
strip_keys_from() { # strip_keys_from <file>  - env or json, preserves everything else
  local f="$1"
  [ -f "$f" ] || return 0
  case "$f" in
    *.json)
      node -e '
        const fs=require("fs"); const f=process.argv[1];
        try{ const d=JSON.parse(fs.readFileSync(f,"utf8")||"{}");
          for (const k of Object.keys(d)) if (/key$/i.test(k)) delete d[k];
          fs.writeFileSync(f, JSON.stringify(d,null,2)+"\n");
        }catch(e){}
      ' "$f" 2>/dev/null ;;
    *)
      grep -vE '^[[:space:]]*[A-Z_]*(API_KEY|PASSWORD|LOGIN|USER)=' "$f" > "$f.tmp" 2>/dev/null || true
      mv "$f.tmp" "$f" ;;
  esac
  chmod 600 "$f" 2>/dev/null
}

do_purge_quiet() {
  local f removed=0
  printf '%s\n' "$DEST_FILES" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    strip_keys_from "$f"
    ok "stripped ${f/#$HOME/~}"
  done
  strip_keys_from "$HOME/.agentic-os/outreach/config.json"
  return 0
}

do_purge() {
  hdr "Purge keys from destination files"
  say "Removes API key lines from the files the tabs read, leaving other settings intact."
  say "Use this when stepping away, handing the machine over, or before a backup."
  say ""
  warn "Tabs that need those keys will stop working until you run ./keys.sh --apply again."
  printf 'Proceed? [y/N] '
  read -r a
  case "$a" in y|Y|yes|YES) ;; *) info "Cancelled"; return 0 ;; esac
  do_purge_quiet
  say ""
  ok "Purged. Restore with: ./keys.sh --apply"
}

# ---------------------------------------------------------------- session mode
# The destination files CANNOT be encrypted, because Hermes and the rest read them
# directly and have no vault support. What can be reduced is how long they exist.
# That turns "plaintext on disk permanently" into "plaintext while you are working",
# which is a meaningful reduction and not a fix. See SECURITY.md.
do_session_start() {
  hdr "Session start"
  "$SCRIPT_DIR/keys.sh" --apply || return 1
  mkdir -p "$STATE_DIR"; date '+%Y-%m-%d %H:%M' > "$STATE_DIR/session-open"
  say ""
  ok "Keys written. Tabs will work until you end the session."
  dim "When you finish:  ./vault.sh --session-end"
}
do_session_end() {
  hdr "Session end"
  do_purge_quiet
  rm -f "$STATE_DIR/session-open"
  say ""
  ok "Keys stripped from destination files. The vault still holds them."
  dim "Start again with:  ./vault.sh --session-start"
}

# ---------------------------------------------------------------- programmatic
# Used by keys.sh. Prints values raw and nothing else, so they are never logged.
if [ "$MODE" = getq ]; then vb_get "$ARG"; exit 0; fi

# Bulk read: one decrypt instead of N. Without this an age vault asks for the
# passphrase once per key, which for a fifteen-key status check is fifteen prompts.
if [ "$MODE" = dump ]; then
  case "$(backend)" in
    age)      age_read ;;
    plain)    [ -f "$PLAIN_FILE" ] && grep -E '^[[:space:]]*[A-Z_]+=' "$PLAIN_FILE" ;;
    keychain|op)
      while IFS= read -r n; do
        [ -z "$n" ] && continue
        printf '%s=%s\n' "$n" "$(vb_get "$n")"
      done <<EOF
$(vb_list)
EOF
      ;;
  esac
  exit 0
fi

if [ "$MODE" = setstdin ]; then
  case "$ARG" in ANTHROPIC_API_KEY) exit 1 ;; esac
  vb_set "$ARG"; exit $?
fi

case "$MODE" in
  init) do_init ;;
  status) do_status ;;
  set) do_set ;;
  rm) do_rm ;;
  list) do_list ;;
  import) do_import ;;
  audit) do_audit ;;
  purge) do_purge ;;
  sesstart) do_session_start ;;
  sessend) do_session_end ;;
esac
