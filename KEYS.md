# API Keys: one place, one file

Agent OS reads keys from eight different locations in three different formats. Nobody
can hold that in their head, which is why the usual state of an install is "some tabs
work and I'm not sure why."

This folder replaces that with one file you edit and one command that distributes it.

---

## The one command

```bash
./keys.sh --setup
```

Walks you through every key, one at a time, in priority order. For each one you see what
it costs, what it unlocks, and the exact URL to get it, then choose:

```
[a] add now   [s] skip for now   [n] never ask   [q] stop here
```

Choosing **add** takes the key with the input hidden, stores it in the vault, writes it
to the files that tab actually reads, and **validates it against the provider on the
spot**. A mistyped or revoked key is caught at the moment you paste it, not weeks later
when a tab quietly fails.

Choosing **never** records it so you are not asked again. Choosing **quit** stops
cleanly, and re-running picks up where you left off.

Nothing is required. Skipping a key simply leaves that tab quiet.

### The underlying commands

```bash
./keys.sh --apply     # fan stored values out to every location that needs them
./keys.sh --check     # re-validate everything against the providers
./vault.sh --set KEY  # add or replace a single key directly
```

Everything else is read-only:

```bash
./keys.sh             # status: what is set, masked
./keys.sh --list      # what each key costs, unlocks, and where to get it
./keys.sh --where     # every destination path, so you can see the scatter
./keys.sh --list --tier core    # just the ones that matter
```

The master file lives at `~/.agent-os-keys.env`, **outside** the app folder, so it
survives pack updates. Mode 600. Never printed in full, never sent anywhere.

`--check` is the one people skip and then regret. It calls each provider read-only and
tells you whether the key is valid, revoked, or valid-but-out-of-credit. Finding that
out now is much cheaper than finding out mid-workflow, because the symptom at that
point looks like a broken tab rather than a billing problem.

---

## When each key gets added

You do not add keys upfront. You add one when you want the tab it unlocks.

| Point | Key | Why then |
|---|---|---|
| Stages 0 to 3 | **none** | Dashboard, Memory, and free local building need nothing |
| Stage 4 | `claude login` only | Browser OAuth against your Claude plan, not a key |
| Stage 5 | `OPENROUTER_API_KEY` | The one key that unlocks everything agentic |
| Later, per tab | one at a time | Only when you actually want that tab |

Adding a key later is the same command: `./keys.sh --setup` skips anything already set
and asks only about the rest. Or go straight at one with `./vault.sh --set KEY_NAME`,
then `./keys.sh --apply`. Both store into the encrypted vault, so there is no point at
which you have to go back to a plaintext file.

So: **one key prompt during install.** Everything after is deliberate and optional.

---

## The full table

### Core, set this one

| Key | From | Cost | Unlocks |
|---|---|---|---|
| `OPENROUTER_API_KEY` | openrouter.ai/keys | free tier | Hermes, Jarvis, Loop, Goal Mode, Fusion, Mastermind, OmniRoute, Hy3, OpenMontage, Radar |

Free tier gives 50 requests a day. Adding $5 of credit once raises that to 1,000 a day
while still using free models. Two errors worth recognising: **HTTP 402** means your
free model was retired, so swap to a current named `:free` model. **HTTP 429** means
you hit the daily cap.

### Useful

| Key | From | Cost | Unlocks |
|---|---|---|---|
| `ELEVENLABS_API_KEY` | elevenlabs.io | free tier | Jarvis speech |
| `OPENAI_API_KEY` | platform.openai.com | ~$0.04/image | Thumbnail Studio |
| `DATAFORSEO_LOGIN` + `DATAFORSEO_PASSWORD` | dataforseo.com | per lookup | OpenSEO |

Two things people get wrong here.

Jarvis **listens for free** using the browser's own speech recognition. The ElevenLabs
key only makes it **speak**. If you don't need it talking back, skip it.

The OpenAI API is **prepaid and completely separate from ChatGPT Plus**. Paying for
ChatGPT does not fund the API. An `insufficient_quota` error is an empty API credit
balance, not a broken tool.

### Optional

`GEMINI_API_KEY` (live translate), `YT_API_KEY` (Astros higher limits, keyless works
fine by default), `SERPAPI_KEY` (competitor SERP layer on SEO Research),
`OLLAMA_API_KEY` (GLM Code cloud models only, local Ollama needs nothing),
`GLM_API_KEY`, `SAKANA_API_KEY` (cheaper alternative judge for Loop).

### Skip

`HEYGEN_API_KEY`, `SUNO_API_KEY`, `HUNTER_API_KEY`, `APOLLO_API_KEY`,
`FIRECRAWL_API_KEY`.

These are per-seat services whose own interfaces are better than the tab wrapping them,
or lead-finding that stops at names and addresses with no sequencing behind it. If you
already run a CRM and a design workflow, none of these earn their place.

---

## Needs no key at all

Worth knowing before you go shopping:

- Local Ollama building (Agent Factory, Game Studio, Agent Kanban), free forever
- Hermes Astros, keyless tier reads channel RSS and works day one
- Jarvis listening, browser speech recognition
- Claude tab, `claude login`
- Free Claude Code, OmniRoute, opencode
- SEO Research, Google Search Console OAuth, read-only, no API key
- NotebookLM, `nlm login`

---

## The one key that is blocked on purpose

`ANTHROPIC_API_KEY` is refused by `keys.sh` and is not in the template.

The Claude tab authenticates with `claude login` against your Claude plan. Setting this
key switches you to pay-per-token. Setting it **empty**, which a well-meaning setup step
often does, silently overrides your login and breaks the tab with a message that sends
you looking for a missing key rather than an extra one.

If you hit it: `./install.sh --fix-claude-tab`

---

## Security

- The master file is mode 600, in your home directory, locked to your user account.
- Every destination file is chmod 600 on write.
- `--apply` preserves unrelated settings in destination files and replaces only the
  line for that key. It never clobbers a file wholesale.
- Values are masked in all output. Nothing prints a whole key.
- `--check` is read-only against each provider and cannot incur charges.
- No script here will ever enter your card details or perform a login for you. If any
  tool or guide offers to, refuse.
- Never paste a key into a chat window, including into an AI assistant.

---

## If a destination is marked "inferred"

`./keys.sh --where` labels each destination `verified` or `inferred`.

**Verified** means the path is stated explicitly in the pack's own docs.
**Inferred** means it follows the pack's convention but is not documented, so check that
tab after applying. If a tab still reports a missing key, set it in that tab's own
settings UI and tell me which one, so the manifest can be corrected.

The pack changes weekly, so re-run `./keys.sh --check` after each update.
