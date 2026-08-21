# Agent OS Plus: Reference

The short path is in `README.md`. This is everything else: the full flag surface, the
mental model behind the six stages, and the answers to the questions that come up once
it is running.

You never have to read this. `./aos help` lists the nine words that cover normal use.

---

# THE NEXT LEVEL

Read this once the basics work. None of it is urgent.

## The mental model

It is not 40 tabs. It is **two spines with plugins**.

| Spine | What it is | What it carries |
|---|---|---|
| **The bus** | Your Obsidian vault | Memory, Jarvis recall, Journal and Notebook all read and write here |
| **The executor** | Hermes plus a coding CLI | Jarvis, Loop, Goal Mode, Radar and Mastermind all build on it |

Every other tab builds on one of those two. Set those up first and the rest plug in
trivially, which is the whole reason this installer works in the order it does.

## The one thing worth slowing down for

**Model routing.** Every tab talks to its own model. There is no shared pipeline.

| Job | Model | Config file |
|---|---|---|
| Free on-device building | a small local model | `~/.fcc/.env` |
| Coding agents | Claude, or a named `:free` model | `~/.fcc/.env` |
| Hermes, and so Jarvis | a capable OpenRouter model | `~/.hermes/profiles/<active>/.env` |
| Video authoring | a strong model | per tool |

Small local models are excellent at fast on-device building and are not built to drive
Hermes' tool loop or author video. Matching each job to the right class of model is what
makes the whole thing sing. AI assistants sometimes try to unify everything onto one
model to be tidy, which is the one thing to watch for.

`preflight.sh` checks this, and `routing.json` is the spec it actually reads. Edit that
file and the check changes with it.

## Managing API keys

```bash
./keys.sh --setup     # guided, one at a time
```

For each key you see what it costs, what it unlocks, and the exact URL to get it, then:

```
[a] add now   [s] skip for now   [n] never ask   [q] stop here
```

**Add** takes the key with input hidden, stores it, writes it wherever that tab
actually reads it, and validates it against the provider immediately. A mistyped key is
caught when you paste it, not weeks later.

```bash
./keys.sh --list      # what every key costs and unlocks
./keys.sh --check     # re-validate everything against the providers
./keys.sh --where     # every file each key gets written to
./keys.sh --discover  # read your installed pack to confirm those paths
```

`--discover` is worth running after every pack update. Destinations occasionally move,
and it reads the truth off your own copy rather than trusting this repo's manifest.

Full detail in **KEYS.md**.

## Optional tabs

```bash
./tabs.sh             # what is installed
./tabs.sh --list      # what each needs, costs, and what it is good at
./tabs.sh --add wordpress
```

Each tab checks its prerequisites first and stops rather than half-installing. Every tab
carries a suggestion: `take`, `maybe` or `skip`. Those say what tends to be worth setting
up **first** if you already own dedicated tools for the same job. They are not a ranking
of quality, and every tab does what it says. Edit `tabs.json` to match your priorities.

## Security

```bash
./vault.sh --audit    # the one worth running monthly
```

It checks file permissions, leftover plaintext, **shell history for pasted keys**, `.env`
files sitting inside git repos, and keys exported in your shell. Those last two are how
keys actually leak: not someone reading your disk, but a file getting committed.

**About the store, honestly.** `vault.sh` can keep the master copy in `age`, macOS
Keychain or 1Password. That protects the master copy in backups and sync, and on a locked
machine. It does **not** mean your keys are encrypted while you use Agent OS: the eight
files each tab reads must stay plaintext, because those tools have no vault support.

So if you run `./keys.sh --apply` and leave it, your keys sit in plaintext on disk, the
same as they would with no store at all. What the store buys you is a spare copy, which
is what makes this safe:

```bash
./vault.sh --session-start   # write the keys out, ready to work
./vault.sh --session-end     # strip them from disk again
```

Without a spare copy, stripping them would just be deleting them.

**Full-disk encryption is worth more than everything above combined.** Turn on FileVault
or LUKS first. **SECURITY.md** is explicit about the limits.

## Updating

Agent OS builds on a dozen separate open-source projects, each with its own release cycle.

```bash
./update.sh           # read-only. What is installed
./update.sh --all     # update everything, then re-verify
```

The app itself needs a freshly downloaded pack:

```bash
./update.sh --pack --from ~/Downloads/agent-os
./update.sh --rollback     # if a build fails
```

It backs up first and preserves `~/.agentic-os`, `~/.hermes`, `~/.fcc`, your vault and
your notes. Then re-run `./keys.sh --discover`, since destinations sometimes move.

## Automating the checks

```bash
./schedule.sh --install   # daily read-only health check at 07:00
```

Writes a dated report into your Obsidian vault, so agents reading the vault can answer
"is anything wrong today" from real data.

**Deliberately not automated:** the app itself, Ollama models and Hermes. Agent OS is
actively developed and new features land often, so updates are worth applying while you
are at the keyboard and can see what changed. An unattended update also needs a manually
downloaded pack, so it could not be fully automated in any case.

---
---

# REFERENCE

## Every file

