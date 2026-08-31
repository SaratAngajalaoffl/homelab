# openclaw Stack Context

## Glossary

**openclaw-stack** — compose project `openclaw-stack` in `containers/openclaw/`. Self-hosted [OpenClaw](https://openclaw.ai) personal AI assistant/agent gateway — reads/organizes email, manages calendar, and talks to chat apps (Telegram/Discord/Slack/etc.), with all context and skills living on this host rather than a vendor's cloud.

**openclaw-gateway** — `ghcr.io/openclaw/openclaw` image, the long-running service. A single Node process multiplexes the control UI, HTTP API (`/v1/chat/completions`, `/tools/invoke`, ...), and websocket RPC all on port `18789`. No other ports are published or needed.

**openclaw-cli** — same image, run one-off via `docker compose --profile cli run --rm openclaw-cli <args>` (onboarding, `channels add`, `dashboard --no-open`, etc.). It shares `openclaw-gateway`'s network namespace (`network_mode: service:openclaw-gateway`) so it can talk to the gateway at localhost. It's behind a compose `profiles: ["cli"]` gate specifically so `up-all-stacks.sh`'s blanket `docker compose up -d` doesn't start it as a phantom long-running service — it has no `restart:` policy and is meant to exit after each invocation.

**`edge` network** — only `openclaw-gateway` joins it (same shape as every other HTTP-facing stack — see root `CONTEXT.md`). No `ports:` entry: NPM reaches it at `openclaw_gateway:18789` over the docker network, same pattern as `atuin_server` and `portainer`.

**Blast radius is higher than most stacks here** — unlike atuin (E2E encrypted, server only sees ciphertext) or netbird (a tunnel), a valid `OPENCLAW_GATEWAY_TOKEN` grants control of an agent that can read/send email, hit arbitrary configured tools, and act on connected chat accounts. Treat that token, and every provider/channel API key in `openclaw.env`, with at least the care of a root credential — never commit `openclaw.env`, rotate the token if it's ever exposed in a log or screenshot.

**Sandbox mode is off by default** — the compose file has a commented-out `/var/run/docker.sock` bind mount for `agents.defaults.sandbox` (per-task containerized tool execution). Enabling it hands the gateway container the host's docker socket, which is a materially bigger blast radius than the default in-process execution. Only uncomment it (and the matching `group_add: DOCKER_GID`) if you deliberately want sandboxed tool calls and understand that trade-off.

**Data**:
- `homelab-conf/openclaw/state` → `/home/node/.openclaw` — `openclaw.json` config, agent auth profiles.
- `homelab-conf/openclaw/auth-secrets` → `/home/node/.config/openclaw` — auth encryption key material, kept outside the main state dir on purpose (matches upstream's Docker guide).
- `homelab-data/openclaw/workspace` → `/home/node/.openclaw/workspace` — the agent's own working directory (files it reads/writes/generates while doing tasks); this is bulk agent-produced content rather than app config, hence `homelab-data` not `homelab-conf`.

**Domain** — `openclaw.smugiwara.com`, same public-NPM-with-app-level-auth pattern as every other stack (see `.setup`). The gateway's own token requirement is the access control, not network isolation — same trust model already used for `portainer` (docker socket access) and `netbird` (Dex IdP) on this host.
