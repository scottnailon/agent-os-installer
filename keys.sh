#!/usr/bin/env bash
# keys.sh - one place to manage every Agent OS API key.
#
# Agent OS scatters keys across eight locations in three formats. This gives you one
# file to edit, then fans the values out to wherever each tab actually reads them.
#
#   ./keys.sh --init     create ~/.agent-os-keys.env, a commented template
#   ./keys.sh --list     what each key costs, unlocks, and where to get it
#   ./keys.sh --status   which keys you have set, masked  (default)
#   ./keys.sh --apply    write your keys out to every destination file
#   ./keys.sh --check    call each provider to confirm the key actually works
#   ./keys.sh --where    show every destination path for every key
#   ./keys.sh --tier core|useful|optional|skip     filter --list
#
# Your master file lives at ~/.agent-os-keys.env, OUTSIDE the app folder, so it
# survives pack updates. Mode 600. It is never printed in full, never committed,
# and never sent anywhere.
#
# This script will never enter your card details or log in on your behalf.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MASTER="$HOME/.agent-os-keys.env"
MANIFEST="$SCRIPT_DIR/keys.json"
[ -f "$MANIFEST" ] || die "keys.json not found next to this script"
have node || die "node is required (it parses the manifest). Run ./install.sh --stage 0 first."

MODE="status"; TIER=""; WANT_ALL=0; ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --init) MODE=init; shift ;;
    --setup|--wizard) MODE=setup; shift ;;
    --all) WANT_ALL=1; shift ;;
    --list) MODE=list; shift ;;
    --status) MODE=status; shift ;;
    --apply) MODE=apply; shift ;;
    --check) MODE=check; shift ;;
    --where) MODE=where; shift ;;
    --discover) MODE=discover; shift ;;
    --tier) TIER="$2"; shift 2 ;;
    --names) MODE=names; shift ;;
    --has) MODE=has; ARG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) warn "unknown option: $1"; shift ;;
  esac
done

# q <jsonpath-ish query> - small node helper emitting TSV
q() { node -e "$1" "$MANIFEST" "${2:-}" "${3:-}" 2>/dev/null; }

# All key metadata in ONE node call, cached for the process. Previously every field
# lookup spawned a fresh node, which made a status read take over a second.
# NOTE: field() is called inside $( ), a subshell, so prime_meta MUST run in the parent
# first or the cache is rebuilt and discarded on every single lookup.
META=""
prime_meta() {
  [ -n "$META" ] && return 0
  META="$(node -e '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const j=v=>Array.isArray(v)?v.join(", "):String(v??"");
    for(const k of m.keys){
      console.log([k.id,k.tier,k.label,k.cost,j(k.unlocks),j(k.url),
                   j(k.cost_detail).replace(/\t/g," "),j(k.note).replace(/\t/g," ")].join("\t"));
    }
  ' "$MANIFEST" 2>/dev/null)"
}
meta_col() { # meta_col <id> <1-based column>
  prime_meta
  printf '%s\n' "$META" | awk -F'\t' -v id="$1" -v c="$2" '$1==id{print $c; exit}'
}

ids_for_tier() {
  prime_meta
  printf '%s\n' "$META" | awk -F'\t' -v t="${TIER:-}" '(t==""||$2==t){print $1}'
}

field() { # field <id> <name>  - served from the cached table, no process spawn
  case "$2" in
    tier)        meta_col "$1" 2 ;;
    label)       meta_col "$1" 3 ;;
    cost)        meta_col "$1" 4 ;;
    unlocks)     meta_col "$1" 5 ;;
    url)         meta_col "$1" 6 ;;
    cost_detail) meta_col "$1" 7 ;;
    note)        meta_col "$1" 8 ;;
    *) q '
         const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
         const k=m.keys.find(x=>x.id===process.argv[2]);
         if(!k) process.exit(0);
         const v=k[process.argv[3]];
         process.stdout.write(Array.isArray(v)?v.join(", "):String(v??""));
       ' "$1" "$2" ;;
  esac
}