| File | What it is |
|---|---|
| `aos` | **The one command to remember.** A thin dispatcher over everything below |
| `setup.sh` | Installs whatever is missing, in dependency order |
| `preflight.sh` | Read-only health check. Run any time |
| `install.sh` | The six-stage spine. Idempotent, resumable, gate-enforced |
| `keys.sh` | Guided key setup, fan-out, live validation, destination discovery |
| `vault.sh` | The key store, the security audit, and session mode |
| `tabs.sh` | Optional tabs, one at a time, with dependency checks |
| `update.sh` | Updates the app and every project behind the tabs. Backup and rollback |
| `healthcheck.sh` | Non-interactive report, written into your vault. Cron-safe |
| `schedule.sh` | Puts the health check on a daily cron |
| `uninstall.sh` | Removes what this created, in graduated stages |
| `test.sh` | Automated tests in a sandboxed HOME. Run after any change |
| `test-regressions.sh` | Guards the bug classes that are easy to reintroduce. Asserts behaviour, not text |
| `lib.sh` | Shared gate checks, so preflight and install can never disagree |
| `bootstrap.ps1` | Windows to WSL2 handoff |
| `README.md` | The short path: install it, run it, get unstuck |
| `REFERENCE.md` | This file. Every script, every flag, the long explanations |
| `RUNBOOK.md` | The agent-facing document, dependency-ordered |
| `KEYS.md` | Every API key: source, cost, what it unlocks |
| `SECURITY.md` | What the key store protects, and what it does not |
| `routing.json` | The model routing spec, read by the routing check |
| `keys.json` | Key catalogue with evidence for every destination |
| `tabs.json` | Tab catalogue: prerequisites and what each tab is good at |
| `.routing-parse.js` | Parses routing.json into the routing gate's patterns |
| `.strip-json-keys.js` | Removes key fields from JSON configs, for purge and uninstall |

## Every flag

Every script also accepts `--version` and, where it changes anything, `--dry-run`.

**aos** — the dispatcher, and the only thing worth memorising
```
(no args)   setup.sh              install whatever is missing
status      setup.sh --status     what is working right now
check       preflight.sh          the same, with a fix line for each
keys        keys.sh --setup       add or check API keys
tabs        tabs.sh               the optional tabs
update      update.sh             update the app and everything behind it
audit       vault.sh --audit      plaintext exposure report
log         the transcript of the last setup run
vault / test / uninstall / schedule / health   the matching script
version, help
```
Every extra argument passes straight through: `./aos tabs --add wordpress` is
`./tabs.sh --add wordpress`. The scripts all stay callable on their own.

**setup.sh** — installs whatever is missing
```
--status        what is working. Installs nothing
--verbose       print every command as it runs, instead of into the log
--dry-run       show every step, change nothing
--minimal       spine only, skip the optional tabs  (--no-tabs is the same)
--ask           confirm each install and pause between steps (implies --verbose)
--stop-on-fail  halt at the first failing stage instead of stepping over it
--no-keys       skip the key wizard and every other prompt, for unattended runs
--app-dir P     point at the Agent OS source folder explicitly
--port N        use a port other than 3737
--yes           accepted and ignored, this is the default
```
Exit code is 0 when all six stages pass, 1 when anything still needs you.

**Where the output went.** A normal run prints one line per thing. The full transcript
of every child script is appended to `~/.agent-os-install/setup.log`, which `./aos log`
opens. `--verbose` skips the log and prints everything to the screen, which is what
every run used to do.

**preflight.sh** — read-only health check
```
--expect N    mark stage N as intentionally absent
--unexpect N  start reporting stage N again
--app-dir P   point at the Agent OS source folder
--port N      check a different port
```

**install.sh** — the six-stage spine
```
--from N            resume at stage N
--stage N           run only stage N (bypasses the already-installed skip)
--keep-going        record a failing gate and carry on to the next stage
--no-prompt         never block on a human step, name it and skip it
--no-hermes         skip stage 5 (records it as intentional)
--fix-claude-tab    clear an empty ANTHROPIC_API_KEY and exit
```

**keys.sh** — guided setup, fan-out, validation
```
--setup     guided, one key at a time, with live validation
--list      what each key costs and unlocks
--status    what is set, masked
--apply     write stored keys to every destination
--check     re-validate everything against the providers
--where     every file each key gets written to
--discover  read your installed pack to confirm those paths
--tier T    filter to core / useful / optional / skip
--names     machine-readable list of keys that are set
--has KEY   exit 0 if set, 1 if not
```

**vault.sh** — the key store and audit
```
--init            set up the store (plain, age, Keychain or 1Password)
--backend B       force age, keychain, op or plain
--set KEY         store one secret, typed hidden
--rm KEY          remove one secret
--list            secret names only, never values
--import          pull in a plaintext key file, then shred it
--status          which backend, how many secrets
--audit           plaintext exposure report
--purge           strip keys from destination files
--session-start   write keys out, ready to work
--session-end     strip them again
```

