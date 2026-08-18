# Agent OS Plus: Runbook

**Audience: an AI agent, or someone troubleshooting.** For a human doing a first install,
read `README.md` instead, which starts with the two commands you actually need.

Use this alongside the pack's own `SETUP-WITH-AI.md`. The pack's guides are organised per
feature, which is ideal for going straight to one thing. This one is organised by
dependency, which suits standing the whole system up in a single pass.

Companion machine-readable files: `routing.json` (the model routing spec, which the
routing gate actually reads), `keys.json` (key catalogue and destinations), `tabs.json`
(optional tab prerequisites).

## The mental model

It is not 40 tabs. It is two spines with plugins.

| Spine | What it is | What it carries |
|---|---|---|
| **The bus** | Your Obsidian vault | Memory, Jarvis recall, Journal, Notebook and Pipeline all read and write here, so they wait until a vault is connected |
| **The executor** | Hermes, plus whichever coding CLI | Jarvis, Loop, Goal Mode, Radar and Mastermind all build on it |

Every other tab builds on one of those two, or is a standalone tool. Set the two spines
up first and everything else plugs in trivially, which is why this runbook starts there.

---

## The six stages

Each stage ends in a gate: a single check that either passes or fails. Stages are
dependency-ordered, so a failure at stage 2 will produce confusing results at stages 3, 4
and 5 that have nothing to do with those stages. Fix the lowest number first.

| Stage | Name | Gate |
|---|---|---|
| 0 | Prerequisites | `node -v` is 20+, and Python 3.10+ exists if you want Hermes |
| 1 | Dashboard | `http://localhost:3737` returns a page |
| 2 | Memory bus | Memory tab renders your notes as a star map |
| 3 | Free local brain | Agent Factory builds a starfield in about 15 seconds |
| 4 | Model routing | Each config file holds the *right class* of model |
| 5 | Executor | Hermes completes a two-step tool task |

Stage 4 is the one worth slowing down for. Matching each job to the right class of model
is what makes the whole system sing.

---

## Running it

Full instructions are in `README.md`. The short form:

```bash
./setup.sh              # everything, in dependency order
./preflight.sh          # read-only, re-verify at any time
./test.sh               # 83 tests, sandboxed
```

Mark any stage you deliberately skip, so the daily health check treats it as intentional
rather than flagging it every morning:

```bash
./preflight.sh --expect 5      # stage 5 is intentionally absent
./preflight.sh --unexpect 5    # undo
```

## Stage detail

### Stage 0: prerequisites

Node 20+ is a hard requirement because the dashboard is a Next.js app.
Python 3.10+ is needed for **Hermes only**, so if `pip install hermes-agent` fails, check
your Python version first. macOS ships 3.9.6, so you will want a newer one alongside it.

### Stage 1: dashboard

`npm install` then `npm run build` on first run, two to five minutes. After that,
launches take seconds. If port 3737 is occupied, use `--port 3738` rather than killing
whatever is there blindly.

Use `http://`, not https. Use Chrome, because voice input relies on the browser's own
speech recognition.

### Stage 2: the memory bus

Auto-detected at `~/Documents/Obsidian Vault`, `~/Obsidian Vault`, or `~/Obsidian`.
Anywhere else and you set `vaultRoot` in `~/.agentic-os/config.json`.

The system only ever **reads** your existing notes. Everything it writes goes into a
clearly named `Agentic OS/` folder. It never edits notes you wrote.

What you put in the vault determines output quality more than any model choice:
who you are, what the business does, your sites and their keywords, your team, and
above all **case studies and real results**. That last one is what makes generated
content specific to you rather than generic.

### Stage 3: free local brain

Ollama plus one model. Costs nothing, runs entirely on your machine, nothing leaves it.

`gemma2` is better at animation and generative art. `qwen2.5-coder:14b` is sharper at
full apps and wants 16GB+ of RAM. Same local speed, so pick by job. Swap any time by
editing `~/.fcc/.env`.

First build of a session is five to ten seconds slower while the model loads into
memory. After that it stays warm.

### Stage 4: model routing

The whole stage in one sentence: **every tab talks to its own model, and there is no
shared pipeline.**

| Job | Model class | Config file |
|---|---|---|
| Free on-device building | small local model | `~/.fcc/.env` |
| Coding agents | Claude, or a named `:free` model | `~/.fcc/.env` |
| Hermes, and so Jarvis | a capable OpenRouter model | `~/.hermes/profiles/<name>/config.yaml` |
| Video authoring | a strong model | per tool |

Three things the gate checks:

**Small model as global default.** Small local models are excellent at fast on-device
building, and are not built to drive Hermes' tool loop or author video. AI assistants
sometimes try to unify everything onto one model to be tidy, which is the thing to watch
for.

