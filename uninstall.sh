#!/usr/bin/env bash
# uninstall.sh - remove what this toolkit created, in graduated stages.
#
#   ./uninstall.sh              show exactly what would be removed, remove nothing
#   ./uninstall.sh --scheduled  remove the cron entries only
#   ./uninstall.sh --state      also remove installer state, logs and backups
#   ./uninstall.sh --keys       also remove key files from their destinations
#   ./uninstall.sh --vault      also DESTROY the encrypted vault (keys are unrecoverable)
#   ./uninstall.sh --all        everything above, confirming each stage
#
# NEVER TOUCHED, at any level:
#   the Agent OS app itself       remove it by deleting its folder
#   your Obsidian vault           your notes are yours
#   Ollama, Hermes, Node, ffmpeg  installed by their own installers, remove those the same way
#   ~/.agentic-os/config.json     dashboard settings, not ours to delete
#
# Each stage asks separately. No single command destroys keys without confirmation.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
detect_platform

DO_SCHED=0; DO_STATE=0; DO_KEYS=0; DO_VAULT=0; DRY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --scheduled) DO_SCHED=1; DRY=0; shift ;;
    --state) DO_SCHED=1; DO_STATE=1; DRY=0; shift ;;
    --keys) DO_SCHED=1; DO_STATE=1; DO_KEYS=1; DRY=0; shift ;;
    --vault) DO_VAULT=1; DRY=0; shift ;;
    --all) DO_SCHED=1; DO_STATE=1; DO_KEYS=1; DO_VAULT=1; DRY=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

confirm() { printf '%s%s [y/N] %s' "$C_YEL" "$1" "$C_RST"; read -r a; case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }

DEST_FILES="
$HOME/.hermes/profiles/main/.env
$HOME/.claude/skills/youtube-thumbnails/.env
$HOME/open-seo/.env
$HOME/.agentic-os/heygen.env
$HOME/.agentic-os/suno.env
$HOME/.agentic-os/gemini.env
$HOME/.agentic-os/indexceptional.env
$HOME/.agentic-os/outreach/config.json
"

# ---------------------------------------------------------------- inventory
hdr "What this toolkit created"

say ""
say "Scheduled jobs:"
if have crontab && crontab -l 2>/dev/null | grep -qE '# agent-os-(plus|installer)'; then
  crontab -l 2>/dev/null | grep -E '# agent-os-(plus|installer)' | sed 's/^/  /'
else
  dim "  none"
fi

say ""
say "Installer state:"
if [ -d "$STATE_DIR" ]; then
  say "  $STATE_DIR  ($(du -sh "$STATE_DIR" 2>/dev/null | awk '{print $1}'))"
else
  dim "  none"
fi

say ""
say "Update backups:"
BAKS="$(find "$HOME" -maxdepth 3 -name '*.bak-*' -type d 2>/dev/null)"
[ -n "$BAKS" ] && printf '%s\n' "$BAKS" | sed 's/^/  /' || dim "  none"

say ""
say "Key files written to destinations:"
printf '%s\n' "$DEST_FILES" | while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] && say "  $f"
done

say ""
say "Encrypted vault:"
if [ -d "$HOME/.agent-os-vault" ]; then
  say "  $HOME/.agent-os-vault  (backend: $(cat "$HOME/.agent-os-vault/backend" 2>/dev/null || echo unknown))"
  case "$(cat "$HOME/.agent-os-vault/backend" 2>/dev/null)" in
    keychain) dim "  note: secrets live in the macOS Keychain, not in this folder" ;;
    op)       dim "  note: secrets live in 1Password, not in this folder" ;;
  esac
else
  dim "  none"
fi

say ""
say "Plaintext key file:"
[ -f "$HOME/.agent-os-keys.env" ] && say "  $HOME/.agent-os-keys.env" || dim "  none"

if [ "$DRY" = 1 ]; then
  say ""
  hdr "Nothing was removed"
  say "This was a dry run. To actually remove things, pick a level:"
  say ""
  say "  ./uninstall.sh --scheduled   cron entries only"
  say "  ./uninstall.sh --state       also state, logs and update backups"
  say "  ./uninstall.sh --keys        also key files in their destinations"
  say "  ./uninstall.sh --vault       also destroy the encrypted vault"
  say "  ./uninstall.sh --all         all of the above, confirming each"
  say ""
  dim "The Agent OS app, your Obsidian vault, and tools like Ollama and Hermes are never"
  dim "touched by any level. Remove those the way you installed them."
  exit 0
fi

# ---------------------------------------------------------------- removal
if [ "$DO_SCHED" = 1 ] && have crontab; then
  hdr "Scheduled jobs"
  if crontab -l 2>/dev/null | grep -qE '# agent-os-(plus|installer)'; then
    if confirm "Remove the cron entries?"; then
      crontab -l 2>/dev/null | grep -vE '# agent-os-(plus|installer)' | crontab -
      ok "Removed"
    fi
  else info "None to remove"; fi
fi

if [ "$DO_STATE" = 1 ]; then
  hdr "Installer state, logs and backups"
  if [ -d "$STATE_DIR" ] && confirm "Remove $STATE_DIR ?"; then
    rm -rf "$STATE_DIR"; ok "Removed"
  fi
  BAKS="$(find "$HOME" -maxdepth 3 -name '*.bak-*' -type d 2>/dev/null)"
  if [ -n "$BAKS" ]; then
    printf '%s\n' "$BAKS" | sed 's/^/  /'
    warn "These are rollback points for the Agent OS app."
    confirm "Delete them?" && printf '%s\n' "$BAKS" | while IFS= read -r b; do rm -rf "$b" && ok "removed $b"; done
  fi
fi

if [ "$DO_KEYS" = 1 ]; then
  hdr "Key files in their destinations"
  warn "Tabs using these keys will stop working."
  dim "Unrelated settings in the same files are preserved."
  if confirm "Strip API keys from destination files?"; then
    printf '%s\n' "$DEST_FILES" | while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ -f "$f" ] || continue
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
      ok "stripped $f"
    done
  fi
fi

if [ "$DO_VAULT" = 1 ]; then
  hdr "Encrypted vault"
  bad "This DESTROYS your stored keys. They cannot be recovered from here."
  say "You would have to fetch each one again from its provider."
  say ""
  printf '%sType DESTROY to confirm, anything else cancels: %s' "$C_RED" "$C_RST"
  read -r a
  if [ "$a" = "DESTROY" ]; then
    rm -rf "$HOME/.agent-os-vault"
    [ -f "$HOME/.agent-os-keys.env" ] && {
      if have shred; then shred -u "$HOME/.agent-os-keys.env" 2>/dev/null
      elif [ "$PLATFORM" = macos ]; then rm -P "$HOME/.agent-os-keys.env" 2>/dev/null || rm -f "$HOME/.agent-os-keys.env"
      else rm -f "$HOME/.agent-os-keys.env"; fi
    }
    ok "Vault destroyed"
    case "$(uname -s)" in
      Darwin) dim "If you used the Keychain backend, entries remain there. Remove them in Keychain Access, they are named agent-os:*" ;;
    esac
    dim "If you used 1Password, the items remain in that vault."
  else
    info "Cancelled. Vault untouched."
  fi
fi

say ""
hdr "Done"
say "Still present, and yours to remove separately if you want to:"
say "  the Agent OS app folder"
say "  ~/.agentic-os/config.json  (dashboard settings)"
say "  ~/.hermes/  (profiles and personas)"
say "  Ollama, Hermes, Node, ffmpeg and other tools"
say "  your Obsidian vault, including any Agentic OS/ folder inside it"
