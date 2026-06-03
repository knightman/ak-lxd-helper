# 005 — pi agent (earendil-works/pi) wired to lab-004 vLLM

- **Status:** 🟢 done (2026-06-02)
- **Skills:** `lxd-vm-create`, `lxd-vm-provision`, `lxd-multi-connect`
- **Instance:** `lab-005-pi` (VM, base profile) + dependency on `lab-004-vllm`

## Goal

Build the [earendil-works/pi](https://github.com/earendil-works/pi) Node coding-agent
harness from source on a fresh VM, wire it to use lab-004's vLLM as its OpenAI-
compatible model backend, and expose a **persistent terminal interface accessible
from the LAN** so you can `ssh` in, attach to a long-lived session, and chat with
Qwen3-8B through pi.

## Inputs / parameters

| Name | Value | Notes |
|------|-------|-------|
| pi repo | `https://github.com/earendil-works/pi` | TypeScript monorepo |
| Node version | **24.x** | `.ts` script files need Node 22+; we use 24 LTS |
| provider | `vllm` (custom) | `openai-completions` API; baseUrl points at lab-004 |
| model | `Qwen/Qwen3-8B` | from lab-004 |
| ollama backend ip | `10.10.249.171:8000` | lab-004 lxdbr0 IP |
| session | persistent **tmux** via systemd user unit | survives ssh disconnects + VM reboots |

## Preconditions

- Project 004 (`lab-004-vllm`) running and serving on `0.0.0.0:8000`.
- Network: route-metric fixed so the LAN NIC wins as default (else github / npm fail).

## Steps

1. `lab.sh create lab-005-pi` (base-ubuntu profile, macvlan LAN access).
2. `apt install -y nodejs` from **NodeSource setup_24.x** (NOT distro nodejs 20 —
   it can't run pi's `.ts` build scripts).
3. `su - lab -c 'git clone --depth=1 https://github.com/earendil-works/pi ~/pi'`.
4. `cd ~/pi && npm install --ignore-scripts && npm run build` (detached + poll).
5. Write `~lab/.pi/agent/models.json` registering `vllm` provider with `api:
   openai-completions`, `baseUrl: http://10.10.249.171:8000/v1`, `apiKey: "none"`
   (lowercase — pi treats UPPERCASE values as env-var references).
6. Install `pi-tmux` wrapper at `~lab/.local/bin/pi-tmux`:
   ```bash
   exec tmux new -A -s pi "/home/lab/pi/pi-test.sh --provider vllm --model 'vllm/Qwen/Qwen3-8B'"
   ```
7. systemd user unit `~lab/.config/systemd/user/pi-session.service` running the
   same tmux session; enable lingering (`loginctl enable-linger lab`) so it
   auto-starts at VM boot; `systemctl --user enable --now pi-session.service`.

## Acceptance criteria

- [x] pi CLI built (`packages/coding-agent/dist/cli.js` exists; `pi --help` works).
- [x] `~lab/.pi/agent/models.json` validates against pi's schema (no warnings).
- [x] From lab-005, `curl http://10.10.249.171:8000/v1/models` lists `Qwen/Qwen3-8B`.
- [x] `pi --provider vllm --model vllm/Qwen/Qwen3-8B --no-tools -p "..."` returns generated text.
- [x] tmux session `pi` exists and the systemd user unit is `enabled`.
- [x] LAN reachable: `ssh lab@<lab-005-LAN-IP>` from the laptop logs in.

## Verification

```bash
lab/tests/lab-004-005.sh         # full suite (proves 004 + 005 end-to-end)
```

## How to use it (remote terminal access)

From the LAN (laptop) — `ssh -t` is required for any non-interactive pi command;
without it pi waits on a TTY/stdin and hangs.

```bash
# interactive (recommended): drops into the persistent tmux session
ssh -t lab@192.168.1.152 pi-tmux
# Ctrl-b d to detach; the session keeps running (systemd user unit + lingering)

# one-shot from the shell:
ssh -t lab@192.168.1.152 \
  "/home/lab/pi/pi-test.sh --provider vllm --model vllm/Qwen/Qwen3-8B --no-tools -p 'YOUR PROMPT'"

# shell alias on your laptop:
alias pi='ssh -t lab@192.168.1.152 pi-tmux'
```

`pi-tmux` is symlinked into `/usr/local/bin` so the bare name resolves over a
non-login `ssh host pi-tmux` command (the user `~/.local/bin` is NOT on PATH for
non-login SSH). If you ever rebuild the VM, re-add the symlink:
`ln -sf /home/lab/.local/bin/pi-tmux /usr/local/bin/pi-tmux`.

Note: pi/Qwen3 emits `<think>...</think>` reasoning blocks before the final answer
(that's Qwen3's normal behavior, not a bug).

### Web search / tools (added 2026-06-03)

pi can search the web via the **`pi-web-access`** extension (zero-config Exa, no API
key): `~/pi/pi-test.sh install npm:pi-web-access` (registers in
`~/.pi/agent/settings.json` → `"packages"`; exposes `web_search`, `code_search`,
`fetch_content`). Optional Perplexity/Gemini fallbacks via `~/.pi/web-search.json`.

**Prerequisite — tool calling on the backend:** lab-004's vLLM must be served with
`--enable-auto-tool-choice --tool-call-parser hermes` (now baked into its systemd
unit). Without them every tool call 400s — this, not the search extension, was why
search failed. (The default `@ollama/pi-web-search` path is a dead end here: it uses
Ollama's hosted search and needs `ollama signin`/`OLLAMA_API_KEY`, and ollama isn't
installed.) Verified: `pi -p "use web_search to find the latest Node LTS"` returns a
real, current answer sourced from live results.

Auth: key-based SSH is the easiest path — append your laptop pubkey to
`~lab/.ssh/authorized_keys` (via `lxc exec lab-005-pi` from the host if you can't
type the password through a non-TTY caller). Otherwise password auth: `lab` /
`$LAB_VM_PASSWORD` from `.env` (dashboard's **Overview → LAN access** card shows
them). Password prompts need a real terminal — Claude Code's `!` prefix and
non-interactive callers have no TTY and fall back to the missing `ssh-askpass`.

## Teardown

```bash
lab/scripts/lab.sh delete lab-005-pi
# leave lab-004-vllm unless tearing that down too
```

## Results

**2026-06-02 — PASS.** All 10 checks in `lab/tests/lab-004-005.sh` green:
- pi CLI built; `models.json` registers the `vllm` provider + Qwen3-8B.
- From lab-005, `/v1/models` on lab-004 lists `Qwen/Qwen3-8B`.
- `pi --provider vllm --model vllm/Qwen/Qwen3-8B -p "..."` returned a real
  completion (Qwen3 emits `<think>...</think>` then the final answer).
- tmux session `pi` running; systemd user unit `enabled` (auto-restarts).
- LAN access: `ssh lab@192.168.1.152` works from the Mac; `pi-tmux` drops into the
  persistent session.

Lessons (folded into the framework):
- Node 20 can't run pi's `.ts` build scripts (no native TS); needs Node 22+/24.
- pi's `models.json` migrates all-UPPERCASE values to `$ENV` references; use
  lowercase literals for things like `apiKey: "none"`.
- pi's `--model` accepts `<provider>/<id>` form; `vllm/Qwen/Qwen3-8B` routes to our custom provider.
