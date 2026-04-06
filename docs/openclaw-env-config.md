# OpenClaw Environment Variable Configuration Reference

This document captures every environment variable used to configure the OpenClaw
container's connection to the llama.cpp OpenAI-compatible LLM provider, along with
the JSON configuration file format that is generated from those variables at
container startup.

---

## How Configuration Works

The OpenClaw container uses a **belt-and-suspenders** strategy so that the llama.cpp
backend is picked up regardless of how the OpenClaw application reads its config:

1. **JSON config file** — `entrypoint.sh` writes `/app/config/config.json` from
   env vars at every container start.
2. **Standard OpenAI env vars** — `OPENAI_API_BASE`, `OPENAI_BASE_URL`,
   `OPENAI_API_KEY`, `OPENAI_MODEL` are exported for Node.js LLM client libraries
   that honour the OpenAI SDK conventions.
3. **OpenClaw-specific env vars** — `OPENCLAW_LLM_*` vars are exported for
   OpenClaw's native provider configuration path.

All three layers are populated from the same source values so they always stay
in sync.

---

## Environment Variables

### Primary llama.cpp Connection Variables

These are the canonical source variables read by `entrypoint.sh`. All other
groups are derived from these.

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `LLAMACPP_BASE_URL` | `http://llamacpp:8000/v1` | Full base URL of the llama.cpp OpenAI-compatible API. Uses the container hostname `llamacpp` on the shared `democlaw-net` network. Change only if the llama.cpp container has a different hostname or port. |
| `LLAMACPP_API_KEY` | `EMPTY` | API key sent in `Authorization: Bearer` headers. llama.cpp accepts any non-empty string by default; set `EMPTY` or any placeholder value. |
| `LLAMACPP_MODEL_NAME` | `gemma-4-E4B-it` | Model identifier that llama.cpp is serving. Must match the `MODEL_NAME` passed to the llama.cpp container. |
| `LLAMACPP_MAX_TOKENS` | `4096` | Maximum number of tokens per LLM response. |
| `LLAMACPP_TEMPERATURE` | `0.7` | Sampling temperature (`0.0` = deterministic, `1.0+` = more random). |

### llama.cpp Readiness-Wait Variables

Used by `entrypoint.sh` to poll the llama.cpp `/health` endpoint before starting
OpenClaw.

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `LLAMACPP_HEALTH_RETRIES` | `60` | Maximum number of polling attempts before giving up. |
| `LLAMACPP_HEALTH_INTERVAL` | `5` | Seconds between each polling attempt. Total wait = `LLAMACPP_HEALTH_RETRIES × LLAMACPP_HEALTH_INTERVAL` = 300 s by default. |

### OpenClaw Server Variables

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `OPENCLAW_PORT` | `18789` | TCP port the OpenClaw web dashboard listens on inside the container. |
| `OPENCLAW_HOST` | `0.0.0.0` | Bind address for the OpenClaw HTTP server. `0.0.0.0` makes it accessible from outside the container. |
| `OPENCLAW_CONFIG_DIR` | `/app/config` | Directory where `config.json` is written at startup. |
| `OPENCLAW_CONFIG` | `/app/config/config.json` | Full path to the generated JSON config file. |
| `NODE_ENV` | `production` | Node.js environment mode. |

### Standard OpenAI-Compatible Environment Variables

Exported by `entrypoint.sh` for Node.js libraries that use the OpenAI SDK
conventions (e.g. `openai`, LangChain.js, LiteLLM).

| Variable | Default Value | Maps From | Description |
|----------|---------------|-----------|-------------|
| `OPENAI_API_BASE` | `http://llamacpp:8000/v1` | `LLAMACPP_BASE_URL` | Base URL for the OpenAI-compatible endpoint. Used by older OpenAI SDK versions and many third-party libraries. |
| `OPENAI_BASE_URL` | `http://llamacpp:8000/v1` | `LLAMACPP_BASE_URL` | Same as above; used by OpenAI SDK v4+ and newer libraries. Both are set for maximum compatibility. |
| `OPENAI_API_KEY` | `EMPTY` | `LLAMACPP_API_KEY` | API key in the OpenAI SDK format. Set to any non-empty placeholder. |
| `OPENAI_MODEL` | `gemma-4-E4B-it` | `LLAMACPP_MODEL_NAME` | Default model identifier used in API requests. |

### OpenClaw-Specific LLM Provider Variables

Exported by `entrypoint.sh` for OpenClaw's native LLM provider configuration
path.

