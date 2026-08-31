# hermes Stack Context

## Glossary

**hermes-stack** — compose project `hermes-stack` in `containers/hermes/`. Self-hosted [Hermes Agent](https://github.com/NousResearch/hermes-agent) personal AI assistant by Nous Research. A single Docker container multiplexes the OpenAI-compatible API server (port `8642`) and the web dashboard (port `9119`, enabled via `HERMES_DASHBOARD=1`) — all state (config, sessions, memories, skills, keys) lives in one mounted volume (`/opt/data`).

**hermes-gateway** — `nousresearch/hermes-agent:latest` image running a supervised `gateway run` process (managed by s6-overlay PID 1). The API server exposes OpenAI-compatible endpoints (`/v1/chat/completions`, …) on port `8642`; the dashboard serves its UI on port `9119`. Both are reached through nginx-proxy-manager over the `edge` network.

**s6 supervision** — the official Docker image uses s6-overlay as PID 1, so the gateway process is automatically restarted on crash without losing container state (no need for `restart: always` semantics). The dashboard is also a serviced s6-rc slot alongside the gateway; both appear in `docker logs hermes_gateway`.

**API server key** — the Bearer token that guards `hermes_gateway:8642`. Set as `HERMES_API_SERVER_KEY` in `hermes.env`; clients pass it as `Authorization: Bearer <key>`. The API server must be bound to `0.0.0.0` inside the container so NPM can reach it on the docker network.

**Dashboard auth** — since the dashboard binds `0.0.0.0` and is exposed on a non-loopback address via NPM, Hermes requires an authentication provider. We use the bundled basic-auth provider (set two env vars in `hermes.env`). Suitable for trusted homelab networks; not recommended for direct internet exposure without additional hardening.

**Data**:
- `homelab-conf/hermes/state` → `/opt/data` — single source of truth: `config.yaml`, `.env` (API keys), sessions, memories, skills, cron jobs, hooks, logs, and SOUL.md personality. All state is portable across upgrades since the image is stateless.

**Blast radius** — comparable to or lower than openclaw. A valid `HERMES_API_SERVER_KEY` grants access to an agent with tool execution capability and session history. The API server key plus NPM path enforcement provide access control. No docker socket mount (unlike openclaw's optional sandbox mode), so the blast radius is contained to the agent's configured tools and model provider permissions.

**Model providers** — Hermes reads keys from two places: `/opt/data/.env` (the setup wizard writes here) and compose-level `-e KEY=value` env vars (which override `.env` values). Compatible with Anthropic, OpenAI, Gemini, OpenRouter, Bedrock, Azure, and more. Can share model provider keys with the openclaw stack on the host (different files; same keys are fine).

**Domain** — `hermes.smugiwara.com` (API server) and `hermes-dashboard.smugiwara.com` (dashboard), both using `http` to NPM. Same public-NPM-with-app-level-auth pattern as every other stack (see .setup). The gateway's own API key is the gate, not network isolation — matching the trust model already used on the host.
