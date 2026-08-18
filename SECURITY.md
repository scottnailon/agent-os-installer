# Security: what this protects, and what it does not

**Read this bit first, because the honest version is smaller than it sounds.**

`vault.sh` is two useful things and one overstated one.

**Useful: one place for your keys.** You enter each key once, and `keys.sh --apply`
writes it to all eight scattered files Agent OS reads keys from. That is convenience,
not security, and it is the main reason the file exists.

**Useful: the audit.** `--audit` finds keys pasted into shell history and `.env` files
sitting inside git repos. That is how keys actually leak in practice. Run it monthly.

**Overstated: the encryption.** Encrypting the master copy does **not** mean your keys
are encrypted while you use Agent OS. The eight destination files must stay plaintext,
because Hermes and the other tools read them directly and have no vault support. If you
run `--apply` and walk away, your keys sit in plaintext on disk exactly as they would
with no store at all.

What encryption does buy: the master copy stays safe in backups and cloud sync, and on a
locked machine if you use the Keychain or 1Password backend.

What the store really buys: a spare copy. That is what makes `--session-end` safe, since
without it, stripping the plaintext files would just be deleting your only copy.

**Turn on full-disk encryption.** FileVault or LUKS is worth more than everything in
this document combined. If you do nothing else, do that.

---

## The commands

```bash
./vault.sh --init      # pick the best backend available on this machine
./vault.sh --import    # pull in an existing plaintext key file, then shred it
./vault.sh --set KEY   # store a secret, typed, hidden, never in argv or history
./vault.sh --list      # secret NAMES only, never values
./vault.sh --audit     # find plaintext keys lying around this machine
./vault.sh --purge     # strip keys from destination files when locking down
```

Once a vault exists, `keys.sh` reads from it automatically. `./keys.sh --status` shows
its source, so you can confirm at a glance whether you are on `[vault: age]` or
`[~/.agent-os-keys.env (plaintext)]`.

---

## Backends

Chosen automatically in this order:

| Backend | Protection | Unlock | Best for |
|---|---|---|---|
| `op` | 1Password vault | your 1Password session | teams already on 1Password |
| `keychain` | macOS Keychain, hardware-backed on Apple Silicon | your macOS login | Mac, and the best default there |
| `age` | scrypt-encrypted file | a passphrase, per read | Linux, WSL, anywhere portable |
| `plain` | file mode 600 only | none | fallback, explicitly insecure |

`keychain` is the right choice on a Mac: no passphrase to juggle, it unlocks with your
login, and on Apple Silicon the key material is protected by the Secure Enclave.

`age` is the portable option and the one to use on WSL. It asks for the passphrase on
each read, which is mildly annoying and is the price of not caching a decryption key on
disk.

---

## What this actually protects against

Mode 600 alone only stops **other user accounts** on the machine. That is a narrow
threat and probably not yours.

An encrypted vault additionally protects against:

- **Backups capturing your keys.** Time Machine and cloud sync copy `~` wholesale. An
  encrypted store means those backups hold ciphertext.
- **Casual and automated filesystem reads.** Anything that greps your home directory for
  `API_KEY=` finds nothing useful. This includes AI agents you point at your home folder,
  which matters here because that is exactly what Agent OS tells you to do.
- **Accidental disclosure.** Screen shares, pasted file contents, a repo you did not
  realise you were inside.
- **Shell history and process lists.** Secrets are typed with echo off, read from the
  terminal, and never passed as command arguments. Anything in argv is visible to every
  process on the machine through `ps`.

---

## What it cannot protect against, and why

**The destination files must remain plaintext.**

Hermes reads `~/.hermes/profiles/main/.env`. Thumbnail Studio reads
`~/.claude/skills/youtube-thumbnails/.env`. None of these tools support a vault, so
`keys.sh --apply` has to write real values into real files for anything to work.

So the accurate description is: **a vault protects the master copy and shrinks the
plaintext window. It does not close it.** Any claim otherwise is wrong.

Three specific things remain true regardless of backend:

1. **Anything running as your user can read the destination files.** Including any AI
   coding agent you run in your home directory, every npm `postinstall` script, and any
   browser extension with filesystem access.
2. **Unlocking is transitive.** With `keychain`, once you are logged in, anything running
   as you can ask the keychain for those items. It protects a stolen disk, not a running
   session.
3. **Older backups may still hold plaintext.** `--import` shreds the current file. It
   cannot reach into Time Machine snapshots or a cloud sync history.

If your threat model includes a compromised local account, no file-based secret store
fixes it. That needs per-key scoping and short-lived credentials, which none of these
upstream tools support.

---

## The audit

`./vault.sh --audit` is the honest picture, and worth running monthly. It checks:

- **Destination file permissions.** Flags anything not 600, with the `chmod` to fix it.
- **A leftover plaintext master file** when a vault is already configured.
- **Shell history**, for pasted keys in `.bash_history` and `.zsh_history`. This is the
  most common real-world leak and almost nobody checks it.
- **Git exposure.** Whether any key file sits inside a repo and is not gitignored.
- **Environment leakage.** Exported keys in your current shell, which every child process
  inherits, including agents you launch from that shell.
- **`ANTHROPIC_API_KEY`**, which should never be set at all.

---

## Session mode, for shrinking the plaintext window

The destination files cannot be encrypted. That is a hard constraint, not an oversight:
the tools reading them have no vault support, so `--apply` must write real values into
real files for anything to work.

What you can control is **how long those files exist**:

```bash
./vault.sh --session-start   # write keys out, start working
./vault.sh --session-end     # strip them again
```

This turns "plaintext on disk permanently" into "plaintext while you are actually
working". That is a real reduction and it is **not** a fix. During a session the exposure
is identical to having no vault at all.

`--audit` warns if a session has been left open, because the failure mode here is
forgetting to close one and quietly getting no benefit at all.

Worth being blunt about the limit: if your threat model includes something already running
as your user, session mode buys you very little, since that something can simply wait for
a session. It helps against backups, disk theft, screen shares, and casual filesystem
scans, which is most of what actually happens.

## Purge, for handing the machine over

```bash
./vault.sh --purge      # strips key lines from destination files
./keys.sh --apply       # puts them back when you return
```

Use it before a repair, a handover, a demo on someone else's screen, or a backup you do
not control. It preserves unrelated settings in those files and leaves `.prepurge`
copies, which you should delete too if you are genuinely locking down.

---

## Practical hardening, in order of value

1. **Turn on FileVault** (Mac) or LUKS (Linux). Full-disk encryption is worth more than
   everything on this page, because it covers the destination files a vault cannot.
   If you do only one thing from this document, do this one.
2. **Run `./vault.sh --init`** and pick `keychain` on Mac, `age` elsewhere.
3. **`./vault.sh --import`**, then let it shred the plaintext file.
4. **Never export keys in your shell profile.** Let `keys.sh --apply` write files instead,
   so agents you launch do not inherit them through the environment.
5. **Use free-tier and scoped keys** wherever the provider allows it. A key that can only
   spend $5 is a smaller problem than one that cannot.
6. **Rotate anything you have ever pasted into a chat window**, including into an AI
   assistant. Treat it as disclosed.
7. **Run `--audit` monthly**, and after every pack update.

---

## The rules that do not change

- No script here will ever enter your card details or log in on your behalf. If any tool
  or guide offers to, refuse.
- Secrets are never passed as command arguments.
- Values are masked in all output. Nothing prints a whole key.
- `ANTHROPIC_API_KEY` is refused outright. The Claude tab uses `claude login`, and an
  empty value silently breaks it.
- `--check` is read-only against each provider and cannot incur charges.
