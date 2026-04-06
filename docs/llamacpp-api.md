# llama.cpp OpenAI-Compatible API Reference

This document describes the OpenAI-compatible REST API exposed by the DemoClaw llama.cpp
container (`democlaw-llamacpp`), how to reach it from the host, and how to verify it
is working correctly.

---

## Base URL

The llama.cpp container listens on **port 8000** inside the container and publishes that
port to the Linux host:

| Access context | Base URL | Notes |
|----------------|----------|-------|
| **From the host** (browser, curl, SDK) | `http://localhost:8000/v1` | Use after `./scripts/start-llamacpp.sh` |
| **From another container** on `democlaw-net` | `http://llamacpp:8000/v1` | Resolved via container hostname / network alias |
| **Custom host port** | `http://localhost:${LLAMACPP_HOST_PORT}/v1` | Set `LLAMACPP_HOST_PORT` in `.env` to override `8000` |

> **How the port gets published:** `start-llamacpp.sh` passes
> `-p ${LLAMACPP_HOST_PORT}:${LLAMACPP_PORT}` (default `8000:8000`) to `docker run` /
> `podman run`, making the API reachable at `http://localhost:8000` from any
> process on the host.

---

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/health` | Liveness probe — `200 OK` when the server is accepting requests |
| `GET`  | `/v1/models` | List loaded models (OpenAI `GET /v1/models` format) |
| `POST` | `/v1/chat/completions` | Chat inference (OpenAI chat completions format) |
| `POST` | `/v1/completions` | Text completion (OpenAI legacy completions format) |
| `POST` | `/v1/embeddings` | Text embeddings (when supported by the loaded model) |

All endpoints follow the [OpenAI REST API specification](https://platform.openai.com/docs/api-reference).
Any client that works with the official OpenAI API can be pointed at
`http://localhost:8000/v1` without code changes.

---

## Verifying the API from the host

### Quick liveness check

```bash
# Expects HTTP 200 with an empty body
curl -sf http://localhost:8000/health && echo "llama.cpp is up"
```

### List loaded models

```bash
curl http://localhost:8000/v1/models | python3 -m json.tool
```

Expected response:

```json
{
  "object": "list",
  "data": [
    {
      "id": "gemma-4-E4B-it",
      "object": "model",
      "created": 1700000000,
      "owned_by": "llamacpp"
    }
  ]
}
```

### Chat completion (`/v1/chat/completions`)

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-E4B-it",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user",   "content": "What is the capital of France?"}
    ],
    "max_tokens": 128,
    "temperature": 0.7
  }' | python3 -m json.tool
```

Expected response shape:

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "created": 1700000000,
  "model": "gemma-4-E4B-it",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "The capital of France is Paris."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 29,
    "completion_tokens": 10,
    "total_tokens": 39
  }
}
```

### Gemma 4 response format notes

Gemma 4 models served via llama.cpp have a few format characteristics that
consuming applications (including OpenClaw) should handle:

| Behaviour | Detail | Handling |
|-----------|--------|----------|
| **Thinking tokens** | Gemma 4 may prefix responses with `<start_of_thinking>...</end_of_thinking>` blocks containing internal reasoning. | Strip with regex before displaying to users. |
| **Finish reason** | May return `"stop"`, `"end_turn"`, `"eos"`, or `"length"`. All are valid completion signals. | Accept any of these as a successful stop. |
| **MoE token counts** | The 26B A4B MoE variant may report different `usage` counts than dense models. | Accept any positive `completion_tokens` value. |
| **Model name** | The `model` field in responses matches the `--alias` flag (e.g. `gemma-4-E4B-it` or `gemma-4-26B-A4B-it`). | Match against `MODEL_NAME` from `.env`. |

### Automated endpoint validation

Use the bundled validation scripts to test endpoints:

**Quick health + model + chat completion check:**

```bash
./scripts/validate-chat-completion.sh
# Windows: scripts\validate-chat-completion.bat
```

This runs 7 compatibility checks:
1. Non-streaming chat completion — full OpenAI response schema
2. Streaming chat completion — SSE (Server-Sent Events) format
3. Gemma 4 thinking-token handling
4. Model name agreement (`/v1/models` vs response `model` field)
5. Multi-turn conversation (system + user + assistant history)
6. Finish reason validation (`stop`/`end_turn`/`eos`/`length`)
7. Usage token counts (`prompt_tokens` + `completion_tokens` + `total_tokens`)

Custom endpoint / model:

