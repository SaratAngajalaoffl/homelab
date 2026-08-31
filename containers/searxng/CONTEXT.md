# searxng Stack Context

## Glossary

**searxng-stack** — compose project `searxng-stack` in `containers/searxng/`. Self-hosted [SearXNG](https://docs.searxng.org/) metasearch engine — aggregates results from Google/Bing/DuckDuckGo/etc. without an API key or per-query cost, and gives every other stack in this repo a shared, private web-search backend.

**Why it exists** — `webui`, `openclaw`, and `hermes` each want a web-search tool for their agents/chat, and each supports SearXNG natively as a key-free provider. Standing up one shared instance avoids paying for (or rate-limiting on) a per-app cloud search API (Brave, Tavily, ...) three times over.

**No auth of its own** — same shape as `ollama` (see its CONTEXT.md). Internally, `webui`/`openclaw-gateway`/`hermes-gateway` reach it unauthenticated at `searxng:8080` over `edge` — every edge-network container already trusts every other one by container name. Publicly, unlike ollama's API-only bearer-token snippet, this is a browsable search UI a human will actually visit — so `websearch.smugiwara.com` is gated with an **NPM Access List** (built-in HTTP Basic Auth, no custom nginx snippet needed) instead. See `.setup` for exact steps.

**JSON API must be explicitly enabled** — the official image only serves HTML by default; `format=json` 403s until `search: formats: [html, json]` is added to the generated `settings.yml`. All three consuming apps (webui's `SEARXNG_QUERY_URL`, openclaw's and hermes's `SEARXNG_BASE_URL`) call the JSON endpoint, so this isn't optional — see `.setup` step 2.

**Config bootstrap is automatic, not baked in** — the entrypoint copies its bundled `settings.template.yml` into the mounted `/etc/searxng` volume on first boot (only if `settings.yml` isn't already there) and generates a random secret key in the same pass. This repo doesn't ship a pre-filled `settings.yml` — it's generated on the host at `homelab-conf/searxng/config/settings.yml` the first time the stack comes up, then hand-edited once for the JSON format. Runtime data this repo doesn't own, consistent with the root CLAUDE.md convention.

**No redis/valkey sidecar** — upstream's reference compose adds a `valkey` container for its bot-detection rate limiter, aimed at wide-open public instances getting scraped. This instance's only public exposure is behind NPM's Basic Auth, and its only unauthenticated exposure is the trusted `edge` network, so the limiter isn't load-bearing here. Add it later if abuse becomes a problem.

**Data** — `homelab-conf/searxng/config` → `/etc/searxng` — `settings.yml` (engines, secret key, search formats) and `uwsgi.ini`. No separate data/cache volume (upstream's `core-data` volume is disk cache for the bot-detection limiter this stack doesn't run).

**Consumers**:
- `webui` — `SEARXNG_QUERY_URL=http://searxng:8080/search?q=<query>`, `WEB_SEARCH_ENGINE=searxng`, `ENABLE_WEB_SEARCH=true` (`containers/webui/docker-compose.yml`). These env vars only unlock the capability — in native tool-calling mode, `search_web` isn't injected into a model's toolset until "Web Search" is also checked under that model's Default Features (`Workspace > Models > Edit`) or toggled per-message via the `+` button. Confirmed by testing: without that checkbox, the model reports having no web-search tool at all even with these env vars set and searxng verified reachable.
- `openclaw` — `SEARXNG_BASE_URL=http://searxng:8080` (`containers/openclaw/docker-compose.yml`). Only takes effect if no other search-provider key (`BRAVE_API_KEY` etc.) is set in `openclaw.env` — openclaw auto-detects providers in a fixed priority order, SearXNG last.
- `hermes` — `SEARXNG_BASE_URL=http://searxng:8080` (`containers/hermes/docker-compose.yml`), plus a one-time `web.search_backend: searxng` in the runtime `config.yaml` (state dir, not this repo — see `.setup`).

**Domain** — `websearch.smugiwara.com`, `http` to NPM, forwarded to `searxng:8080`. Unlike every other proxy host in this repo (app-level token/no auth), this one uses NPM's own Access List feature because SearXNG has no login screen of its own and is meant to be browsed directly, not just called by API clients.