**Stealth and alpha models.** Names like `owl-alpha`, `sonoma-*`, anything ending
`-alpha`. Labs offer these free for a few weeks, then retire them or move them to paid.
Prefer a named `:free` model so your setup keeps working.

**The Claude tab and API keys.** The Claude tab authenticates with `claude login`, not an
API key. An **empty** `ANTHROPIC_API_KEY=` left in a `.env.local` by any tool takes
precedence over that login, so the tab then asks for a key.
`./install.sh --fix-claude-tab` clears it.

Two inheritance rules worth memorising:

- Jarvis runs on Hermes' model, so improving Hermes improves Jarvis.
- Subagents inherit the model of whatever spawned them.

The full spec is in `routing.json`. Hand that file to an AI agent rather than letting it
guess.

### Stage 5: executor

Hermes needs an OpenRouter key at `~/.hermes/profiles/main/.env`. Many models are free.
With no credit you get 50 requests a day; $5 of credit once raises that to 1,000 a day
while still using free models.

Two responses you will see and what they mean:

- **HTTP 402, requires more credits.** Your free model was retired. Swap to a current
  named `:free` model.
- **HTTP 429, free-models-per-day.** You hit the 50/day cap. Add credit, or switch to
  local for unlimited.

Profiles are isolated Hermes instances, each with its own model, persona, memory and
thread. Treat them like staff members:

```bash
hermes profile create seo
hermes profile create research --clone
hermes profile list
```

---

## Updating

```bash
./update.sh                              # what is installed, read-only
./update.sh --all                        # everything, then re-verify
./update.sh --pack --from ~/Downloads/agent-os
./update.sh --rollback                   # undo the last app update
```

Agent OS builds on a dozen separate open-source projects, each with its own release
cycle, so updating the pack alone leaves those at their previous versions. `--all` covers
Ollama models, Hermes, opencode, OmniRoute, OpenSEO, the Python libraries and system
packages, then runs preflight and validates your keys, because updates can move things.

`./update.sh --only docs` refreshes the install guides inside your vault, which is the
pro tip below.

## Where settings live, and what survives an update

Updates replace the entire app folder. These three locations are never touched:

1. `~/.agentic-os/config.json` : vault path, your name, model routing, tool paths
2. `~/.hermes/` : profiles, keys, personas, sessions
3. Your Obsidian vault : your notes

Also preserved: `~/.fcc/.env`, credential folders, and local project folders you made.

**Put every customisation in `config.json`, never in the source files.** If a tweak you
made reverts to default after an update, this is why.

---

## The pro tip worth doing on day one

Copy the pack's `install/` folder into your vault, for example at `Agent OS/Install/`,
and refresh it after each update.

Because the OS reads your vault, your agents can then pull the real setup docs as
context when you ask them to troubleshoot. "Why won't my Memory tab connect?" gets
answered against the actual steps rather than guesswork.

Copy this runbook and `routing.json` in there too.

---

## Triage table

Symptom first, cause second, because that is the direction you meet them in.

| Symptom | Cause |
|---|---|
| Dashboard will not open | Server not running, or you used https, or not Chrome |
| Port 3737 already in use | Old terminal still open. Use `--port 3738` |
| `npm install` red errors | Node below 20, or a download hiccup. Run it again |
| "local model not reachable" | Ollama not running, no model pulled, or `~/.fcc/.env` names a model you have not pulled |
| Jarvis silent on first load | Browsers block audio until you interact. Click anywhere once |
| Jarvis listens but never speaks | No ElevenLabs key. Listening is free, speaking needs the key |
| Hermes does nothing | Missing `OPENROUTER_API_KEY`, or Hermes pointed at a small local model |
| Claude tab wants an API key | Empty `ANTHROPIC_API_KEY=` in `.env.local`. Run `--fix-claude-tab` |
| Memory tab empty | `vaultRoot` unset or pointing at a folder that does not exist |
| Videos are five-second colour blobs | Video authoring pointed at a small model. Not a renderer fault |
| Everything slow, fans spinning | Too many local models at once. One big job at a time |
| A tab looks unstyled or missing | That feature is in a newer release. Update the pack rather than rebuilding the tab |
| `pip install hermes-agent` fails | Python below 3.10 |

For anything not listed: open your coding agent **inside the pack folder** and paste the
error verbatim. It can read the whole folder, which is more context than any generic
troubleshooting will have.

---

## After it works

Start with four tabs and add more as you need them. Forty is a lot of surface area to
learn at once, and which four matter depends entirely on your work. A reasonable default
is Memory, one coding agent, Hermes, and whichever single output tab matches what you do.

Run `./preflight.sh` after each pack update, since new releases sometimes move things.