mask() { # never show a whole key
  local v="$1" n=${#1}
  if [ "$n" -le 12 ]; then printf '%s' "****"; else printf '%s...%s' "${v:0:6}" "${v: -4}"; fi
}

is_placeholder() { # a value the user has not really filled in
  case "$1" in
    your_*|YOUR_*|xxx*|XXX*|sk-xxxx*|paste_*|PASTE_*|changeme*|CHANGEME*|\<*\>) return 0 ;;
    *) return 1 ;;
  esac
}

# Source of truth: the vault if one is initialised, otherwise the plaintext file.
VAULT_SH="$SCRIPT_DIR/vault.sh"
VAULT_BACKEND="none"
[ -f "$HOME/.agent-os-vault/backend" ] && VAULT_BACKEND="$(cat "$HOME/.agent-os-vault/backend")"

# Backends that prompt or make a network call per read are dumped ONCE per run and held
# in memory. Without this, an age vault asks for the passphrase once per key, which for a
# fifteen-key status check is fifteen prompts.
VAULT_CACHE=""
VAULT_CACHED=0
prime_cache() {
  [ "$VAULT_CACHED" = 1 ] && return 0
  case "$VAULT_BACKEND" in
    age|op) VAULT_CACHE="$("$VAULT_SH" --dump 2>/dev/null)" ;;
    *) return 0 ;;
  esac
  VAULT_CACHED=1
}

read_master() { # read_master KEY -> value
  # NOTE: callers run this inside $( ), a subshell. prime_cache MUST have been called
  # in the parent already, or every read is a fresh decrypt.
  case "$VAULT_BACKEND" in
    age|op)
      printf '%s\n' "$VAULT_CACHE" | grep -E "^$1=" | tail -1 | cut -d= -f2-
      return ;;
  esac
  if [ "$VAULT_BACKEND" != none ] && [ "$VAULT_BACKEND" != plain ] && [ -x "$VAULT_SH" ]; then
    "$VAULT_SH" --get-quiet "$1" 2>/dev/null
    return
  fi
  [ -f "$MASTER" ] || { echo ""; return; }
  grep -E "^[[:space:]]*$1=" "$MASTER" 2>/dev/null | tail -1 | cut -d= -f2- \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

dest_confidence() { # dest_confidence <id> <expanded-path>
  q '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const k=m.keys.find(x=>x.id===process.argv[2]);
    const home=process.env.HOME||"";
    const d=(k?.destinations||[]).find(d=>d.path.replace("~",home)===process.argv[3]);
    process.stdout.write(d?d.confidence:"unknown");
  ' "$1" "$2"
}

source_label() {
  case "$VAULT_BACKEND" in
    none|plain) printf '%s' "$MASTER (plaintext)" ;;
    *) printf 'vault: %s' "$VAULT_BACKEND" ;;
  esac
}

# ============================================================ init
do_init() {
  if [ -f "$MASTER" ]; then
    ok "Master key file already exists: $MASTER"
    dim "Open it in any editor and fill in the keys you want. Then: ./keys.sh --apply"
    return 0
  fi
  info "Creating $MASTER"
  {
    echo "# Agent OS master key file"
    echo "# Edit this ONE file, then run: ./keys.sh --apply"
    echo "#"
    echo "# Leave a line blank or commented to skip that key. Nothing breaks."
    echo "# NEVER add ANTHROPIC_API_KEY here. The Claude tab uses 'claude login'."
    echo "# Format: KEY=value   (no quotes, no spaces around the =)"
    echo ""
    node -e '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const order=["core","useful","optional","skip"];
      for(const t of order){
        const ks=m.keys.filter(k=>k.tier===t);
        if(!ks.length) continue;
        console.log("# ".padEnd(74,"-"));
        console.log("# "+t.toUpperCase()+"  "+m.tiers[t]);
        console.log("# ".padEnd(74,"-"));
        for(const k of ks){
          console.log("");
          console.log("# "+k.label+"   ["+k.cost+"]");
          console.log("#   get it: "+k.url);
          console.log("#   unlocks: "+(k.unlocks||[]).join(", "));
          if(k.note) console.log("#   note: "+k.note.replace(/\n/g," "));
          console.log("# "+k.id+"=");
        }
        console.log("");
      }
    ' "$MANIFEST"
  } > "$MASTER"
  chmod 600 "$MASTER"
  ok "Created $MASTER (mode 600)"
  say ""
  say "Next: open it, uncomment the keys you want, paste the values, then:"
  say "  ${C_B}./keys.sh --apply${C_RST}"
}

