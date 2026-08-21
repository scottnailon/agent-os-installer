# Agent OS Plus — Changelog

> This is the changelog for **Agent OS Plus**, not for Agent OS itself.
> The pack's own changelog is one level up at `../CHANGELOG.md`.

## 1.2.0

**A quieter run**
- A normal `./setup.sh` is now one aligned line per thing instead of several screens of
  four scripts talking over each other. Nothing is lost: the full transcript of every
  run is appended to `~/.agent-os-install/setup.log`, and `--verbose` prints it to the
  screen exactly as before
- Each line says what it is and, when it is not ready, what it is waiting on in plain
  words. The summary carries the commands, so a row stays a row
- `./setup.sh --status` shows the same picture and installs nothing. It takes no lock
  either, so it works while a setup is running

**One command to remember**
- `./aos` dispatches to everything: `status`, `check`, `keys`, `tabs`, `update`,
  `audit`, `log`, `help`. Extra arguments pass straight through, so
  `./aos tabs --add wordpress` is `./tabs.sh --add wordpress`
- It chmods the scripts itself, so a bare clone works without `chmod +x *.sh` first
- Every script stays callable on its own. Nothing is hidden behind the dispatcher

**Shorter docs**
- README cut from 24KB to 8KB: install it, run it, get unstuck. The full flag surface,
  the mental model and the long explanations moved to `REFERENCE.md`

**Fixed**
- A crashed run could hold the install lock forever. The reaper used `kill -0` to decide
  whether the owner was alive, and `kill -0` succeeds on a **zombie**, a process that
  has exited but has not been reaped by its parent yet. `kill -9` on a stuck run left
  exactly that, so the lock looked live and every later run sat at "Waiting for another
  run to finish" for a process that was already dead. It now reads the process state and
  treats `Z` as gone
- A run that died between creating the lock and writing its pid left a lock with no
  owner, which nothing could ever reap. Now cleared after 20 seconds
- Any lock held for more than six hours is cleared with a warning
- `./schedule.sh --time 99:00` reported "crontab not found" instead of "Hour must be
  0-23" on any machine without cron, because it checked the environment before it
  checked what you typed. Your input is validated first now. This is why one test had
  been failing since 1.0.0 on every CI runner

**Added**
- `tabs.sh --count` prints "5 of 20", for the one-line summary
- Six more regression tests: the quiet run stays quiet, the log still gets everything,
  `--verbose` is still verbose, a zombie cannot hold the lock, an ownerless lock clears
  itself, and `./aos` works on a clone nothing has chmod'd yet

## 1.1.0

**One command, and it keeps going**
- `./setup.sh` now installs everything it finds missing without stopping to ask. The
  old confirm-each-step flow is still there as `./setup.sh --ask`
- A failing stage is recorded and stepped over instead of ending the run, so one broken
  thing no longer hides whether anything behind it would have worked. `--stop-on-fail`
  restores the old halt
- Every stage runs its gate first. A gate that already passes means that stage is
  already installed, so it is skipped rather than re-run
- One summary at the end: what was already in place, what got installed this run, what
  is still failing, and the single command that fixes the lowest failure
- `./setup.sh --no-keys` and any run without a terminal raise no prompts at all. Steps
  that genuinely need a human are named and skipped, so cron and CI runs cannot hang
- `install.sh --keep-going` and `install.sh --no-prompt`, `tabs.sh --no-prompt`
- `tabs.sh --recommended` reports which tabs it could not finish instead of failing quietly
- `--yes` on `setup.sh` is accepted and ignored, since it is now the default

## 1.0.0

First release.

**Install**
- `setup.sh`, one command that runs the whole thing in dependency order
- Six stages, each ending in a gate that must pass before the next begins
- Idempotent and resumable: re-running skips anything already working
- `preflight.sh`, a read-only health check safe to run at any time

**Keys**
- One store instead of eight scattered files. Enter each key once, `--apply` writes it
  wherever the tab that needs it actually reads from
- Guided setup showing cost, what each key unlocks, and where to get it
- Live validation against the provider as you paste, so a typo is caught immediately
- Destinations verified against a real pack build, each citing the file and line
- `--discover` reads your own installed pack to confirm those paths after an update
- Master copy can live in `age`, macOS Keychain or 1Password
- `ANTHROPIC_API_KEY` refused: the Claude tab uses `claude login`, and an empty value
  takes precedence over that login

**Security**
- `--audit` finds keys pasted into shell history, `.env` files inside git repos, loose
  permissions, and keys exported in your shell
- Session mode writes keys out only while you work and strips them afterwards
- Secrets are typed with echo off and never passed as command arguments
- SECURITY.md is explicit that destination files must stay plaintext, and that full-disk
  encryption is worth more than anything here

**Extend and maintain**
- `tabs.sh`, 20 optional tabs à la carte, each checking prerequisites before starting
- WordPress multi-site publisher with CSV bulk import
- `update.sh` covers the app plus the open-source projects behind the tabs, with backup
  and `--rollback`
- `healthcheck.sh` and `schedule.sh` for a daily report written into your Obsidian vault
- `uninstall.sh` removes only what this created, dry run by default

**Compatibility**
- Linux, macOS, and Windows via WSL2 (`bootstrap.ps1`)
- Never modifies the Agent OS pack, and stops with an explanation if placed in its root

**Testing**
- 87 automated tests in a sandboxed HOME
- CI on Linux and macOS: shell syntax, shellcheck, JSON validity, secret scan, both suites
- Verified end to end on Linux against `agent-os-pack-2026-08-16`: dashboard built and
  served, key store and fan-out, audit, and health check
