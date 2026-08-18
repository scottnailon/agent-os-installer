# Contributing

Pull requests welcome. Two rules keep this useful.

## 1. Never commit a secret

This toolkit stores no keys of its own and the repo must stay that way. CI fails the
build on anything that looks like a key. `.gitignore` already excludes every env file,
the vault, and the generated logs.

If you are adding an example, use an obvious placeholder such as `sk-xxxx`. The
placeholder detector recognises those and refuses to treat them as real keys.

## 2. Every change ships with a test

```bash
./test.sh              # all tests, sandboxed HOME
./test.sh --verbose    # show why something failed
./test.sh --only keys  # a subset
```

Tests run against a throwaway `HOME` under `/tmp`, so they cannot touch your real
config, vault or cron. Add a case that fails before your fix and passes after it.

## Correcting a key destination

`keys.json` destinations carry an `evidence` field citing the file and line the claim
came from. If you correct a path, update the evidence too. A test fails if any
destination lacks it.

The fastest way to find the truth for your own pack version:

```bash
./keys.sh --discover
```

That reads the installed pack and reports where each key name is genuinely referenced.
Pack versions move, so a correction that is right today may need revisiting.

## What this project will not do

- Enter card details, or log in on anyone's behalf
- Pass secrets as command arguments, since argv is visible via `ps`
- Write `ANTHROPIC_API_KEY`, which breaks the Claude tab when empty
- Hand-code a replacement for a tab that ships in the pack

Those are enforced by tests under "Safety invariants". Please do not weaken them.
