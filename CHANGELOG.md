# Agent OS Plus — Changelog

> This is the changelog for **Agent OS Plus**, not for Agent OS itself.
> The pack's own changelog is one level up at `../CHANGELOG.md`.

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