```bash
LLAMACPP_PORT=8001 MODEL_NAME=gemma-4-26B-A4B-it ./scripts/validate-chat-completion.sh
```

**Full E2E validation pipeline** (GPU, memory, throughput, API):

```bash
./scripts/validate-e2e.sh
# Windows: scripts\validate-e2e.bat
```

Exit code `0` = all checks passed; `1` = one or more checks failed.

---

## Using the API with client libraries

### Python — OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="EMPTY",          # llama.cpp accepts any non-empty string by default
)

response = client.chat.completions.create(
    model="gemma-4-E4B-it",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user",   "content": "Explain llama.cpp in one sentence."},
    ],
    max_tokens=128,
    temperature=0.7,
)
print(response.choices[0].message.content)
```

### Python — Streaming

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="EMPTY")

with client.chat.completions.create(
    model="gemma-4-E4B-it",
    messages=[{"role": "user", "content": "Count to 5."}],
    max_tokens=64,
    stream=True,
) as stream:
    for chunk in stream:
        delta = chunk.choices[0].delta.content or ""
        print(delta, end="", flush=True)
print()
```

### JavaScript / Node.js — OpenAI SDK

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://localhost:8000/v1",
  apiKey: "EMPTY",
});

const response = await client.chat.completions.create({
  model: "gemma-4-E4B-it",
  messages: [
    { role: "system", content: "You are a helpful assistant." },
    { role: "user",   content: "What is the capital of France?" },
  ],
  max_tokens: 128,
  temperature: 0.7,
});

console.log(response.choices[0].message.content);
```

---

## Port and URL configuration

The default port (`8000`) can be changed via environment variables or `.env`:

```bash
# .env
LLAMACPP_HOST_PORT=8001   # publish to host port 8001 instead of 8000
LLAMACPP_PORT=8000        # internal container port (keep at 8000 unless image is rebuilt)
```

After changing `LLAMACPP_HOST_PORT`, the host-side base URL becomes:

```
http://localhost:8001/v1
```

The container-internal base URL used by OpenClaw (`http://llamacpp:8000/v1`) is
**not** affected by `LLAMACPP_HOST_PORT` — it always routes via the container network.

See [`.env.example`](../.env.example) for all configurable variables.

---

## Container networking

The llama.cpp container is launched with:

```
--network democlaw-net
--hostname llamacpp
--network-alias llamacpp
-p ${LLAMACPP_HOST_PORT}:${LLAMACPP_PORT}
```

This means:

- **Host access:** `http://localhost:8000/v1` (via the published port)
- **Container access:** `http://llamacpp:8000/v1` (via the `democlaw-net` bridge network)

The OpenClaw container is configured with `LLAMACPP_BASE_URL=http://llamacpp:8000/v1` by
default so it reaches llama.cpp over the container network without going through the
host port.

---

## API authentication

By default, llama.cpp runs in **no-auth mode** — it accepts requests with any
`Authorization` header value (or none at all). This is safe for an isolated,
trusted container network.

To require a Bearer token, set `LLAMACPP_API_KEY` to a non-empty value in `.env`:

```bash
# .env
LLAMACPP_API_KEY=my-secret-key
```

Clients must then include `Authorization: Bearer my-secret-key` in every request:

```bash
curl http://localhost:8000/v1/models \
  -H "Authorization: Bearer my-secret-key"
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `curl: (7) Failed to connect` | Container not started or port blocked | Run `./scripts/start-llamacpp.sh`; check firewall |
| `HTTP 000` from `validate-api.sh` | Server not yet ready (model loading) | Wait and retry; monitor with `docker logs -f democlaw-llamacpp` |
| `/v1/models` returns empty `data: []` | Model weights still loading | First run downloads ~5.7 GB; check logs |
| `HTTP 401 Unauthorized` | `LLAMACPP_API_KEY` set but request has no token | Add `-H "Authorization: Bearer <key>"` |
| Wrong model in `/v1/models` | `MODEL_NAME` env var mismatch | Verify `MODEL_NAME=gemma-4-E4B-it` (or `gemma-4-26B-A4B-it` for DGX Spark) in `.env` |
| Thinking tokens in response | Gemma 4 includes `<start_of_thinking>` blocks | Strip with regex: `re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*', '', content, flags=re.DOTALL)` |
| Unexpected `finish_reason` | Gemma 4 may return `end_turn` or `eos` | All of `stop`, `end_turn`, `eos`, `length` are valid |

For the full healthcheck output:

```bash
./scripts/healthcheck.sh --llamacpp-only
```