# ============================================================ list
do_list() {
  prime_meta
  hdr "What each key costs and unlocks"
  node -e '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const t=process.argv[2]||"";
    const order=["core","useful","optional","skip"];
    for(const tier of order){
      if(t && tier!==t) continue;
      const ks=m.keys.filter(k=>k.tier===tier);
      if(!ks.length) continue;
      console.log("\n"+tier.toUpperCase()+" - "+m.tiers[tier]+"\n");
      for(const k of ks){
        console.log("  "+k.id);
        console.log("     "+k.label+"   ["+k.cost+"]");
        console.log("     get it:  "+k.url);
        console.log("     unlocks: "+(k.unlocks||[]).join(", "));
        if(k.cost_detail) console.log("     cost:    "+k.cost_detail);
        if(k.note)        console.log("     note:    "+k.note);
        console.log("");
      }
    }
  ' "$MANIFEST" "$TIER"

  hdr "Needs no key at all"
  node -e '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    m.no_key_needed.forEach(x=>console.log("  "+x.what.padEnd(34)+x.note));
  ' "$MANIFEST"

  hdr "Blocked on purpose"
  node -e '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    m.blocked.forEach(b=>{console.log("  "+b.id);console.log("     "+b.why);console.log("     instead: "+b.instead);});
  ' "$MANIFEST"
}

# ============================================================ status
do_status() {
  prime_meta
  prime_cache
  if [ ! -f "$MASTER" ] && { [ "$VAULT_BACKEND" = none ] || [ "$VAULT_BACKEND" = plain ]; }; then
    warn "No key store yet."
    fix "./vault.sh --init   (adds encryption + audit)   or   ./keys.sh --init   (plain file)"
    return 1
  fi
  hdr "Key status  [$(source_label)]"
  local id v tier set_count=0 miss_core=""
  for id in $(ids_for_tier); do
    v="$(read_master "$id")"
    tier="$(field "$id" tier)"
    if [ -n "$v" ] && is_placeholder "$v"; then
      warn "$(printf '%-22s %-10s placeholder, not filled in' "$id" "[$tier]")"
    elif [ -n "$v" ]; then
      ok "$(printf '%-22s %-10s %s' "$id" "[$tier]" "$(mask "$v")")"
      set_count=$((set_count+1))
    elif [ "$tier" = core ]; then
      bad "$(printf '%-22s %-10s not set' "$id" "[$tier]")"
      fix "$(field "$id" url)"
      miss_core="$miss_core $id"
    else
      info "$(printf '%-22s %-10s not set  (%s)' "$id" "[$tier]" "$(field "$id" unlocks)")"
    fi
  done
  say ""
  dim "$set_count key(s) set. Unset keys simply leave their tab quiet, nothing breaks."
  [ -n "$miss_core" ] && { say ""; warn "Missing core:$miss_core"; }
  say ""
  dim "./keys.sh --apply to write them out, --check to confirm they work."
}

# ============================================================ where
do_where() {
  prime_meta
  hdr "Where each key gets written"
  dim "This is the scatter the master file exists to hide."
  node -e '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    for(const k of m.keys){
      console.log("\n  "+k.id+"  ["+k.tier+"]");
      (k.destinations||[]).forEach(d=>{
        console.log("     -> "+d.path+"   ("+d.format+", "+d.confidence+")");
      });
    }
    console.log("\n  inferred = follows the pack convention but is not documented.");
    console.log("  Check that tab after applying.\n");
  ' "$MANIFEST"
}

