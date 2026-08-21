# Agent OS Plus

**One command sets up Agent OS. One place holds your API keys. One check tells you what is working.**

> **Agent OS Plus is not Agent OS.** Agent OS is the work of Julian Goldie from the AI
> Profit Lab and all credit for it belongs to him. This is an independent companion
> toolkit that sits alongside it in its own `agent-os-plus/` folder and never modifies
> the pack's own files. The pack ships its own README, setup guide and 44 install
> guides, and nothing here replaces those.

Agent OS is a local dashboard fronting around 40 AI tools, documented one feature at a
time so you can set up exactly the pieces you want in any order.

Agent OS Plus is the other way through the same material: it works out what is already
on the machine, installs what is not, in dependency order, and tells you in one screen
what is left. It also gives you one place to keep your API keys instead of eight, an
audit that finds keys leaking into shell history and git repos, an updater with
rollback, and a daily health check.

Free, MIT licensed, and it stores none of your secrets. Agent OS itself is community
content and requires a paid membership, see below.

---

# START HERE

## 1. Get Agent OS itself

This project is the installer. You still need the pack it installs.

1. Join the AI Profit Lab community. Membership is **$59 USD per month** and gives you
   the pack plus every update.
   **[Sign up and download AgentOS](https://www.skool.com/ai-profit-lab-7462/about?ref=82a7b15cca5a4b3185abd0d54e8c7398)**
2. Open the Agent OS lesson:
   **[Go to the lesson](https://www.skool.com/ai-profit-lab-7462/classroom/9daf24e1?md=097eb41a59b74f06a6112351c07216fa)**
3. **Scroll to the "Resources" section at the bottom of that lesson**, click the dated
   link, then click **DOWNLOAD** in the preview box.
4. Unzip `agent-os-pack-YYYY-MM-DD.zip` somewhere permanent. Not inside Downloads, and
   not inside the zip itself.

## 2. Add Agent OS Plus to it

```bash
cd /path/to/agent-os          # the folder that contains source/
git clone https://github.com/scottnailon/agent-os-plus.git agent-os-plus
```

> **It must live in its own subfolder.** The pack has its own `README.md`,
> `CHANGELOG.md` and `VERSION`. Copying this toolkit's loose files into the pack root
> would overwrite all three. Cloning into `agent-os-plus/` prevents that, and every
> script stops with an explanation if it detects it has been misplaced.
>
> Already did it? Nothing is lost. Restore the three files from your pack zip:
> ```bash
> unzip -o -j <your-pack>.zip 'agent-os/README.md' 'agent-os/CHANGELOG.md' 'agent-os/VERSION' -d .
> ```

## 3. Run one command

```bash
cd agent-os-plus
./aos
```

**That is the whole thing.** You can stop reading here.

---

## What you will see

```
Agent OS Plus 1.2.0   linux/x86_64, apt

  ok    Prerequisites       node v22.22.2
  ok    Dashboard           http://localhost:3737
  todo  Memory bus          the path to an Obsidian vault
  ok    Local brain         ollama/gemma2
  ok    Model routing       anthropic/claude-haiku-4.5
  todo  Executor            an OpenRouter key
  ok    API keys            3 of 23 set
  ok    Optional tabs       9 of 20
  ok    Security audit      nothing exposed

  4 of 6 in place.

  Needs you
    Memory bus        the path to an Obsidian vault
    Executor          an OpenRouter key

    Run ./aos again once you have those. It picks up only what is left.

  Dashboard   http://localhost:3737   (Chrome, http not https)
  Detail      ./preflight.sh
  Full log    ~/.agent-os-install/setup.log
```

One line per thing. Anything already working is detected and left alone, so a second
run is quick. Anything missing is installed without stopping to ask. Anything that
fails is noted and stepped over, so one problem cannot hide the rest.

The quiet default loses nothing. Every command of every run is written to
`~/.agent-os-install/setup.log`, and `./aos --verbose` prints it all to the screen
instead.

## The nine commands

```bash
./aos              install whatever is missing
./aos status       what is working right now
./aos check        the same, with a fix line for each thing
./aos keys         add or check your API keys
./aos tabs         the optional tabs
./aos update       update the app and every project behind it
./aos audit        where keys can currently be read in the clear
./aos log          the transcript of the last run
./aos help
```

Each is a thin wrapper over the script that does the work, and every extra argument
passes straight through, so `./aos keys --check` is exactly `./keys.sh --check`. Every
script and flag is listed in **REFERENCE.md**.

## Three things worth knowing

**You need almost no API keys.** The first four stages need none at all. Only one really
matters (OpenRouter, which has a free tier). Skipping every other key is a perfectly
valid choice, and each one you skip just leaves that tab quiet.

**Nervous? Look before you leap.** Neither of these changes anything:

```bash
./aos status         # what is working now
./aos --dry-run      # every step it would take
```

**Model routing is the one thing worth slowing down for.** Every tab talks to its own
model and there is no shared pipeline. Small local models are excellent at fast
on-device building and cannot drive Hermes' tool loop or author video. `./aos check`
tests this, and REFERENCE.md explains it.

## If you get stuck

```bash
./aos check
```

Read-only, safe any time. For anything not yet set up it gives you the exact command
that fixes it. Run this first whenever something feels off.

Deliberately skipping something? Mark it so the daily check treats it as intentional
rather than flagging it every morning:

```bash
./preflight.sh --expect 5     # stage 5 is intentionally absent
./preflight.sh --unexpect 5   # undo
```

## Running it unattended

Cron, CI, or over SSH with no terminal attached:

```bash
./aos --no-keys
```

No prompts are raised at all. Anything that genuinely needs a human, an API key or a
browser login, is named in the summary and skipped rather than left waiting on a
question nobody will answer.

---

## Why this exists

Agent OS is a genuinely impressive piece of work, and it is actively developed, with new
features arriving regularly. Its 44 guides are written per feature, which is the right
shape when you know what you want and want to go straight to it.

Agent OS Plus is for the other case: you want the whole thing standing up, in one pass,
without deciding what to do first. It adds an order of operations, one place to keep
your API keys, and a health check that tells you what is configured.

Neither replaces the other. The pack is the product. This is one on-ramp to it, and the
guides remain the reference for everything it can do.

## Publishing your own copy

```bash
git init
git add -A
git commit -m "Agent OS Plus"
git branch -M main
git remote add origin git@github.com:<you>/agent-os-plus.git
git push -u origin main
```

CI runs automatically on push: shell syntax, shellcheck, JSON validity, a secret scan, and
the full test suite on Linux and macOS.

`.gitignore` already excludes every env file, the vault, generated logs, and the Agent OS
pack itself, so a stray `agent-os/` folder in your working copy cannot be committed.

## Author

Built by **Scott Nailon**, [Sites By Design](https://sitesbydesign.com.au) and GoodHost.

Agent OS itself is not mine. It is the work of Julian Goldie from the AI Profit Lab,
membership $59 USD per month:
**[Sign up and download AgentOS](https://www.skool.com/ai-profit-lab-7462/about?ref=82a7b15cca5a4b3185abd0d54e8c7398)**

MIT licensed. Issues and pull requests welcome, see CONTRIBUTING.md.
