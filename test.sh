#!/usr/bin/env bash
# test.sh - automated tests for the Agent OS installer toolkit.
#
#   ./test.sh              run everything
#   ./test.sh --verbose    show output from failing tests
#   ./test.sh --only NAME  run tests matching NAME
#
# Every test runs against a THROWAWAY HOME under /tmp, so your real config, vault, keys
# and cron are never touched. Nothing here talks to the network except the two tests
# explicitly marked as live, which are skipped if there is no connectivity.
#
# Run this after any change. The point is to be able to prove a fix did not break
# something else, which is the thing the pack this wraps cannot do.

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSE=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verbose|-v) VERBOSE=1; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; D=""; B=""; N=""; fi

PASS=0; FAIL=0; SKIP=0; FAILED_NAMES=""
SANDBOX=""

setup_sandbox() {
  SANDBOX="$(mktemp -d /tmp/aos-test.XXXXXX)"
  mkdir -p "$SANDBOX/home" "$SANDBOX/kit"
  cp "$SRC"/*.sh "$SRC"/*.json "$SRC"/*.ps1 "$SRC"/VERSION "$SRC"/LICENSE "$SRC"/*.md "$SANDBOX/kit/" 2>/dev/null
  cp "$SRC"/.gitignore "$SANDBOX/kit/" 2>/dev/null
  chmod +x "$SANDBOX/kit"/*.sh
  export HOME="$SANDBOX/home"
}
teardown_sandbox() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; SANDBOX=""; }

REAL_HOME="$HOME"

t() { # t <name> <function>
  [ -n "$ONLY" ] && case "$1" in *"$ONLY"*) ;; *) return 0 ;; esac
  local name="$1" fn="$2" out rc
  setup_sandbox
  out="$( "$fn" 2>&1 )"; rc=$?
  teardown_sandbox
  export HOME="$REAL_HOME"
  case $rc in
    0)  printf '%s  PASS%s  %s\n' "$G" "$N" "$name"; PASS=$((PASS+1)) ;;
    77) printf '%s  SKIP%s  %s  %s%s%s\n' "$Y" "$N" "$name" "$D" "$(printf '%s' "$out" | tail -1)" "$N"; SKIP=$((SKIP+1)) ;;
    *)  printf '%s  FAIL%s  %s\n' "$R" "$N" "$name"; FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  $name"
        [ "$VERBOSE" = 1 ] && printf '%s%s%s\n' "$D" "$out" "$N" ;;
  esac
}

assert()      { if ! eval "$1"; then echo "assertion failed: $1"; return 1; fi; }
assert_grep() { if ! printf '%s' "$2" | grep -qE "$1"; then echo "expected to match: $1"; echo "got: $2"; return 1; fi; }
assert_no()   { if printf '%s' "$2" | grep -qE "$1"; then echo "should NOT match: $1"; return 1; fi; }
K() { echo "$SANDBOX/kit"; }
online() { curl -fsS --max-time 5 https://openrouter.ai/api/v1/models >/dev/null 2>&1; }

# ============================================================ syntax
test_syntax() {
  local f
  for f in "$(K)"/*.sh; do bash -n "$f" || { echo "syntax error in $f"; return 1; }; done
}
test_json_valid() {
  local f
  for f in "$(K)"/*.json; do
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f" \
      || { echo "invalid JSON: $f"; return 1; }
  done
}

# ============================================================ routing gate
test_routing_catches_small_model_on_hermes() {
  mkdir -p "$HOME/.hermes/profiles/main"
  echo 'model: ollama/gemma2' > "$HOME/.hermes/profiles/main/config.yaml"
  local out; out="$(cd "$(K)" && bash -c '. ./lib.sh; detect_platform; gate_routing' 2>&1)"
  assert_grep "Hermes is pointed at" "$out"
}
test_routing_catches_stealth_model() {
  mkdir -p "$HOME/.fcc"
  echo 'MODEL="open_router/owl-alpha"' > "$HOME/.fcc/.env"
  local out; out="$(cd "$(K)" && bash -c '. ./lib.sh; detect_platform; gate_routing' 2>&1)"
  assert_grep "stealth/alpha" "$out"
}
test_routing_accepts_correct_config() {
  mkdir -p "$HOME/.fcc" "$HOME/.hermes/profiles/main"
  echo 'MODEL="ollama/gemma2"' > "$HOME/.fcc/.env"
  echo 'model: anthropic/claude-haiku-4.5' > "$HOME/.hermes/profiles/main/config.yaml"
  cd "$(K)" && bash -c '. ./lib.sh; detect_platform; gate_routing' >/dev/null 2>&1
}
test_routing_json_is_live_not_decorative() {
  # Adding a pattern to routing.json must change gate behaviour.
  node -e '
    const fs=require("fs"),f=process.argv[1];
    const r=JSON.parse(fs.readFileSync(f,"utf8"));
    r.rules.never_global_default.push("zzztestmodel");
    fs.writeFileSync(f,JSON.stringify(r,null,2));
  ' "$(K)/routing.json"
  mkdir -p "$HOME/.hermes/profiles/main"
  echo 'model: zzztestmodel-x' > "$HOME/.hermes/profiles/main/config.yaml"
  local out; out="$(cd "$(K)" && bash -c '. ./lib.sh; detect_platform; gate_routing' 2>&1)"
  assert_grep "zzztestmodel" "$out"
}

# ============================================================ claude tab trap
test_claude_trap_detected() {
  mkdir -p "$HOME/app"; echo '{}' > "$HOME/app/package.json"
  printf 'ANTHROPIC_API_KEY=\n' > "$HOME/app/.env.local"
  local out; out="$(cd "$(K)" && APP_DIR="$HOME/app" bash -c '. ./lib.sh; detect_platform; gate_routing' 2>&1)"
  assert_grep "Empty ANTHROPIC_API_KEY" "$out"
}
test_claude_trap_fixed_single_line() {
  mkdir -p "$HOME/app"; echo '{}' > "$HOME/app/package.json"
  printf 'ANTHROPIC_API_KEY=\n' > "$HOME/app/.env.local"
  ( cd "$(K)" && APP_DIR="$HOME/app" ./install.sh --fix-claude-tab >/dev/null 2>&1 )
  assert "! grep -qE '^ANTHROPIC_API_KEY=[[:space:]]*$' '$HOME/app/.env.local'"
}
test_claude_trap_fix_preserves_other_lines() {
  mkdir -p "$HOME/app"; echo '{}' > "$HOME/app/package.json"
  printf 'FOO=1\nANTHROPIC_API_KEY=\nBAR=2\n' > "$HOME/app/.env.local"
  ( cd "$(K)" && APP_DIR="$HOME/app" ./install.sh --fix-claude-tab >/dev/null 2>&1 )
  assert "grep -q '^FOO=1$' '$HOME/app/.env.local'" && \
  assert "grep -q '^BAR=2$' '$HOME/app/.env.local'"
}

# ============================================================ keys
test_keys_init_creates_template() {
  ( cd "$(K)" && ./keys.sh --init >/dev/null 2>&1 )
  assert "[ -f '$HOME/.agent-os-keys.env' ]" && \
  assert "[ \"\$(stat -c %a '$HOME/.agent-os-keys.env' 2>/dev/null || stat -f %A '$HOME/.agent-os-keys.env')\" = 600 ]"
}
test_keys_template_excludes_anthropic() {
  ( cd "$(K)" && ./keys.sh --init >/dev/null 2>&1 )
  assert "! grep -qE '^ANTHROPIC_API_KEY=' '$HOME/.agent-os-keys.env'"
}
test_keys_apply_fans_out() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-or-testvalue123\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  assert "grep -q 'sk-or-testvalue123' '$HOME/.hermes/profiles/main/.env'"
}
test_keys_apply_preserves_unrelated_settings() {
  mkdir -p "$HOME/.agent-os-vault" "$HOME/.hermes/profiles/main"
  echo plain > "$HOME/.agent-os-vault/backend"
  printf 'KEEP_ME=yes\nOPENROUTER_API_KEY=old\n' > "$HOME/.hermes/profiles/main/.env"
  printf 'OPENROUTER_API_KEY=sk-or-new123456\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  assert "grep -q '^KEEP_ME=yes$' '$HOME/.hermes/profiles/main/.env'" && \
  assert "grep -q 'sk-or-new123456' '$HOME/.hermes/profiles/main/.env'" && \
  assert "! grep -q 'OPENROUTER_API_KEY=old' '$HOME/.hermes/profiles/main/.env'"
}
test_keys_apply_no_duplicate_lines() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-or-dupetest\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  local n; n="$(grep -c '^OPENROUTER_API_KEY=' "$HOME/.hermes/profiles/main/.env")"
  assert "[ '$n' = 1 ]"
}
test_keys_rejects_placeholder() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENAI_API_KEY=sk-xxxx\n' > "$HOME/.agent-os-keys.env"
  local out; out="$(cd "$(K)" && ./keys.sh --apply 2>&1)"
  assert_grep "placeholder" "$out"
}
test_keys_flags_inferred_destinations() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'DATAFORSEO_LOGIN=me@example.com\n' > "$HOME/.agent-os-keys.env"
  local out; out="$(cd "$(K)" && ./keys.sh --apply 2>&1)"
  assert_grep "INFERRED" "$out"
}
test_keys_verified_destination_not_flagged() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-or-verified123\n' > "$HOME/.agent-os-keys.env"
  local out; out="$(cd "$(K)" && ./keys.sh --apply 2>&1)"
  assert_no "OPENROUTER_API_KEY.*INFERRED" "$out"
}

# ============================================================ vault
test_vault_refuses_anthropic_key() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  local out; out="$(cd "$(K)" && ./vault.sh --set ANTHROPIC_API_KEY </dev/null 2>&1)"
  assert_grep "Refused" "$out"
}
test_vault_roundtrip_plain() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'secret-value-abc' | ( cd "$(K)" && ./vault.sh --set-stdin TEST_KEY >/dev/null 2>&1 )
  local got; got="$(cd "$(K)" && ./vault.sh --get-quiet TEST_KEY 2>/dev/null)"
  assert "[ '$got' = 'secret-value-abc' ]"
}
test_vault_age_encrypts_and_roundtrips() {
  command -v age >/dev/null 2>&1 || { echo "age not installed"; return 77; }
  command -v script >/dev/null 2>&1 || { echo "no pty helper"; return 77; }
  mkdir -p "$HOME/.agent-os-vault"; chmod 700 "$HOME/.agent-os-vault"
  echo age > "$HOME/.agent-os-vault/backend"
  printf 'PLAINTEXT_CANARY_XYZ=supersecret999\n' > "$SANDBOX/p.txt"
  printf 'pw123\npw123\n' | script -qec "age -p -o '$HOME/.agent-os-vault/keys.age' '$SANDBOX/p.txt'" /dev/null >/dev/null 2>&1
  assert "[ -s '$HOME/.agent-os-vault/keys.age' ]" || return 1
  # ciphertext must not contain the secret
  assert "! grep -q 'supersecret999' '$HOME/.agent-os-vault/keys.age'" || return 1
  local got; got="$(printf 'pw123\n' | script -qec "cd '$(K)' && ./vault.sh --get-quiet PLAINTEXT_CANARY_XYZ" /dev/null 2>/dev/null | tr -d '\r' | tail -1 | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
  assert_grep "supersecret999" "$got"
}
test_vault_age_single_decrypt_per_run() {
  command -v age >/dev/null 2>&1 || { echo "age not installed"; return 77; }
  command -v script >/dev/null 2>&1 || { echo "no pty helper"; return 77; }
  mkdir -p "$HOME/.agent-os-vault"; chmod 700 "$HOME/.agent-os-vault"
  echo age > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=a1\nELEVENLABS_API_KEY=b2\nOPENAI_API_KEY=c3\nGEMINI_API_KEY=d4\n' > "$SANDBOX/p.txt"
  printf 'pw123\npw123\n' | script -qec "age -p -o '$HOME/.agent-os-vault/keys.age' '$SANDBOX/p.txt'" /dev/null >/dev/null 2>&1
  local out; out="$(printf 'pw123\n' | script -qec "cd '$(K)' && ./keys.sh --status" /dev/null 2>/dev/null | tr -d '\r')"
  local prompts; prompts="$(printf '%s' "$out" | grep -c 'Enter passphrase' || true)"
  # four keys stored, must still be exactly one prompt
  assert "[ '${prompts:-0}' -le 1 ]" || { echo "got $prompts passphrase prompts, expected 1"; return 1; }
}
test_vault_audit_flags_loose_permissions() {
  mkdir -p "$HOME/.hermes/profiles/main"
  echo 'OPENROUTER_API_KEY=x' > "$HOME/.hermes/profiles/main/.env"
  chmod 644 "$HOME/.hermes/profiles/main/.env"
  local out; out="$(cd "$(K)" && ./vault.sh --audit 2>&1)"
  assert_grep "TOO OPEN" "$out"
}
test_vault_audit_passes_correct_permissions() {
  mkdir -p "$HOME/.fcc"
  echo 'MODEL="ollama/gemma2"' > "$HOME/.fcc/.env"
  chmod 600 "$HOME/.fcc/.env"
  local out; out="$(cd "$(K)" && ./vault.sh --audit 2>&1)"
  assert_no "fcc/.env.*TOO OPEN" "$out"
}

# ============================================================ tabs
test_tabs_refuses_missing_prerequisites() {
  local out; out="$(cd "$(K)" && ./tabs.sh --add openseo --yes </dev/null 2>&1)"
  assert_grep "Prerequisites missing" "$out"
}
test_tabs_changes_nothing_on_refusal() {
  ( cd "$(K)" && ./tabs.sh --add openseo --yes </dev/null >/dev/null 2>&1 )
  assert "[ ! -d '$HOME/open-seo' ]"
}
test_tabs_wordpress_csv_import() {
  printf 'a.com,u1,pw one\nb.com,u2,pw two\nc.com,u3,pw three\n' > "$SANDBOX/sites.csv"
  mkdir -p "$HOME/.agentic-os"
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({default:"seed.com",sites:{"seed.com":{}}},null,2))' \
    "$HOME/.agentic-os/wordpress.json"
  printf '2\n%s\n' "$SANDBOX/sites.csv" | ( cd "$(K)" && ./tabs.sh --add wordpress >/dev/null 2>&1 )
  local n; n="$(node -e 'console.log(Object.keys(require(process.argv[1]).sites).length)' "$HOME/.agentic-os/wordpress.json")"
  assert "[ '$n' = 4 ]"
}
test_tabs_wordpress_config_is_600() {
  printf 'a.com,u1,pw one\n' > "$SANDBOX/sites.csv"
  mkdir -p "$HOME/.agentic-os"
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({sites:{}},null,2))' "$HOME/.agentic-os/wordpress.json"
  printf '2\n%s\n' "$SANDBOX/sites.csv" | ( cd "$(K)" && ./tabs.sh --add wordpress >/dev/null 2>&1 )
  local m; m="$(stat -c %a "$HOME/.agentic-os/wordpress.json" 2>/dev/null || stat -f %A "$HOME/.agentic-os/wordpress.json")"
  assert "[ '$m' = 600 ]"
}

# ============================================================ update / rollback
mk_fake_app() {
  mkdir -p "$HOME/app"
  printf '{"name":"a","version":"1.0.0","scripts":{"build":"true","start":"true"}}\n' > "$HOME/app/package.json"
  echo OLD > "$HOME/app/old.js"; echo 'SECRET=keep' > "$HOME/app/.env.local"
  mkdir -p "$HOME/pack/source"
  printf '{"name":"a","version":"2.0.0","scripts":{"build":"true","start":"true"}}\n' > "$HOME/pack/source/package.json"
  echo NEW > "$HOME/pack/source/new.js"
}
test_update_replaces_source() {
  mk_fake_app
  ( cd "$(K)" && APP_DIR="$HOME/app" ./update.sh --pack --from "$HOME/pack" --yes >/dev/null 2>&1 )
  assert "[ -f '$HOME/app/new.js' ]" && assert "[ ! -f '$HOME/app/old.js' ]"
}
test_update_preserves_env() {
  mk_fake_app
  ( cd "$(K)" && APP_DIR="$HOME/app" ./update.sh --pack --from "$HOME/pack" --yes >/dev/null 2>&1 )
  assert "grep -q 'SECRET=keep' '$HOME/app/.env.local'"
}
test_update_creates_backup() {
  mk_fake_app
  ( cd "$(K)" && APP_DIR="$HOME/app" ./update.sh --pack --from "$HOME/pack" --yes >/dev/null 2>&1 )
  assert "[ -n \"\$(ls -d '$HOME'/app.bak-* 2>/dev/null)\" ]"
}
test_rollback_restores() {
  mk_fake_app
  ( cd "$(K)" && APP_DIR="$HOME/app" ./update.sh --pack --from "$HOME/pack" --yes >/dev/null 2>&1 )
  ( cd "$(K)" && APP_DIR="$HOME/app" ./update.sh --rollback --yes >/dev/null 2>&1 )
  local v; v="$(node -e 'console.log(require(process.argv[1]).version)' "$HOME/app/package.json")"
  assert "[ '$v' = '1.0.0' ]" && assert "[ -f '$HOME/app/old.js' ]"
}

# ============================================================ healthcheck
test_healthcheck_never_blocks() {
  # must complete without stdin and without hanging
  ( cd "$(K)" && timeout 90 ./healthcheck.sh --quiet --no-vault </dev/null >/dev/null 2>&1 )
  local rc=$?
  assert "[ $rc -ne 124 ]" || { echo "healthcheck timed out, it is blocking on input"; return 1; }
}
test_healthcheck_writes_log() {
  ( cd "$(K)" && timeout 90 ./healthcheck.sh --quiet --no-vault </dev/null >/dev/null 2>&1 )
  assert "[ -f '$HOME/.agent-os-install/health.log' ]"
}
test_healthcheck_detects_age_passphrase_problem() {
  mkdir -p "$HOME/.agent-os-vault"; echo age > "$HOME/.agent-os-vault/backend"
  ( cd "$(K)" && timeout 90 ./healthcheck.sh --quiet --no-vault </dev/null >/dev/null 2>&1 )
  local out; out="$(cat "$HOME/.agent-os-install/health.log")"
  assert_grep "needs a passphrase" "$out"
}
test_healthcheck_exit_code_reflects_breakage() {
  # nothing installed in the sandbox, so the spine must fail and exit 2
  ( cd "$(K)" && timeout 90 ./healthcheck.sh --quiet --no-vault </dev/null >/dev/null 2>&1 )
  local rc=$?
  assert "[ $rc -eq 2 ]"
}

# ============================================================ safety invariants
prod_scripts() { ls "$(K)"/*.sh | grep -v '/test\.sh$'; }

test_no_secrets_passed_as_argv() {
  # vault.sh must read secrets from stdin/tty, never as a command argument
  assert "! grep -nE '^\\s*(security add-generic-password|op item create).*\\\$v' '$(K)/keys.sh'"
}
test_scripts_do_not_export_keys() {
  local hit; hit="$(prod_scripts | xargs grep -nE '^[[:space:]]*export [A-Z_]*API_KEY=' 2>/dev/null || true)"
  [ -z "$hit" ] || { echo "found: $hit"; return 1; }
}
test_no_anthropic_key_written_anywhere() {
  # Product scripts must never WRITE this key. test.sh is excluded because its own
  # fixtures create the trap deliberately in order to test the detection of it.
  local hit; hit="$(prod_scripts | xargs grep -nE "printf[^|]*'ANTHROPIC_API_KEY=" 2>/dev/null || true)"
  [ -z "$hit" ] || { echo "found: $hit"; return 1; }
}
test_preflight_is_read_only() {
  # snapshot HOME, run preflight, compare. It may only create its own state file.
  local before after
  before="$(find "$HOME" -type f 2>/dev/null | sort)"
  ( cd "$(K)" && ./preflight.sh </dev/null >/dev/null 2>&1 )
  after="$(find "$HOME" -type f 2>/dev/null | grep -v '.agent-os-install/state' | sort)"
  assert "[ \"$before\" = \"$after\" ]" || { echo "preflight created or modified files"; return 1; }
}

# ============================================================ v1.1 fixes
test_version_flag_on_every_script() {
  local f n
  for f in preflight keys vault tabs update install setup; do
    n="$(cd "$(K)" && ./$f.sh --version 2>/dev/null | head -1)"
    printf '%s' "$n" | grep -q 'agent-os-plus' || { echo "$f.sh --version failed: $n"; return 1; }
  done
}
test_expected_absent_suppresses_failure() {
  mkdir -p "$HOME/.agent-os-install"
  local before after
  before="$(cd "$(K)" && ./preflight.sh </dev/null 2>&1)"
  assert_grep "Failing gates" "$before" || return 1
  # mark every failing stage as intentional
  local n
  for n in 0 1 2 3 4 5; do ( cd "$(K)" && ./preflight.sh --expect $n >/dev/null 2>&1 ); done
  after="$(cd "$(K)" && ./preflight.sh </dev/null 2>&1)"
  assert_no "Failing gates" "$after"
}
test_expected_absent_can_be_undone() {
  ( cd "$(K)" && ./preflight.sh --expect 5 >/dev/null 2>&1 )
  ( cd "$(K)" && ./preflight.sh --unexpect 5 >/dev/null 2>&1 )
  assert "! grep -qx 5 '$HOME/.agent-os-install/expected-absent' 2>/dev/null"
}
test_no_hermes_marks_stage_five() {
  ( cd "$(K)" && ./install.sh --stage 5 --no-hermes --yes </dev/null >/dev/null 2>&1 )
  assert "grep -qx 5 '$HOME/.agent-os-install/expected-absent'"
}
test_schedule_hour_wraps_at_23() {
  command -v crontab >/dev/null 2>&1 || { echo "no crontab"; return 77; }
  printf 'y
' | ( cd "$(K)" && ./schedule.sh --updates --time 23:30 >/dev/null 2>&1 )
  local bad_hour; bad_hour="$(crontab -l 2>/dev/null | grep 'agent-os-plus' | awk '{print $2}' | grep -c '^24$' || true)"
  crontab -l 2>/dev/null | grep -v 'agent-os-plus' | crontab - 2>/dev/null || crontab -r 2>/dev/null || true
  assert "[ '${bad_hour:-0}' = 0 ]" || { echo "produced invalid cron hour 24"; return 1; }
}
test_schedule_rejects_bad_time() {
  local out; out="$(cd "$(K)" && ./schedule.sh --install --time 99:00 </dev/null 2>&1)"
  assert_grep "Hour must be" "$out"
}
test_keys_names_interface() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-real123456
OPENAI_API_KEY=sk-xxxx
' > "$HOME/.agent-os-keys.env"
  local out; out="$(cd "$(K)" && ./keys.sh --names 2>/dev/null)"
  assert_grep "OPENROUTER_API_KEY" "$out" || return 1
  assert_no "OPENAI_API_KEY" "$out"   # placeholder must not count as set
}
test_keys_has_interface() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-real123456
' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --has OPENROUTER_API_KEY >/dev/null 2>&1 ) || return 1
  ( cd "$(K)" && ./keys.sh --has SUNO_API_KEY >/dev/null 2>&1 ) && { echo "--has returned 0 for an unset key"; return 1; }
  return 0
}
test_status_is_fast() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-perf123456
' > "$HOME/.agent-os-keys.env"
  local s e ms
  s=$(date +%s%N); ( cd "$(K)" && ./keys.sh --status >/dev/null 2>&1 ); e=$(date +%s%N)
  ms=$(( (e-s)/1000000 ))
  # regression guard: the metadata cache must stay in parent scope
  assert "[ $ms -lt 800 ]" || { echo "status took ${ms}ms, cache is probably being rebuilt per lookup"; return 1; }
}
test_lock_prevents_concurrent_runs() {
  mkdir -p "$HOME/.agent-os-install/lock"
  echo 999999 > "$HOME/.agent-os-install/lock/pid"   # a pid that does not exist
  # a stale lock must be reaped, not block forever
  local out; out="$(cd "$(K)" && timeout 30 ./tabs.sh </dev/null 2>&1)"
  local rc=$?
  assert "[ $rc -ne 124 ]" || { echo "stale lock caused a hang"; return 1; }
}
test_uninstall_dry_run_removes_nothing() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-keepme
' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./uninstall.sh </dev/null >/dev/null 2>&1 )
  assert "[ -f '$HOME/.agent-os-keys.env' ]" && assert "[ -d '$HOME/.agent-os-vault' ]"
}
test_uninstall_vault_requires_typed_confirmation() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'no
' | ( cd "$(K)" && ./uninstall.sh --vault >/dev/null 2>&1 )
  assert "[ -d '$HOME/.agent-os-vault' ]" || { echo "vault destroyed without typing DESTROY"; return 1; }
}
test_uninstall_never_touches_agentic_os_config() {
  mkdir -p "$HOME/.agentic-os"
  echo '{"vaultRoot":"/x"}' > "$HOME/.agentic-os/config.json"
  printf 'y
y
y
' | ( cd "$(K)" && ./uninstall.sh --keys >/dev/null 2>&1 )
  assert "[ -f '$HOME/.agentic-os/config.json' ]"
}

# ============================================================ untested-platform backends
# macOS Keychain and 1Password cannot run here. Stubbing the binaries verifies that OUR
# code invokes them with the right arguments and handles their output, which is the half
# of the problem we control. It does NOT prove the real tools behave as expected.
stub_bin() { # stub_bin <name> <script-body>
  mkdir -p "$SANDBOX/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"
  chmod +x "$SANDBOX/bin/$1"
  export PATH="$SANDBOX/bin:$PATH"
}

test_keychain_backend_stores_and_reads() {
  mkdir -p "$SANDBOX/kcstore"
  stub_bin security '
store="$SANDBOX_KC"
case "$1" in
  add-generic-password)
    svc=""; val=""
    while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift 2;; -w) val="$2"; shift 2;; *) shift;; esac; done
    printf "%s" "$val" > "$store/$(printf "%s" "$svc" | tr "/:" "__")"; exit 0 ;;
  find-generic-password)
    svc=""
    while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift 2;; *) shift;; esac; done
    f="$store/$(printf "%s" "$svc" | tr "/:" "__")"
    [ -f "$f" ] && cat "$f" && exit 0; exit 1 ;;
  delete-generic-password)
    svc=""
    while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift 2;; *) shift;; esac; done
    rm -f "$store/$(printf "%s" "$svc" | tr "/:" "__")"; exit 0 ;;
  dump-keychain) for f in "$store"/*; do [ -e "$f" ] && printf "\"%s\"\n" "$(basename "$f" | tr "_" ":")"; done; exit 0 ;;
esac
exit 0'
  export SANDBOX_KC="$SANDBOX/kcstore"
  mkdir -p "$HOME/.agent-os-vault"; echo keychain > "$HOME/.agent-os-vault/backend"
  printf 'kc-secret-value-42' | ( cd "$(K)" && SANDBOX_KC="$SANDBOX/kcstore" ./vault.sh --set-stdin TEST_KC >/dev/null 2>&1 )
  local got; got="$(cd "$(K)" && SANDBOX_KC="$SANDBOX/kcstore" ./vault.sh --get-quiet TEST_KC 2>/dev/null)"
  assert "[ '$got' = 'kc-secret-value-42' ]"
}

test_keychain_works_without_USER_set() {
  # cron and non-login shells do not set $USER. Under `set -u` that was fatal.
  stub_bin security 'exit 0'
  mkdir -p "$HOME/.agent-os-vault"; echo keychain > "$HOME/.agent-os-vault/backend"
  local out; out="$(cd "$(K)" && env -u USER -u LOGNAME ./vault.sh --get-quiet ANY_KEY 2>&1)"
  assert_no "unbound variable" "$out"
}

test_keychain_refuses_anthropic() {
  stub_bin security 'exit 0'
  mkdir -p "$HOME/.agent-os-vault"; echo keychain > "$HOME/.agent-os-vault/backend"
  local out; out="$(cd "$(K)" && ./vault.sh --set ANTHROPIC_API_KEY </dev/null 2>&1)"
  assert_grep "Refused" "$out"
}

test_op_backend_invoked_correctly() {
  mkdir -p "$SANDBOX/opstore"
  stub_bin op '
store="$SANDBOX_OP"
case "$1 $2" in
  "account list") exit 0 ;;
esac
case "$1" in
  read) # op://VAULT/TITLE/credential
    t="$(printf "%s" "$2" | awk -F/ "{print \$4}")"
    [ -f "$store/$t" ] && cat "$store/$t" && exit 0; exit 1 ;;
  item)
    case "$2" in
      get) t="$3"; [ -f "$store/$t" ] && exit 0 || exit 1 ;;
      create)
        t=""; v=""
        while [ $# -gt 0 ]; do
          case "$1" in --title) t="$2"; shift 2;; credential=*) v="${1#credential=}"; shift;; *) shift;; esac
        done
        printf "%s" "$v" > "$store/$t"; exit 0 ;;
      edit)
        t="$3"; v=""
        while [ $# -gt 0 ]; do case "$1" in credential=*) v="${1#credential=}"; shift;; *) shift;; esac; done
        printf "%s" "$v" > "$store/$t"; exit 0 ;;
      list) printf "[]\n"; exit 0 ;;
    esac ;;
esac
exit 0'
  export SANDBOX_OP="$SANDBOX/opstore"
  mkdir -p "$HOME/.agent-os-vault"; echo op > "$HOME/.agent-os-vault/backend"
  printf 'op-secret-99' | ( cd "$(K)" && SANDBOX_OP="$SANDBOX/opstore" ./vault.sh --set-stdin TEST_OP >/dev/null 2>&1 )
  local got; got="$(cd "$(K)" && SANDBOX_OP="$SANDBOX/opstore" ./vault.sh --get-quiet TEST_OP 2>/dev/null)"
  assert "[ '$got' = 'op-secret-99' ]"
}

test_powershell_bootstrap_syntax() {
  command -v pwsh >/dev/null 2>&1 || { echo "pwsh not installed"; return 77; }
  pwsh -NoProfile -Command "
    \$ErrorActionPreference='Stop'
    \$null = [System.Management.Automation.Language.Parser]::ParseFile('$(K)/bootstrap.ps1',[ref]\$null,[ref]\$errs)
    if (\$errs.Count -gt 0) { \$errs | ForEach-Object { Write-Output \$_.Message }; exit 1 }
    exit 0" 2>&1
}

test_powershell_bootstrap_static_checks() {
  local f="$(K)/bootstrap.ps1"
  # balanced braces and no obviously fatal typos, as a floor when pwsh is unavailable
  local o c
  o="$(grep -o '{' "$f" | wc -l | tr -d ' ')"; c="$(grep -o '}' "$f" | wc -l | tr -d ' ')"
  assert "[ '$o' = '$c' ]" || { echo "unbalanced braces: $o open, $c close"; return 1; }
  grep -q 'wsl.exe --install' "$f" || { echo "missing WSL install path"; return 1; }
  grep -q 'IsInRole' "$f" || { echo "missing admin check"; return 1; }
}

test_discover_finds_real_paths() {
  mkdir -p "$HOME/pack/source/lib"
  echo '{"name":"a"}' > "$HOME/pack/source/package.json"
  printf 'const p="~/open-seo/.env";\nconst k=process.env.DATAFORSEO_LOGIN;\n' > "$HOME/pack/source/lib/s.js"
  local out; out="$(cd "$(K)" && APP_DIR="$HOME/pack/source" ./keys.sh --discover 2>&1)"
  assert_grep "DATAFORSEO_LOGIN.*referenced in" "$out"
}
test_discover_flags_absent_keys() {
  mkdir -p "$HOME/pack/source"
  echo '{"name":"a"}' > "$HOME/pack/source/package.json"
  local out; out="$(cd "$(K)" && APP_DIR="$HOME/pack/source" ./keys.sh --discover 2>&1)"
  assert_grep "not referenced anywhere" "$out"
}
test_discover_never_edits_manifest() {
  mkdir -p "$HOME/pack/source"; echo '{"name":"a"}' > "$HOME/pack/source/package.json"
  local before after
  before="$(md5sum "$(K)/keys.json" 2>/dev/null || md5 -q "$(K)/keys.json")"
  ( cd "$(K)" && APP_DIR="$HOME/pack/source" ./keys.sh --discover >/dev/null 2>&1 )
  after="$(md5sum "$(K)/keys.json" 2>/dev/null || md5 -q "$(K)/keys.json")"
  assert "[ '$before' = '$after' ]"
}

# ============================================================ session mode
test_session_start_writes_then_end_strips() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-or-sess123\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./vault.sh --session-start >/dev/null 2>&1 )
  assert "grep -q 'sk-or-sess123' '$HOME/.hermes/profiles/main/.env'" || { echo "session-start did not write"; return 1; }
  ( cd "$(K)" && ./vault.sh --session-end >/dev/null 2>&1 )
  assert "! grep -q 'sk-or-sess123' '$HOME/.hermes/profiles/main/.env'"
}
test_session_end_keeps_vault_contents() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-or-keep456\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./vault.sh --session-start >/dev/null 2>&1 )
  ( cd "$(K)" && ./vault.sh --session-end >/dev/null 2>&1 )
  ( cd "$(K)" && ./keys.sh --has OPENROUTER_API_KEY >/dev/null 2>&1 )
}
test_session_end_preserves_unrelated_settings() {
  mkdir -p "$HOME/.agent-os-vault" "$HOME/.hermes/profiles/main"
  echo plain > "$HOME/.agent-os-vault/backend"
  printf 'KEEP_THIS=yes\n' > "$HOME/.hermes/profiles/main/.env"
  printf 'OPENROUTER_API_KEY=sk-or-x789\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./vault.sh --session-start >/dev/null 2>&1 )
  ( cd "$(K)" && ./vault.sh --session-end >/dev/null 2>&1 )
  assert "grep -q '^KEEP_THIS=yes$' '$HOME/.hermes/profiles/main/.env'"
}
test_audit_warns_about_open_session() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-or-open1\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./vault.sh --session-start >/dev/null 2>&1 )
  local out; out="$(cd "$(K)" && ./vault.sh --audit 2>&1)"
  assert_grep "session has been open" "$out"
}

# ============================================================ real-pack destinations
test_json_destination_writes_named_field() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'HUNTER_API_KEY=hunter-abc123\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  local f="$HOME/.agentic-os/outreach/config.json"
  assert "[ -f '$f' ]" || { echo "config.json not created"; return 1; }
  node -e 'const d=require(process.argv[1]);process.exit(d.hunterKey==="hunter-abc123"?0:1)' "$f" \
    || { echo "hunterKey field wrong: $(cat "$f")"; return 1; }
}
test_json_destination_merges_not_clobbers() {
  mkdir -p "$HOME/.agent-os-vault" "$HOME/.agentic-os/outreach"
  echo plain > "$HOME/.agent-os-vault/backend"
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({icp:"keep me"},null,2))' \
    "$HOME/.agentic-os/outreach/config.json"
  printf 'HUNTER_API_KEY=hunter-xyz\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  node -e 'const d=require(process.argv[1]);process.exit(d.icp==="keep me"&&d.hunterKey==="hunter-xyz"?0:1)' \
    "$HOME/.agentic-os/outreach/config.json"
}
test_json_destination_is_600() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'APOLLO_API_KEY=apollo-1\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  local f="$HOME/.agentic-os/outreach/config.json" m
  m="$(stat -c %a "$f" 2>/dev/null || stat -f %A "$f")"
  assert "[ '$m' = 600 ]"
}
test_env_only_keys_are_flagged_not_written() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'YT_API_KEY=yt-123\n' > "$HOME/.agent-os-keys.env"
  local out; out="$(cd "$(K)" && ./keys.sh --apply 2>&1)"
  assert_grep "ENVIRONMENT only" "$out" || return 1
  # must not silently invent a file that nothing reads
  assert "[ ! -f '$HOME/.agentic-os/astros.env' ]"
}
test_hermes_active_profile_is_honoured() {
  mkdir -p "$HOME/.agent-os-vault" "$HOME/.hermes"
  echo plain > "$HOME/.agent-os-vault/backend"
  echo "clientwork" > "$HOME/.hermes/active_profile"
  printf 'OPENROUTER_API_KEY=sk-or-profile1\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  assert "grep -q 'sk-or-profile1' '$HOME/.hermes/profiles/clientwork/.env'" \
    || { echo "wrote to main instead of the active profile"; return 1; }
}
test_hermes_defaults_to_main_without_active_profile() {
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-or-default1\n' > "$HOME/.agent-os-keys.env"
  ( cd "$(K)" && ./keys.sh --apply >/dev/null 2>&1 )
  assert "grep -q 'sk-or-default1' '$HOME/.hermes/profiles/main/.env'"
}
test_discover_excludes_its_own_folder() {
  # the toolkit's own files mention every key name, so scanning itself reports
  # our filenames back as if they were the pack's truth
  mkdir -p "$HOME/pack/source"
  echo '{"name":"a"}' > "$HOME/pack/source/package.json"
  cp -r "$(K)" "$HOME/pack/installer"
  local out; out="$(cd "$HOME/pack/installer" && APP_DIR="$HOME/pack/source" ./keys.sh --discover 2>&1)"
  assert_no "agent-os-keys.env" "$out" || { echo "discovery reported its own filename"; return 1; }
  assert_grep "not referenced anywhere" "$out"
}
test_all_destinations_have_evidence() {
  # every destination must now cite where the claim came from
  node -e '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const bad=[];
    for(const k of m.keys) for(const d of (k.destinations||[]))
      if(!d.evidence) bad.push(k.id);
    if(bad.length){ console.log("no evidence: "+bad.join(", ")); process.exit(1); }
  ' "$(K)/keys.json"
}

# ============================================================ public release safety
test_no_secrets_in_repo() {
  local hit
  hit="$(grep -rnE '(sk-[A-Za-z0-9_-]{24,}|sk-or-v1-[A-Za-z0-9]{24,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xoxb-)' \
        "$(K)" --exclude=test.sh 2>/dev/null || true)"
  [ -z "$hit" ] || { echo "possible secret: $hit"; return 1; }
}
test_no_personal_paths() {
  local hit
  hit="$(grep -rnE '/Users/[a-z]+|/home/[a-z]+/(Desktop|Documents)/[A-Z]' "$(K)"/*.sh "$(K)"/*.json 2>/dev/null || true)"
  [ -z "$hit" ] || { echo "hardcoded personal path: $hit"; return 1; }
}
test_gitignore_covers_secrets() {
  local f="$(K)/.gitignore" p
  [ -f "$f" ] || { echo ".gitignore missing"; return 1; }
  for p in '\*.env' 'keys.age' '.agent-os-vault'; do
    grep -q "$p" "$f" || { echo ".gitignore does not cover $p"; return 1; }
  done
}
test_license_present_and_attributed() {
  local f="$(K)/LICENSE"
  [ -f "$f" ] || { echo "LICENSE missing"; return 1; }
  grep -q "MIT License" "$f" || { echo "not MIT"; return 1; }
  grep -q "Scott Nailon" "$f" || { echo "author attribution missing"; return 1; }
}
test_docs_are_self_identifying() {
  # Three README.md and two CHANGELOG.md exist in a populated pack tree. Ours must say
  # which project it belongs to on the first line, or people open the wrong one.
  head -1 "$(K)/README.md" | grep -q "Agent OS Plus" \
    || { echo "README.md first line does not identify the project"; return 1; }
  head -1 "$(K)/CHANGELOG.md" | grep -q "Agent OS Plus" \
    || { echo "CHANGELOG.md first line does not identify the project"; return 1; }
  grep -q "is not Agent OS" "$(K)/README.md" \
    || { echo "README does not distinguish itself from the pack"; return 1; }
}

test_readme_has_pack_source_and_attribution() {
  local f="$(K)/README.md"
  grep -q "skool.com/ai-profit-lab-7462" "$f" || { echo "community link missing"; return 1; }
  grep -q "Resources" "$f" || { echo "pack download instructions missing"; return 1; }
  grep -q "Scott Nailon" "$f" || { echo "author missing"; return 1; }
}
test_every_new_key_has_evidence() {
  node -e '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const bad=m.keys.filter(k=>(k.destinations||[]).some(d=>!d.evidence)).map(k=>k.id);
    if(bad.length){console.log("missing evidence: "+bad.join(", "));process.exit(1);}
    console.log(m.keys.length+" keys, all with evidence");
  ' "$(K)/keys.json"
}
test_every_tab_has_a_procedure() {
  local ids id
  ids="$(node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).tabs.forEach(t=>console.log(t.id))' "$(K)/tabs.json")"
  local fn
  for id in $ids; do
    # dispatch entries share lines, so match the case label anywhere
    grep -qE "(^|[[:space:]])${id}\)" "$(K)/tabs.sh" \
      || { echo "tab '$id' has no dispatch entry in tabs.sh"; return 1; }
    # and the function it dispatches to must exist
    fn="add_$(printf '%s' "$id" | tr '-' '_')"
    grep -qE "^${fn}\(\)" "$(K)/tabs.sh" \
      || { echo "tab '$id' dispatches to $fn which is not defined"; return 1; }
  done
}

# ============================================================ misplacement guard
test_refuses_to_run_from_pack_root() {
  # simulate the mistake: toolkit files sitting directly in the pack root
  mkdir -p "$HOME/badpack/source" "$HOME/badpack/install"
  echo '{"name":"a"}' > "$HOME/badpack/source/package.json"
  cp "$(K)"/*.sh "$(K)"/*.json "$HOME/badpack/" 2>/dev/null
  local out; out="$(cd "$HOME/badpack" && ./preflight.sh </dev/null 2>&1)"
  local rc=$?
  assert_grep "MISPLACED INSTALL" "$out" || { echo "did not detect misplacement"; return 1; }
  assert "[ $rc -ne 0 ]"
}
test_runs_fine_from_a_subfolder() {
  mkdir -p "$HOME/goodpack/source" "$HOME/goodpack/install" "$HOME/goodpack/installer"
  echo '{"name":"a"}' > "$HOME/goodpack/source/package.json"
  cp "$(K)"/*.sh "$(K)"/*.json "$HOME/goodpack/installer/" 2>/dev/null
  local out; out="$(cd "$HOME/goodpack/installer" && ./preflight.sh </dev/null 2>&1)"
  assert_no "MISPLACED INSTALL" "$out"
}

# ============================================================ live (network)
test_live_rejects_bad_openrouter_key() {
  online || { echo "offline"; return 77; }
  mkdir -p "$HOME/.agent-os-vault"; echo plain > "$HOME/.agent-os-vault/backend"
  printf 'OPENROUTER_API_KEY=sk-or-v1-definitelynotvalid000\n' > "$HOME/.agent-os-keys.env"
  local out; out="$(cd "$(K)" && ./keys.sh --check 2>&1)"
  assert_grep "REJECTED" "$out"
}

# ============================================================ run
printf '%sAgent OS installer test suite%s\n' "$B" "$N"
printf '%ssandboxed HOME, your real config is never touched%s\n\n' "$D" "$N"

printf '%sStatic%s\n' "$B" "$N"
t "shell syntax across all scripts"          test_syntax
t "all JSON files parse"                     test_json_valid

printf '\n%sModel routing gate%s\n' "$B" "$N"
t "catches a small model driving Hermes"     test_routing_catches_small_model_on_hermes
t "catches a stealth/alpha model"            test_routing_catches_stealth_model
t "accepts a correct configuration"          test_routing_accepts_correct_config
t "routing.json edits change behaviour"      test_routing_json_is_live_not_decorative

printf '\n%sClaude tab trap%s\n' "$B" "$N"
t "detects empty ANTHROPIC_API_KEY"          test_claude_trap_detected
t "fix works when it is the only line"       test_claude_trap_fixed_single_line
t "fix preserves other lines"                test_claude_trap_fix_preserves_other_lines

printf '\n%sKeys%s\n' "$B" "$N"
t "init creates a 600 template"              test_keys_init_creates_template
t "template excludes ANTHROPIC_API_KEY"      test_keys_template_excludes_anthropic
t "apply fans out to destinations"           test_keys_apply_fans_out
t "apply preserves unrelated settings"       test_keys_apply_preserves_unrelated_settings
t "apply twice does not duplicate lines"     test_keys_apply_no_duplicate_lines
t "rejects unfilled placeholders"            test_keys_rejects_placeholder
t "flags inferred destination paths"         test_keys_flags_inferred_destinations
t "does not flag verified paths"             test_keys_verified_destination_not_flagged

printf '\n%sVault%s\n' "$B" "$N"
t "refuses ANTHROPIC_API_KEY"                test_vault_refuses_anthropic_key
t "plain backend stores and retrieves"       test_vault_roundtrip_plain
t "age encrypts, no plaintext in file"       test_vault_age_encrypts_and_roundtrips
t "age decrypts ONCE per run, not per key"   test_vault_age_single_decrypt_per_run
t "audit flags loose file permissions"       test_vault_audit_flags_loose_permissions
t "audit passes correct permissions"         test_vault_audit_passes_correct_permissions

printf '\n%sTabs%s\n' "$B" "$N"
t "refuses when prerequisites are missing"   test_tabs_refuses_missing_prerequisites
t "changes nothing when it refuses"          test_tabs_changes_nothing_on_refusal
t "WordPress CSV bulk import"                test_tabs_wordpress_csv_import
t "WordPress config written 600"             test_tabs_wordpress_config_is_600

printf '\n%sUpdate and rollback%s\n' "$B" "$N"
t "update replaces the source"               test_update_replaces_source
t "update preserves .env files"              test_update_preserves_env
t "update creates a backup"                  test_update_creates_backup
t "rollback restores the previous version"   test_rollback_restores

printf '\n%sHealth check%s\n' "$B" "$N"
t "never blocks waiting for input"           test_healthcheck_never_blocks
t "writes a log"                             test_healthcheck_writes_log
t "detects the age passphrase problem"       test_healthcheck_detects_age_passphrase_problem
t "exit code reflects breakage"              test_healthcheck_exit_code_reflects_breakage

printf '\n%sSafety invariants%s\n' "$B" "$N"
t "no secrets passed as argv"                test_no_secrets_passed_as_argv
t "scripts never export API keys"            test_scripts_do_not_export_keys
t "never writes ANTHROPIC_API_KEY"           test_no_anthropic_key_written_anywhere
t "preflight is genuinely read-only"         test_preflight_is_read_only

printf '\n%sVersion, expectations and locking%s\n' "$B" "$N"
t "--version works on every script"          test_version_flag_on_every_script
t "expected-absent suppresses a failure"     test_expected_absent_suppresses_failure
t "expected-absent can be undone"            test_expected_absent_can_be_undone
t "--no-hermes marks stage 5 as expected"    test_no_hermes_marks_stage_five
t "stale lock is reaped, does not hang"      test_lock_prevents_concurrent_runs

printf '\n%sScheduling%s\n' "$B" "$N"
t "hour wraps instead of producing 24"       test_schedule_hour_wraps_at_23
t "rejects an out-of-range time"             test_schedule_rejects_bad_time

printf '\n%sInterfaces and performance%s\n' "$B" "$N"
t "--names lists only genuinely set keys"    test_keys_names_interface
t "--has exits 0 set / 1 unset"              test_keys_has_interface
t "status stays fast (cache in parent)"      test_status_is_fast

printf '\n%sUninstall%s\n' "$B" "$N"
t "dry run removes nothing"                  test_uninstall_dry_run_removes_nothing
t "vault destruction needs typed confirm"    test_uninstall_vault_requires_typed_confirmation
t "never removes ~/.agentic-os/config.json"  test_uninstall_never_touches_agentic_os_config

printf '\n%sBackends that cannot run on this platform (stubbed)%s\n' "$B" "$N"
t "keychain backend stores and reads"        test_keychain_backend_stores_and_reads
t "keychain works with \$USER unset (cron)"  test_keychain_works_without_USER_set
t "keychain still refuses ANTHROPIC_API_KEY" test_keychain_refuses_anthropic
t "1Password backend invoked correctly"      test_op_backend_invoked_correctly
t "PowerShell bootstrap parses"              test_powershell_bootstrap_syntax
t "PowerShell bootstrap static checks"       test_powershell_bootstrap_static_checks

printf '\n%sDestination discovery%s\n' "$B" "$N"
t "finds real paths in the installed pack"   test_discover_finds_real_paths
t "flags keys the pack never references"     test_discover_flags_absent_keys
t "never edits keys.json automatically"      test_discover_never_edits_manifest

printf '\n%sSession mode%s\n' "$B" "$N"
t "start writes keys, end strips them"       test_session_start_writes_then_end_strips
t "end keeps the vault contents"             test_session_end_keeps_vault_contents
t "end preserves unrelated settings"         test_session_end_preserves_unrelated_settings
t "audit warns about a left-open session"    test_audit_warns_about_open_session

printf '\n%sReal-pack destinations%s\n' "$B" "$N"
t "JSON destination writes the named field"  test_json_destination_writes_named_field
t "JSON merge preserves other settings"      test_json_destination_merges_not_clobbers
t "JSON destination written 600"             test_json_destination_is_600
t "env-only keys flagged, no fake file"      test_env_only_keys_are_flagged_not_written
t "honours ~/.hermes/active_profile"         test_hermes_active_profile_is_honoured
t "defaults to 'main' when unset"            test_hermes_defaults_to_main_without_active_profile
t "discovery excludes its own folder"        test_discover_excludes_its_own_folder
t "every destination cites evidence"         test_all_destinations_have_evidence


# --- locking -----------------------------------------------------------------
# setup.sh takes the lock then calls install.sh, keys.sh and tabs.sh, each of which
# also locks. Without the inherit check this deadlocks against its own parent.
test_nested_run_inherits_lock() {
  local out
  out="$(cd "$(K)" && bash -c '
    . ./lib.sh
    acquire_lock
    ./preflight.sh --version 2>&1
    ./vault.sh --status 2>&1 | head -2
  ' 2>&1)"
  case "$out" in
    *"Another agent-os-plus command is running"*)
      echo "a child deadlocked against its own parent"; return 1 ;;
  esac
  return 0
}

test_child_exit_keeps_parent_lock() {
  cd "$(K)" && bash -c '
    . ./lib.sh
    acquire_lock
    ( . ./lib.sh; acquire_lock; )     # child acquires, then exits
    if [ ! -d "$LOCK_DIR" ]; then
      echo "the child released the parent lock on exit"
      exit 1
    fi
  '
}

printf '\n%sPublic release safety%s\n' "$B" "$N"
t "no secrets anywhere in the repo"          test_no_secrets_in_repo
t "no hardcoded personal paths"              test_no_personal_paths
t ".gitignore covers every secret file"      test_gitignore_covers_secrets
t "LICENSE present and attributed"           test_license_present_and_attributed
t "README credits the pack and its author"   test_readme_has_pack_source_and_attribution
t "docs identify which project they are"     test_docs_are_self_identifying
t "every key destination cites evidence"     test_every_new_key_has_evidence
t "every catalogued tab has a procedure"     test_every_tab_has_a_procedure


# Two separate transports mangled the quote-stripping expression into something that
# also removed backslashes and digits. Syntax stayed valid both times, so bash -n caught
# nothing. This asserts the behaviour instead of the text.
test_unquote_strips_only_quotes_and_spaces() {
  local out
  # AOS_DQ is a double quote, defined by lib.sh. Using it keeps this test free of
  # backslashes, which is the whole point of what it is testing.
  out="$(cd "$(K)" && bash -c '. ./lib.sh >/dev/null 2>&1; printf "%s" "${AOS_DQ}ollama/gemma2${AOS_DQ} " | unquote')"
  if [ "$out" != "ollama/gemma2" ]; then
    echo "unquote returned [$out], expected [ollama/gemma2]"
    return 1
  fi
  return 0
}

printf '\n%sLocking%s\n' "$B" "$N"
t "unquote strips only quotes and spaces"   test_unquote_strips_only_quotes_and_spaces
t "a nested run inherits the parent lock"   test_nested_run_inherits_lock
t "a child exit keeps the parent lock"      test_child_exit_keeps_parent_lock

printf '\n%sMisplacement guard%s\n' "$B" "$N"
t "refuses to run from the pack root"        test_refuses_to_run_from_pack_root
t "runs fine from a subfolder"               test_runs_fine_from_a_subfolder

printf '\n%sLive (network)%s\n' "$B" "$N"
t "a bad OpenRouter key is rejected"         test_live_rejects_bad_openrouter_key

printf '\n%s================================%s\n' "$B" "$N"
printf '%s%s passed%s' "$G" "$PASS" "$N"
[ "$SKIP" -gt 0 ] && printf ', %s%s skipped%s' "$Y" "$SKIP" "$N"
[ "$FAIL" -gt 0 ] && printf ', %s%s FAILED%s' "$R" "$FAIL" "$N"
printf '\n'
[ "$FAIL" -gt 0 ] && { printf '%sFailed:%s%s\n' "$R" "$N" "$FAILED_NAMES"; printf '\nRe-run with --verbose to see why.\n'; exit 1; }
exit 0