# ============================================================ discover
# Inferred destinations are guesses. Rather than leave them guesses, read the truth off
# the installed pack: find where each key name actually appears in the source, and in the
# config files of the tools themselves. Turns "inferred" into evidence, on YOUR machine.
do_discover() {
  prime_meta
  hdr "Discovering real key destinations"
  say "Reads the installed Agent OS source and your tool configs to find where each key"
  say "name is actually referenced. Nothing is written unless you ask."
  say ""

  local app root
  app="$(find_app_dir)"
  if [ -z "$app" ]; then
    bad "Agent OS source not found."
    fix "run this from inside the unzipped pack folder, or pass --app-dir"
    return 1
  fi
  root="${app%/source}"
  ok "Scanning $root"
  say ""

  local SELF_DIR_NAME; SELF_DIR_NAME="$(basename "$SCRIPT_DIR")"
  local id conf declared found hits changed=0 report="$STATE_DIR/discovered-paths.txt"
  mkdir -p "$STATE_DIR"; : > "$report"

  for id in $(ids_for_tier); do
    declared="$(q '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const k=m.keys.find(x=>x.id===process.argv[2]);
      (k?.destinations||[]).forEach(d=>console.log(d.path+"|"+d.confidence));
    ' "$id")"
    [ -z "$declared" ] && continue
    conf="$(printf '%s' "$declared" | head -1 | cut -d'|' -f2)"
    [ "$conf" = verified ] && continue

    # Where does the source actually reference this key name?
    # Exclude our own folder. Without this, discovery finds THIS toolkit's files and
    # reports our own filenames back as if they were the pack's truth.
    hits="$(grep -rl --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=.git \
             --exclude-dir="$SELF_DIR_NAME" \
             -e "$id" "$root" 2>/dev/null | head -6)"
    if [ -z "$hits" ]; then
      warn "$(printf '%-22s not referenced anywhere in the pack' "$id")"
      dim "                       that tab may not exist in your pack version"
      printf '%s\tNOT_REFERENCED\n' "$id" >> "$report"
      continue
    fi

    # Pull any env-file path mentioned near the key name.
    found="$(grep -rhoE --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=.git \
              --exclude-dir="$SELF_DIR_NAME" \
              "[~a-zA-Z0-9_./-]*\.env[a-zA-Z0-9_.-]*" $hits 2>/dev/null \
              | sort -u | head -4 | tr '\n' ' ')"
    ok "$(printf '%-22s referenced in %s file(s)' "$id" "$(printf '%s\n' "$hits" | grep -c .)")"
    printf '%s\treferenced_in=%s\tenv_paths=%s\n' "$id" "$(printf '%s' "$hits" | tr '\n' ',')" "$found" >> "$report"
    [ -n "$found" ] && dim "                       env paths seen nearby: $found"
    changed=$((changed+1))
  done

  say ""
  ok "Report written to $report"
  say ""
  if [ "$changed" = 0 ]; then
    info "Nothing new discovered. The inferred paths remain unconfirmed."
  else
    say "For each key above, compare the paths found against what keys.json declares:"
    say "  ${C_B}./keys.sh --where${C_RST}"
    say ""
    say "If a path differs, correct it in keys.json so future runs are right, then:"
    say "  ${C_B}./keys.sh --apply${C_RST}"
  fi
  say ""
  dim "This reads only. It never edits keys.json for you, because a wrong automatic"
  dim "correction would be harder to spot than a wrong guess you were warned about."
}