**tabs.sh** — optional tabs
```
--list          what each tab needs, costs and unlocks
--add ID        install one tab
--check ID      verify one tab
--recommended   install everything marked 'take' that is not already there
--count         "5 of 20", for scripts that only want the number
--yes           do not ask before installing each one
--no-prompt     never block on a human step, name the tab and skip it
```

**update.sh** — the app and every project behind the tabs
```
(no flags)         read-only inventory of what is installed
--all              update everything, then re-verify
--safe             low-risk components only (cron-safe)
--only ID          update one component
--pack --from DIR  update the app from a newly downloaded pack
--rollback         undo the last app update
```
Components: `pack` `models` `hermes` `opencode` `omniroute` `openseo` `python-libs` `system` `docs`

**healthcheck.sh** — cron-safe report
```
--quiet      write the report, print nothing
--no-vault   do not write into the Obsidian vault
```
Exit codes: 0 all clear, 1 warnings, 2 action needed.

**schedule.sh** — daily automation
```
--status      what is currently scheduled
--install     daily read-only health check
--updates     ALSO weekly safe updates on Sunday
--remove      remove everything this added
--time HH:MM  choose the hour (default 07:00)
```

**uninstall.sh** — graduated removal, dry run by default
```
(no flags)    show what would be removed, remove nothing
--scheduled   cron entries only
--state       also state, logs and update backups
--keys        also key files in their destinations
--vault       also destroy the key store (asks you to type DESTROY)
--all         all of the above, confirming each stage
```

**test.sh** — the test suite
```
--verbose    show why a failure happened
--only NAME  run a subset
```

**test-regressions.sh** — the bugs worth never repeating
```
--verbose    show why a failure happened
```

## The six stages

| Stage | Name | Gate |
|---|---|---|
| 0 | Prerequisites | node 20+, python 3.10+, curl, git, lsof, age, rsync |
| 1 | Dashboard | `http://localhost:3737` returns a page |
| 2 | Memory bus | Memory tab renders your notes |
| 3 | Free local brain | Agent Factory builds something in ~15 seconds |
| 4 | Model routing | each config holds the right class of model |
| 5 | Executor | Hermes completes a two-step tool task |

## Common questions

| Symptom | Cause |
|---|---|
| Dashboard will not open | Server not running, you used https, or not Chrome |
| Port 3737 in use | Old terminal still open. Use `--port 3738` |
| "local model not reachable" | Ollama not running, or no model pulled |
| Hermes does nothing | Missing OpenRouter key, or pointed at a small local model |
| Claude tab wants an API key | Empty `ANTHROPIC_API_KEY=`. Run `./install.sh --fix-claude-tab` |
| Memory tab empty | Vault path unset or wrong |
| Videos are colour blobs | Video pointed at a small model. Not a renderer fault |
| `pip install hermes-agent` fails | Python below 3.10 |
| A tab is unstyled or missing | That feature is in a newer release. Update the pack rather than rebuilding the tab |
| "Waiting for another run to finish" forever | A crashed run left a lock. Fixed in 1.2.0; on older versions, `rm -rf ~/.agent-os-install/lock` |

## What these scripts will never do

1. **No browser logins.** `claude login` and similar are yours to run. It stops and waits.
2. **No card details, ever.** It hands you the URL. You create the key.
3. **No hand-coding a missing tab.** If one is missing it is in a newer release, so
   updating the pack is the right fix.
4. **No secrets in argv or shell history.** Values are typed with echo off, because
   anything in argv is visible to every process via `ps`.
5. **`ANTHROPIC_API_KEY` is refused.** The Claude tab uses `claude login`, and an empty
   value takes precedence over it.

These are enforced by tests, not just documented.

## Relationship to `Check My Setup.command`

The pack ships its own health check, which tells you which **features** are configured.
`preflight.sh` tells you whether the **dependency chain** is sound, in order, including
model routing. They answer different questions and both are useful. Run the pack's one to
see what exists, and this one to see the order things need to come up in.

## Testing

```bash
./test.sh                 # 87 tests in a sandboxed HOME, your real config untouched
./test-regressions.sh     # 14 more, guarding bugs that have actually happened here
./test.sh --verbose       # show why a failure happened
./test.sh --only keys     # a subset
```

CI runs both suites plus shellcheck and a secret scan on Linux and macOS.

Every test in `test-regressions.sh` has been confirmed to **fail** when its fix is
reverted, by deliberately breaking the thing it protects. A regression test that passes
either way is worse than none, because it reads like coverage.

## Known limits

- **Destination files must stay plaintext.** The tools reading them have no vault support.
- **Key destinations are verified** against a specific pack build, each citing the file
  and line it came from. Pack versions move, so run `./keys.sh --discover` after updating.
- **macOS Keychain and 1Password are covered by stubbed tests**, which verify this code
  calls them correctly but not that the real tools behave as expected.
- **Verified end to end on Linux only**, against `agent-os-pack-2026-08-16`: the dashboard
  built and served, the key store and fan-out, the audit, and the health check. Stage 3
  (Ollama), stage 5 (Hermes) and `update.sh --pack` have not been run for real. All three
  are optional and fail without taking anything with them, but treat them as less
  travelled. Try `--pack` on a copy first, since it rsyncs over your installed pack.

---
