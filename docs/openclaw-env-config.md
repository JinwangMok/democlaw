# OpenClaw Environment Variable Configuration Reference

This document captures every environment variable used to configure the OpenClaw
container's connection to the vLLM OpenAI-compatible LLM provider, along with
the JSON configuration file format that is generated from those variables at
container startup.

---

## How Configuration Works

The OpenClaw container uses a **belt-and-suspenders** strategy so that the vLLM
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

### Primary vLLM Connection Variables

These are the canonical source variables read by `entrypoint.sh`. All other
groups are derived from these.

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `VLLM_BASE_URL` | `http://vllm:8000/v1` | Full base URL of the vLLM OpenAI-compatible API. Uses the container hostname `vllm` on the shared `democlaw-net` network. Change only if the vLLM container has a different hostname or port. |
| `VLLM_API_KEY` | `EMPTY` | API key sent in `Authorization: Bearer` headers. vLLM accepts any non-empty string by default; set `EMPTY` or any placeholder value. |
| `VLLM_MODEL_NAME` | `Qwen/Qwen3-4B-AWQ` | HuggingFace model identifier that vLLM is serving. Must match the `MODEL_NAME` passed to the vLLM container. |
| `VLLM_MAX_TOKENS` | `4096` | Maximum number of tokens per LLM response. |
| `VLLM_TEMPERATURE` | `0.7` | Sampling temperature (`0.0` = deterministic, `1.0+` = more random). |

### vLLM Readiness-Wait Variables

Used by `entrypoint.sh` to poll the vLLM `/health` endpoint before starting
OpenClaw.

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `VLLM_HEALTH_RETRIES` | `60` | Maximum number of polling attempts before giving up. |
| `VLLM_HEALTH_INTERVAL` | `5` | Seconds between each polling attempt. Total wait = `VLLM_HEALTH_RETRIES × VLLM_HEALTH_INTERVAL` = 300 s by default. |

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
| `OPENAI_API_BASE` | `http://vllm:8000/v1` | `VLLM_BASE_URL` | Base URL for the OpenAI-compatible endpoint. Used by older OpenAI SDK versions and many third-party libraries. |
| `OPENAI_BASE_URL` | `http://vllm:8000/v1` | `VLLM_BASE_URL` | Same as above; used by OpenAI SDK v4+ and newer libraries. Both are set for maximum compatibility. |
| `OPENAI_API_KEY` | `EMPTY` | `VLLM_API_KEY` | API key in the OpenAI SDK format. Set to any non-empty placeholder. |
| `OPENAI_MODEL` | `Qwen/Qwen3-4B-AWQ` | `VLLM_MODEL_NAME` | Default model identifier used in API requests. |

### OpenClaw-Specific LLM Provider Variables

Exported by `entrypoint.sh` for OpenClaw's native LLM provider configuration
path.

| Variable | Default Value | Maps From | Description |
|----------|---------------|-----------|-------------|
| `OPENCLAW_LLM_PROVIDER` | `openai-compatible` | (hardcoded) | LLM provider type. Must be `openai-compatible` for vLLM. |
| `OPENCLAW_LLM_BASE_URL` | `http://vllm:8000/v1` | `VLLM_BASE_URL` | Base URL of the OpenAI-compatible API endpoint. |
| `OPENCLAW_LLM_API_KEY` | `EMPTY` | `VLLM_API_KEY` | API key for the LLM provider. |
| `OPENCLAW_LLM_MODEL` | `Qwen/Qwen3-4B-AWQ` | `VLLM_MODEL_NAME` | Model identifier to request from the provider. |
| `OPENCLAW_LLM_MAX_TOKENS` | `4096` | `VLLM_MAX_TOKENS` | Maximum tokens per response. |
| `OPENCLAW_LLM_TEMPERATURE` | `0.7` | `VLLM_TEMPERATURE` | Sampling temperature. |

---

## JSON Configuration File

`entrypoint.sh` writes the following JSON to `${OPENCLAW_CONFIG}` (default:
`/app/config/config.json`) at every container startup, substituting the resolved
environment-variable values:

```json
{
  "llm": {
    "provider": "openai-compatible",
    "baseUrl": "<VLLM_BASE_URL>",
    "apiKey": "<VLLM_API_KEY>",
    "model": "<VLLM_MODEL_NAME>",
    "maxTokens": <VLLM_MAX_TOKENS>,
    "temperature": <VLLM_TEMPERATURE>
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
    "baseUrl": "http://vllm:8000/v1",
    "apiKey": "EMPTY",
    "model": "Qwen/Qwen3-4B-AWQ",
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
| `llm.baseUrl` | `VLLM_BASE_URL` | Full URL ending in `/v1`, e.g. `"http://vllm:8000/v1"` |
| `llm.apiKey` | `VLLM_API_KEY` | Any non-empty string; vLLM default accepts `"EMPTY"` |
| `llm.model` | `VLLM_MODEL_NAME` | HuggingFace model ID as loaded by vLLM, e.g. `"Qwen/Qwen3-4B-AWQ"` |
| `llm.maxTokens` | `VLLM_MAX_TOKENS` | Integer, e.g. `4096` |
| `llm.temperature` | `VLLM_TEMPERATURE` | Float in `[0.0, 2.0]`, e.g. `0.7` |
| `server.host` | hardcoded | `"0.0.0.0"` — bind to all interfaces |
| `server.port` | `OPENCLAW_PORT` | Integer TCP port, e.g. `18789` |

---

## Overriding Values at Runtime

All primary variables can be overridden in the project `.env` file (copy from
`.env.example`) or passed directly as container environment flags.

**Via `.env` file (recommended):**

```bash
# .env
VLLM_BASE_URL=http://vllm:8000/v1
VLLM_API_KEY=EMPTY
VLLM_MODEL_NAME=Qwen/Qwen3-4B-AWQ
VLLM_MAX_TOKENS=4096
VLLM_TEMPERATURE=0.7
OPENCLAW_PORT=18789
```

**Via Docker/Podman `--env` flags (runtime override):**

```bash
docker run \
  -e VLLM_BASE_URL=http://vllm:8000/v1 \
  -e VLLM_API_KEY=EMPTY \
  -e VLLM_MODEL_NAME=Qwen/Qwen3-4B-AWQ \
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

- The `VLLM_BASE_URL` must be resolvable **from inside the OpenClaw container**.
  On the shared `democlaw-net` Docker/Podman network, the vLLM container is
  reachable as `vllm` (set via `--network-alias vllm` and `--hostname vllm`
  when launching the vLLM container).
- Both `OPENAI_API_BASE` and `OPENAI_BASE_URL` are set simultaneously for
  maximum compatibility across OpenAI SDK versions and third-party Node.js
  LLM libraries.
- The `llm.provider` field in `config.json` is always hardcoded to
  `"openai-compatible"` — this is the only provider supported in this setup.
- `VLLM_API_KEY` / `OPENAI_API_KEY` / `OPENCLAW_LLM_API_KEY` can be set to any
  non-empty string when connecting to an unprotected vLLM instance.
  `EMPTY` is the conventional placeholder.