# ============================================================ apply
write_json_kv() { # write_json_kv <file> <field> <value>  - merges, never clobbers
  local f="$1" n="$2" v="$3"
  mkdir -p "$(dirname "$f")" 2>/dev/null || { bad "Cannot create $(dirname "$f")"; return 1; }
  node -e '
    const fs=require("fs");
    const [f,k,v]=process.argv.slice(1);
    let d={}; try{ if(fs.existsSync(f)) d=JSON.parse(fs.readFileSync(f,"utf8")||"{}"); }catch(e){ d={}; }
    d[k]=v;
    fs.writeFileSync(f, JSON.stringify(d,null,2)+"\n");
  ' "$f" "$n" "$v" || return 1
  chmod 600 "$f" 2>/dev/null || true
}

write_env_kv() { # write_env_kv <file> <name> <value>
  local f="$1" n="$2" v="$3" dir
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || { bad "Cannot create $dir"; return 1; }
  touch "$f" 2>/dev/null || { bad "Cannot write $f"; return 1; }
  # preserve everything except an existing line for this name
  grep -vE "^[[:space:]]*$n=" "$f" > "$f.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$n" "$v" >> "$f.tmp"
  mv "$f.tmp" "$f"
  chmod 600 "$f" 2>/dev/null || true
}