| Variable | Default Value | Maps From | Description |
|----------|---------------|-----------|-------------|
| `OPENCLAW_LLM_PROVIDER` | `openai-compatible` | (hardcoded) | LLM provider type. Must be `openai-compatible` for llama.cpp. |
| `OPENCLAW_LLM_BASE_URL` | `http://llamacpp:8000/v1` | `LLAMACPP_BASE_URL` | Base URL of the OpenAI-compatible API endpoint. |
| `OPENCLAW_LLM_API_KEY` | `EMPTY` | `LLAMACPP_API_KEY` | API key for the LLM provider. |
| `OPENCLAW_LLM_MODEL` | `gemma-4-E4B-it` | `LLAMACPP_MODEL_NAME` | Model identifier to request from the provider. |
| `OPENCLAW_LLM_MAX_TOKENS` | `4096` | `LLAMACPP_MAX_TOKENS` | Maximum tokens per response. |
| `OPENCLAW_LLM_TEMPERATURE` | `0.7` | `LLAMACPP_TEMPERATURE` | Sampling temperature. |

---

## JSON Configuration File

`entrypoint.sh` writes the following JSON to `${OPENCLAW_CONFIG}` (default:
`/app/config/config.json`) at every container startup, substituting the resolved
environment-variable values:

```json
{
  "llm": {
    "provider": "openai-compatible",
    "baseUrl": "<LLAMACPP_BASE_URL>",
    "apiKey": "<LLAMACPP_API_KEY>",
    "model": "<LLAMACPP_MODEL_NAME>",
    "maxTokens": <LLAMACPP_MAX_TOKENS>,
    "temperature": <LLAMACPP_TEMPERATURE>
  },
  "server": {
    "host": "0.0.0.0",
    "port": <OPENCLAW_PORT>
  }
}
```

### Concrete example with default values

```json
{
  "llm": {
    "provider": "openai-compatible",
    "baseUrl": "http://llamacpp:8000/v1",
    "apiKey": "EMPTY",
    "model": "gemma-4-E4B-it",
    "maxTokens": 4096,
    "temperature": 0.7
  },
  "server": {
    "host": "0.0.0.0",
    "port": 18789
  }
}
```

### JSON field descriptions

| JSON Path | Env Var Source | Expected Value |
|-----------|---------------|----------------|
| `llm.provider` | hardcoded | `"openai-compatible"` — selects the OpenAI-compatible provider |
| `llm.baseUrl` | `LLAMACPP_BASE_URL` | Full URL ending in `/v1`, e.g. `"http://llamacpp:8000/v1"` |
| `llm.apiKey` | `LLAMACPP_API_KEY` | Any non-empty string; llama.cpp default accepts `"EMPTY"` |
| `llm.model` | `LLAMACPP_MODEL_NAME` | Model identifier as loaded by llama.cpp, e.g. `"gemma-4-E4B-it"` |
| `llm.maxTokens` | `LLAMACPP_MAX_TOKENS` | Integer, e.g. `4096` |
| `llm.temperature` | `LLAMACPP_TEMPERATURE` | Float in `[0.0, 2.0]`, e.g. `0.7` |
| `server.host` | hardcoded | `"0.0.0.0"` — bind to all interfaces |
| `server.port` | `OPENCLAW_PORT` | Integer TCP port, e.g. `18789` |

---

## Overriding Values at Runtime

All primary variables can be overridden in the project `.env` file (copy from
`.env.example`) or passed directly as container environment flags.

**Via `.env` file (recommended):**

```bash
# .env
LLAMACPP_BASE_URL=http://llamacpp:8000/v1
LLAMACPP_API_KEY=EMPTY
LLAMACPP_MODEL_NAME=gemma-4-E4B-it
LLAMACPP_MAX_TOKENS=4096
LLAMACPP_TEMPERATURE=0.7
OPENCLAW_PORT=18789
```

**Via Docker/Podman `--env` flags (runtime override):**

```bash
docker run \
  -e LLAMACPP_BASE_URL=http://llamacpp:8000/v1 \
  -e LLAMACPP_API_KEY=EMPTY \
  -e LLAMACPP_MODEL_NAME=gemma-4-E4B-it \
  -e OPENCLAW_PORT=18789 \
  democlaw/openclaw:latest
```

---

## Variable Precedence

When the same setting can come from multiple sources, the order of precedence
(highest to lowest) is:

1. `--env` / `-e` flag on the `docker`/`podman run` command
2. `.env` file loaded by `start.sh` / `start-openclaw.sh`
3. `ENV` defaults baked into the Dockerfile image

---

## Notes

- The `LLAMACPP_BASE_URL` must be resolvable **from inside the OpenClaw container**.
  On the shared `democlaw-net` Docker/Podman network, the llama.cpp container is
  reachable as `llamacpp` (set via `--network-alias llamacpp` and `--hostname llamacpp`
  when launching the llama.cpp container).
- Both `OPENAI_API_BASE` and `OPENAI_BASE_URL` are set simultaneously for
  maximum compatibility across OpenAI SDK versions and third-party Node.js
  LLM libraries.
- The `llm.provider` field in `config.json` is always hardcoded to
  `"openai-compatible"` — this is the only provider supported in this setup.
- `LLAMACPP_API_KEY` / `OPENAI_API_KEY` / `OPENCLAW_LLM_API_KEY` can be set to any
  non-empty string when connecting to an unprotected llama.cpp instance.
  `EMPTY` is the conventional placeholder.
