# vLLM OpenAI-Compatible API Reference

This document describes the OpenAI-compatible REST API exposed by the DemoClaw vLLM
container (`democlaw-vllm`), how to reach it from the host, and how to verify it
is working correctly.

---

## Base URL

The vLLM container listens on **port 8000** inside the container and publishes that
port to the Linux host:

| Access context | Base URL | Notes |
|----------------|----------|-------|
| **From the host** (browser, curl, SDK) | `http://localhost:8000/v1` | Use after `./scripts/start-vllm.sh` |
| **From another container** on `democlaw-net` | `http://vllm:8000/v1` | Resolved via container hostname / network alias |
| **Custom host port** | `http://localhost:${VLLM_HOST_PORT}/v1` | Set `VLLM_HOST_PORT` in `.env` to override `8000` |

> **How the port gets published:** `start-vllm.sh` passes
> `-p ${VLLM_HOST_PORT}:${VLLM_PORT}` (default `8000:8000`) to `docker run` /
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
curl -sf http://localhost:8000/health && echo "vLLM is up"
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
      "id": "Qwen/Qwen3-4B-AWQ",
      "object": "model",
      "created": 1700000000,
      "owned_by": "vllm"
    }
  ]
}
```

### Chat completion (`/v1/chat/completions`)

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-4B-AWQ",
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
  "model": "Qwen/Qwen3-4B-AWQ",
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

### Automated endpoint validation

Use the bundled validation script to test all three key endpoints in one step:

```bash
./scripts/validate-api.sh
```

This checks:
1. `GET /health` — liveness probe (expects HTTP 200)
2. `GET /v1/models` — model listing (expects valid OpenAI JSON with ≥ 1 model)
3. `POST /v1/chat/completions` — end-to-end inference (expects valid chat completion JSON)

To skip the inference step (e.g. in CI without a GPU):

```bash
SKIP_INFERENCE_TEST=true ./scripts/validate-api.sh
```

Custom base URL (e.g. remote server):

```bash
VLLM_BASE_URL=http://192.168.1.10:8000 ./scripts/validate-api.sh
```

Exit code `0` = all checks passed; `1` = one or more checks failed.

---

## Using the API with client libraries

### Python — OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="EMPTY",          # vLLM accepts any non-empty string by default
)

response = client.chat.completions.create(
    model="Qwen/Qwen3-4B-AWQ",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user",   "content": "Explain vLLM in one sentence."},
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
    model="Qwen/Qwen3-4B-AWQ",
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
  model: "Qwen/Qwen3-4B-AWQ",
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
VLLM_HOST_PORT=8001   # publish to host port 8001 instead of 8000
VLLM_PORT=8000        # internal container port (keep at 8000 unless image is rebuilt)
```

After changing `VLLM_HOST_PORT`, the host-side base URL becomes:

```
http://localhost:8001/v1
```

The container-internal base URL used by OpenClaw (`http://vllm:8000/v1`) is
**not** affected by `VLLM_HOST_PORT` — it always routes via the container network.

See [`.env.example`](../.env.example) for all configurable variables.

---

## Container networking

The vLLM container is launched with:

```
--network democlaw-net
--hostname vllm
--network-alias vllm
-p ${VLLM_HOST_PORT}:${VLLM_PORT}
```

This means:

- **Host access:** `http://localhost:8000/v1` (via the published port)
- **Container access:** `http://vllm:8000/v1` (via the `democlaw-net` bridge network)

The OpenClaw container is configured with `VLLM_BASE_URL=http://vllm:8000/v1` by
default so it reaches vLLM over the container network without going through the
host port.

---

## API authentication

By default, vLLM runs in **no-auth mode** — it accepts requests with any
`Authorization` header value (or none at all). This is safe for an isolated,
trusted container network.

To require a Bearer token, set `VLLM_API_KEY` to a non-empty value in `.env`:

```bash
# .env
VLLM_API_KEY=my-secret-key
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
| `curl: (7) Failed to connect` | Container not started or port blocked | Run `./scripts/start-vllm.sh`; check firewall |
| `HTTP 000` from `validate-api.sh` | Server not yet ready (model loading) | Wait and retry; monitor with `docker logs -f democlaw-vllm` |
| `/v1/models` returns empty `data: []` | Model weights still loading | First run downloads ~5 GB; check logs |
| `HTTP 401 Unauthorized` | `VLLM_API_KEY` set but request has no token | Add `-H "Authorization: Bearer <key>"` |
| Wrong model in `/v1/models` | `MODEL_NAME` env var mismatch | Verify `MODEL_NAME=Qwen/Qwen3-4B-AWQ` in `.env` |

For the full healthcheck output:

```bash
./scripts/healthcheck.sh --vllm-only
```