do_apply() {
  prime_meta
  # Resolve the Hermes profile the dashboard is actually using.
  HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
  HERMES_ACTIVE="$(cat "$HERMES_HOME_DIR/active_profile" 2>/dev/null | tr -d '[:space:]')"
  HERMES_ACTIVE="${HERMES_ACTIVE:-main}"
  [ "$HERMES_ACTIVE" != main ] && info "Active Hermes profile is '$HERMES_ACTIVE', writing there instead of 'main'"
  prime_cache
  if [ ! -f "$MASTER" ] && { [ "$VAULT_BACKEND" = none ] || [ "$VAULT_BACKEND" = plain ]; }; then
    bad "No key store. Run ./vault.sh --init (encrypted) or ./keys.sh --init (plaintext)."
    return 1
  fi
  hdr "Applying keys  [source: $(source_label)]"

  local id v n applied=0 skipped=0 line path fmt inferred_hits="" env_only_hits=""
  for id in $(ids_for_tier); do
    v="$(read_master "$id")"
    if [ -z "$v" ]; then skipped=$((skipped+1)); continue; fi

    if is_placeholder "$v"; then
      warn "$id still looks like a placeholder ('$v'). Skipping."
      continue
    fi

    while IFS='|' read -r path fmt n; do
      [ -z "$path" ] && continue
      path="${path/#\~/$HOME}"
      # The dashboard reads ~/.hermes/active_profile and falls back to "main".
      # Honour it, or keys land in a profile nothing is using.
      case "$path" in
        */.hermes/profiles/main/*)
          if [ -n "$HERMES_ACTIVE" ] && [ "$HERMES_ACTIVE" != main ]; then
            path="${path//\/profiles\/main\//\/profiles\/$HERMES_ACTIVE\/}"
          fi ;;
      esac
      if [ "$fmt" = env-only ]; then
        warn "$id  reads from the ENVIRONMENT only, no file"
        env_only_hits="$env_only_hits\n    export $n=...   # before starting the dashboard"
        continue
      fi
      if [ "$fmt" = json ]; then
        if write_json_kv "$path" "$n" "$v"; then
          if node -e 'const d=require(process.argv[1]);process.exit(d[process.argv[2]]?0:1)' "$path" "$n" 2>/dev/null; then
            ok "$id -> $path  (field: $n)"
            applied=$((applied+1))
          else
            bad "$id -> $path  WRITE DID NOT LAND"
          fi
        fi
        continue
      fi
      if [ "$fmt" = env ]; then
        if write_env_kv "$path" "$n" "$v"; then
          # Confirm the value actually landed. A silent write failure is worse than a
          # loud one, because the tab stays broken while the report says success.
          if grep -qE "^$n=" "$path" 2>/dev/null; then
            local conf; conf="$(dest_confidence "$id" "$path")"
            if [ "$conf" = inferred ]; then
              warn "$id -> $path  (path INFERRED, verify in the tab)"
              inferred_hits="$inferred_hits\n    $id  ->  $path"
            else
              ok "$id -> $path"
            fi
            applied=$((applied+1))
          else
            bad "$id -> $path  WRITE DID NOT LAND"
            fix "check permissions on $(dirname "$path")"
          fi
        fi
      else
        warn "$id has an unsupported destination format '$fmt'. Set it in the tab UI instead."
      fi
    done <<EOF
$(q '
  const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const k=m.keys.find(x=>x.id===process.argv[2]);
  (k?.destinations||[]).forEach(d=>console.log([d.path,d.format,d.name].join("|")));
' "$id")
EOF
  done

  # The trap check, every time.
  local app envl
  app="$(find_app_dir)"
  if [ -n "$app" ]; then
    for envl in "$app/.env.local" "$app/.env"; do
      [ -f "$envl" ] && grep -qE '^ANTHROPIC_API_KEY=[[:space:]]*$' "$envl" 2>/dev/null && {
        bad "Empty ANTHROPIC_API_KEY still present in $envl"
        fix "./install.sh --fix-claude-tab"
      }
    done
  fi

  say ""
  ok "$applied destination(s) written, $skipped key(s) left unset."
  if [ -n "$env_only_hits" ]; then
    say ""
    warn "These keys are read from the environment only. The dashboard consults no file"
    warn "for them, so they must be exported before it starts:"
    printf '%b\n' "$env_only_hits"
    dim "Add those to your shell profile, or to the terminal you launch the dashboard from."
  fi
  if [ -n "$inferred_hits" ]; then
    say ""
    warn "Some destinations are INFERRED, meaning the path follows the pack's convention"
    warn "but is not documented. If one is wrong, the file is written and nothing reads it."
    printf '%b\n' "$inferred_hits"
    say ""
    dim "Open each of those tabs and confirm it sees the key. If a tab still says the key"
    dim "is missing, set it in that tab's own settings UI and the manifest needs correcting."
  fi
  dim "Restart the dashboard for the new keys to be picked up."
  say ""
  dim "Now confirm they actually work:  ./keys.sh --check"
}

# ============================================================ check
do_check() {
  prime_meta
  prime_cache
  if [ ! -f "$MASTER" ] && { [ "$VAULT_BACKEND" = none ] || [ "$VAULT_BACKEND" = plain ]; }; then
    bad "No key store. Run ./vault.sh --init or ./keys.sh --init."
    return 1
  fi
  have curl || die "curl is required for --check"
  hdr "Live key validation"
  dim "Calls each provider with your key. Read-only, no charges."

  local id v vtype vurl vheader vparam code fails=0
  for id in $(ids_for_tier); do
    v="$(read_master "$id")"
    [ -z "$v" ] && continue
    if is_placeholder "$v"; then
      warn "$(printf '%-22s placeholder, not a real key yet' "$id")"
      continue
    fi
    vtype=""  # resolved below
    vtype="$(q '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const k=m.keys.find(x=>x.id===process.argv[2]);
      if(!k||!k.verify){process.exit(0);}
      console.log([k.verify.type,k.verify.url,k.verify.header||"",k.verify.param||""].join("|"));
    ' "$id")"
    if [ -z "$vtype" ]; then
      info "$(printf '%-22s set, no validation endpoint available' "$id")"
      continue
    fi
    IFS='|' read -r vtype vurl vheader vparam <<EOF
$vtype
EOF

    code=""
    case "$vtype" in
      bearer) code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -H "Authorization: Bearer $v" "$vurl")" ;;
      header) code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -H "$vheader: $v" "$vurl")" ;;
      query)  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "$vurl?$vparam=$v")" ;;
      dataforseo)
        local pw; pw="$(read_master DATAFORSEO_PASSWORD)"
        [ -z "$pw" ] && { warn "$id set but DATAFORSEO_PASSWORD is not. Both are needed."; continue; }
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -u "$v:$pw" "$vurl")" ;;
      *) info "$id  unknown verify type"; continue ;;
    esac

    case "$code" in
      200|201) ok  "$(printf '%-22s valid  (HTTP %s)' "$id" "$code")" ;;
      401|403) bad "$(printf '%-22s REJECTED (HTTP %s) - wrong or revoked key' "$id" "$code")"; fails=$((fails+1)) ;;
      402)     bad "$(printf '%-22s NO CREDIT (HTTP 402) - key is valid, balance is empty' "$id")"; fails=$((fails+1)) ;;
      429)     warn "$(printf '%-22s rate limited (HTTP 429) - key is valid' "$id")" ;;
      000)     warn "$(printf '%-22s no response (network or provider down)' "$id")" ;;
      *)       warn "$(printf '%-22s unexpected HTTP %s' "$id" "$code")" ;;
    esac
  done

  say ""
  if [ "$fails" -gt 0 ]; then
    bad "$fails key(s) failed. Fix them in $MASTER then re-run --apply and --check."
    return 1
  fi
  ok "Every key that has a validation endpoint responded successfully."
}


# ============================================================ setup (guided)
SKIPFILE="$HOME/.agent-os-vault/never-ask"

never_asked() { [ -f "$SKIPFILE" ] && grep -qx "$1" "$SKIPFILE" 2>/dev/null; }
mark_never()  { mkdir -p "$(dirname "$SKIPFILE")"; printf '%s\n' "$1" >> "$SKIPFILE"; chmod 600 "$SKIPFILE"; }

store_key() { # store_key <id> <value>
  if [ "$VAULT_BACKEND" != none ] && [ "$VAULT_BACKEND" != plain ] && [ -x "$VAULT_SH" ]; then
    printf '%s' "$2" | "$VAULT_SH" --set-stdin "$1"
  else
    touch "$MASTER"; chmod 600 "$MASTER"
    grep -vE "^[[:space:]]*$1=" "$MASTER" > "$MASTER.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$1" "$2" >> "$MASTER.tmp"
    mv "$MASTER.tmp" "$MASTER"; chmod 600 "$MASTER"
  fi
}

validate_one() { # validate_one <id> <value> -> prints a verdict line
  local id="$1" v="$2" spec vtype vurl vheader vparam code pw
  spec="$(q '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const k=m.keys.find(x=>x.id===process.argv[2]);
    if(!k||!k.verify){process.exit(0);}
    console.log([k.verify.type,k.verify.url,k.verify.header||"",k.verify.param||""].join("|"));
  ' "$id")"
  [ -z "$spec" ] && { info "stored (no validation endpoint for this provider)"; return 0; }
  IFS='"'"'|'"'"' read -r vtype vurl vheader vparam <<EOF
$spec
EOF
  case "$vtype" in
    bearer) code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -H "Authorization: Bearer $v" "$vurl")" ;;
    header) code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -H "$vheader: $v" "$vurl")" ;;
    query)  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "$vurl?$vparam=$v")" ;;
    dataforseo)
      pw="$(read_master DATAFORSEO_PASSWORD)"
      [ -z "$pw" ] && { info "stored. Validates once DATAFORSEO_PASSWORD is added too."; return 0; }
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -u "$v:$pw" "$vurl")" ;;
    *) info "stored"; return 0 ;;
  esac
  case "$code" in
    200|201) ok "valid, confirmed with the provider" ;;
    401|403) bad "REJECTED by the provider. Check you copied the whole key."; return 1 ;;
    402)     warn "key is valid but the account has no credit" ;;
    429)     warn "key is valid but currently rate limited" ;;
    000)     warn "no response. Network or provider issue, key not verified." ;;
    *)       warn "unexpected HTTP $code" ;;
  esac
}

do_setup() {
  prime_meta
  prime_cache
  hdr "Guided key setup"
  say "One key at a time. For each, you get what it costs, what it unlocks, and where"
  say "to get it. Nothing is required. Skipping a key just leaves that tab quiet."
  say ""
  dim "Keys are typed hidden, stored in [$(source_label)], written to the files each tab"
  dim "reads, and validated against the provider immediately."
  say ""
  warn "You create every key yourself. This never enters a card or logs in for you."

  local id tier v label added=0 skipped=0
  for tier in core useful optional skip; do
    [ "$tier" = skip ] && [ "$WANT_ALL" != 1 ] && continue
    local ids; ids="$(q '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      m.keys.filter(k=>k.tier===process.argv[2]).forEach(k=>console.log(k.id));
    ' "$tier")"
    [ -z "$ids" ] && continue

    hdr "$(printf '%s' "$tier" | tr '[:lower:]' '[:upper:]')  $(q '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.stdout.write(m.tiers[process.argv[2]]||"");
    ' "$tier")"

    for id in $ids; do
      v="$(read_master "$id")"
      if [ -n "$v" ] && ! is_placeholder "$v"; then
        ok "$id already set"; continue
      fi
      never_asked "$id" && { info "$id skipped previously (in $SKIPFILE)"; continue; }

      label="$(field "$id" label)"
      say ""
      say "  ${C_B}$id${C_RST}"
      say "    $label   [$(field "$id" cost)]"
      say "    unlocks: $(field "$id" unlocks)"
      say "    get it:  $(field "$id" url)"
      local cd nt
      cd="$(field "$id" cost_detail)"; nt="$(field "$id" note)"
      [ -n "$cd" ] && dim "    cost:    $cd"
      [ -n "$nt" ] && dim "    note:    $nt"
      say ""
      printf '    %s[a]%s add now   %s[s]%s skip for now   %s[n]%s never ask   %s[q]%s stop here: ' \
        "$C_GRN" "$C_RST" "$C_DIM" "$C_RST" "$C_YEL" "$C_RST" "$C_DIM" "$C_RST"
      read -r choice
      case "$choice" in
        a|A)
          printf '    Paste %s (input hidden): ' "$id"
          stty -echo 2>/dev/null; IFS= read -r kv; stty echo 2>/dev/null; printf '\n'
          if [ -z "$kv" ]; then warn "    nothing entered, skipped"; skipped=$((skipped+1)); continue; fi
          if is_placeholder "$kv"; then warn "    that looks like a placeholder, skipped"; skipped=$((skipped+1)); continue; fi
          store_key "$id" "$kv"
          VAULT_CACHED=0; VAULT_CACHE=""
          VAULT_BACKEND="$VAULT_BACKEND"
          printf '    '; validate_one "$id" "$kv" || true
          unset kv
          added=$((added+1)) ;;
        n|N) mark_never "$id"; info "    will not ask again. Undo by editing $SKIPFILE"; skipped=$((skipped+1)) ;;
        q|Q) say ""; info "Stopped. Re-run ./keys.sh --setup any time to continue."; break 2 ;;
        *) skipped=$((skipped+1)) ;;
      esac
    done
  done

  say ""
  hdr "Writing keys out"
  do_apply
  say ""
  ok "$added key(s) added, $skipped skipped."
  dim "Add any skipped key later with:  ./keys.sh --setup   or   ./vault.sh --set KEY"
}

# Programmatic interfaces for other scripts in this toolkit. One vault read, no parsing
# of human-readable output, and on an age vault exactly one passphrase prompt.
if [ "$MODE" = names ]; then
  prime_meta; prime_cache
  for __id in $(ids_for_tier); do
    __v="$(read_master "$__id")"
    [ -n "$__v" ] && ! is_placeholder "$__v" && printf '%s\n' "$__id"
  done
  exit 0
fi
if [ "$MODE" = has ]; then
  prime_cache
  __v="$(read_master "$ARG")"
  [ -n "$__v" ] && ! is_placeholder "$__v" && exit 0
  exit 1
fi

case "$MODE" in
  init)   do_init ;;
  setup)  do_setup ;;
  list)   do_list ;;
  status) do_status ;;
  apply)  do_apply ;;
  check)  do_check ;;
  where)  do_where ;;
  discover) do_discover ;;
esac
