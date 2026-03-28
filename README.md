# DemoClaw

Shell-script orchestration for running [OpenClaw](https://github.com/openclaw) AI assistant with a self-hosted [vLLM](https://github.com/vllm-project/vllm) backend serving **Qwen3.5-9B AWQ 4-bit** on NVIDIA GPUs — no docker-compose required.

## Overview

DemoClaw launches two containers on a shared network:

| Container | Purpose | Host Port |
|-----------|---------|-----------|
| **vLLM** | Serves Qwen3.5-9B AWQ 4-bit via an OpenAI-compatible API | `localhost:8000` |
| **OpenClaw** | AI assistant web dashboard connected to vLLM | `localhost:18789` |

Both **Docker** and **Podman** are supported — the scripts auto-detect whichever runtime is available.

## Prerequisites

| Requirement | Minimum Version | Details |
|-------------|-----------------|---------|
| **OS** | — | Linux x86_64 (Ubuntu 22.04+, Debian 12+, Fedora 38+, RHEL 9+) |
| **NVIDIA GPU** | — | ≥ 8 GB VRAM required (e.g., RTX 3070, RTX 4060 Ti, A10, L40S) |
| **NVIDIA Driver** | ≥ 520 | Must support CUDA 11.8+; verify with `nvidia-smi` |
| **CUDA** | ≥ 11.8 | Reported by `nvidia-smi`; CUDA 12.x recommended |
| **Docker** | ≥ 20.10 | Required for `--gpus` flag support; [install guide](https://docs.docker.com/engine/install/) |
| **Podman** | ≥ 4.1 | Required for CDI GPU device support; [install guide](https://podman.io/docs/installation) |
| **NVIDIA Container Toolkit** | ≥ 1.14 | Bridges NVIDIA drivers into containers; [install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) |
| **curl** | ≥ 7.68 | For healthchecks (pre-installed on most distros) |
| **bash** | ≥ 4.0 | For all orchestration scripts |

> **Note:** Only one container runtime (Docker **or** Podman) is required — not both. The scripts auto-detect whichever is available.

### Verify prerequisites

```bash
# GPU driver
nvidia-smi

# CUDA version (must be ≥ 11.8)
nvidia-smi | grep "CUDA Version"

# Container runtime (one of these must work)
docker --version   # or
podman --version

# NVIDIA container toolkit
nvidia-ctk --version
```

### Installing the NVIDIA Container Toolkit

<details>
<summary>Docker</summary>

```bash
# Add the NVIDIA repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# Configure Docker to use the NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

</details>

<details>
<summary>Podman</summary>

```bash
# Install toolkit (same packages as Docker)
sudo apt-get install -y nvidia-container-toolkit

# Generate CDI spec for Podman
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Verify
nvidia-ctk cdi list
```

</details>

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/your-org/democlaw.git
cd democlaw

# 2. (Optional) Copy and edit the environment file
cp .env.example .env
# Edit .env to customize ports, model, VRAM settings, etc.

# 3. Launch both containers
./scripts/start.sh
```

The script will:
1. Auto-detect Docker or Podman
2. Validate your NVIDIA GPU and CUDA drivers
3. Build the container images (first run only)
4. Start the vLLM server and wait for model loading
5. Start OpenClaw and connect it to vLLM
6. Run healthchecks on both services

Once ready, open **http://localhost:18789** in your browser to access the OpenClaw dashboard.

## Installation Guide

This guide walks you through every step required to get DemoClaw running on a fresh Linux machine — from cloning the repository to verifying both services are healthy.

### Step 1 — Clone the repository

```bash
git clone https://github.com/your-org/democlaw.git
cd democlaw
```

### Step 2 — Configure environment variables

Copy the bundled template to create your local `.env` file:

```bash
cp .env.example .env
```

Open `.env` in your editor and review the settings. The defaults work out-of-the-box for most machines, but the table below highlights the variables you are most likely to want to change:

| Variable | Default | When to change |
|----------|---------|----------------|
| `CONTAINER_RUNTIME` | *(auto-detect)* | Set to `docker` or `podman` to force a specific runtime |
| `MODEL_NAME` | `Qwen/Qwen3.5-9B-AWQ` | Change only if you want a different AWQ 4-bit model |
| `VLLM_HOST_PORT` | `8000` | Change if port 8000 is already in use on your machine |
| `OPENCLAW_HOST_PORT` | `18789` | Change if port 18789 is already in use on your machine |
| `MAX_MODEL_LEN` | `8192` | Reduce (e.g. `4096`) to lower VRAM usage |
| `GPU_MEMORY_UTILIZATION` | `0.90` | Reduce (e.g. `0.80`) if vLLM reports out-of-memory |
| `HF_CACHE_DIR` | `~/.cache/huggingface` | Point to a disk with ≥ 10 GB free space for model weights |
| `HF_TOKEN` | *(empty)* | Required only for gated HuggingFace models |

**Example `.env` for a machine with port conflicts:**

```bash
VLLM_HOST_PORT=8001
OPENCLAW_HOST_PORT=18790
```

**Example `.env` to pin the runtime and reduce VRAM usage:**

```bash
CONTAINER_RUNTIME=podman
MAX_MODEL_LEN=4096
GPU_MEMORY_UTILIZATION=0.85
```

> All scripts automatically load `.env` from the project root at startup, so no `export` or `source` is needed.

### Step 3 — Verify your environment

Before launching containers, confirm the prerequisites are in place:

```bash
make env-check
```

Expected output when everything is ready:

```
Environment Check
=================

  Container runtime: docker ✓        (or podman ✓)
  nvidia-smi:        found ✓
  NVIDIA GPU:        NVIDIA GeForce RTX 4070
  NVIDIA runtime:    available ✓
  Network:           democlaw-net not created yet
```

If `nvidia-smi` is not found or the NVIDIA runtime is missing, see the [Prerequisites](#prerequisites) section for installation instructions.

### Step 4 — Launch with Docker

If Docker is your container runtime, run:

```bash
# Option A — using the Makefile (recommended)
make start

# Option B — using the script directly
./scripts/start.sh

# Option C — force Docker explicitly (overrides auto-detection)
CONTAINER_RUNTIME=docker ./scripts/start.sh
```

What happens:
1. The script detects Docker and validates your NVIDIA GPU/CUDA drivers.
2. Both container images (`democlaw/vllm:latest` and `democlaw/openclaw:latest`) are built from the local Dockerfiles (first run only; subsequent runs reuse cached images).
3. The vLLM server starts and downloads the Qwen3.5-9B AWQ 4-bit model weights from HuggingFace (~5 GB on first run; cached afterwards).
4. Once the vLLM `/health` endpoint responds, the OpenClaw container starts and connects to it.
5. A final healthcheck confirms the OpenClaw dashboard is reachable.

Expected final output:

```
[start] ========================================================
[start]   Both services started successfully!
[start]   vLLM API     : http://localhost:8000/v1
[start]   OpenClaw UI  : http://localhost:18789
[start]   Runtime      : docker
[start] ========================================================
```

Open **http://localhost:18789** in your browser to access the OpenClaw dashboard.

### Step 5 — Launch with Podman

If Podman is your container runtime, the workflow is identical. Podman uses CDI (Container Device Interface) for GPU passthrough instead of Docker's `--gpus` flag.

**Pre-requisite for Podman:** Generate the CDI spec so Podman can see the GPU:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list   # confirm "nvidia.com/gpu=0" appears
```

Then launch:

```bash
# Option A — using the Makefile
make start CONTAINER_RUNTIME=podman

# Option B — using the script directly
CONTAINER_RUNTIME=podman ./scripts/start.sh

# Option C — set in .env (persistent)
# Add CONTAINER_RUNTIME=podman to your .env, then:
./scripts/start.sh
```

> **Auto-detection:** If Podman is the only runtime installed (Docker is not in `PATH`), the scripts detect and use Podman automatically with no extra configuration.

Expected final output is the same as for Docker, with `Runtime: podman`.

### Step 6 — Verify the installation

After the stack is running, confirm both services are healthy:

```bash
# Healthcheck all services
make status
# or
./scripts/healthcheck.sh

# Validate the vLLM OpenAI-compatible API endpoints
make validate-api
# or
./scripts/validate-api.sh

# Quick curl to confirm vLLM is responding
curl http://localhost:8000/health                  # expects HTTP 200
curl http://localhost:8000/v1/models | python3 -m json.tool

# Open the OpenClaw dashboard in your browser
xdg-open http://localhost:18789   # Linux desktop
```

### Step 7 — Stop the stack

```bash
make stop
# or
./scripts/stop.sh
```

To also remove the built images and network (clean slate for next run):

```bash
make clean
```

---

## Usage

### Using the Makefile

```bash
make start          # Launch both containers
make stop           # Stop and remove containers
make restart        # Stop then start
make status         # Show container status
make health         # Run healthchecks on both services
make logs-vllm      # Follow vLLM container logs
make logs-openclaw  # Follow OpenClaw container logs
make build          # Build container images without starting
make clean          # Stop containers and remove images
make help           # Show all available targets
```

### Using scripts directly

```bash
# Start everything
./scripts/start.sh

# Start individual services
./scripts/start-vllm.sh
./scripts/start-openclaw.sh

# Stop everything
./scripts/stop.sh

# Run healthchecks
./scripts/healthcheck.sh              # Check all services
./scripts/healthcheck.sh --vllm-only  # Check vLLM only
./scripts/healthcheck.sh --json       # JSON output

# Validate vLLM OpenAI-compatible API endpoints
./scripts/validate-api.sh                          # Full validation (including inference)
SKIP_INFERENCE_TEST=true ./scripts/validate-api.sh # Skip inference test
```

### Forcing a specific container runtime

```bash
# Use Podman explicitly
CONTAINER_RUNTIME=podman ./scripts/start.sh

# Use Docker explicitly
CONTAINER_RUNTIME=docker ./scripts/start.sh
```

## Verification & Usage

Once `./scripts/start.sh` exits with the **"Both services started successfully!"** banner, use the steps below to confirm the stack is healthy and to access the OpenClaw dashboard from your browser.

### Confirm both containers are running

The quickest way to verify the full stack is the bundled healthcheck script:

```bash
./scripts/healthcheck.sh
# or via the Makefile
make health
```

It checks that:

- The container runtime (`docker` or `podman`) is available
- The container network `democlaw-net` exists
- Both `democlaw-vllm` and `democlaw-openclaw` containers are in the **running** state
- The vLLM `/health`, `/v1/models`, and `/v1/chat/completions` endpoints respond correctly
- The OpenClaw dashboard responds with HTTP 2xx and serves HTML content

Expected output when everything is healthy:

```
======================================
  DemoClaw Health Check
======================================

▶ Checking container runtime ...
  ✓ Container runtime — docker available (Docker version 26.1.0, ...)
▶ Checking container network ...
  ✓ Container network — 'democlaw-net' exists
▶ Checking vLLM service ...
  ✓ vLLM container — 'democlaw-vllm' is running
  ✓ vLLM container health — Docker HEALTHCHECK reports healthy
▶ Checking vLLM health endpoint ...
  ✓ vLLM /health endpoint — HTTP 200
▶ Checking vLLM /v1/models endpoint ...
  ✓ vLLM /v1/models endpoint — HTTP 200 — 1 model(s) available
  ✓ vLLM model loaded — 'Qwen/Qwen3.5-9B-AWQ' found in /v1/models
▶ Checking vLLM /v1/chat/completions (inference test) ...
  ✓ vLLM chat completions — Inference working — HTTP 200 with valid response
▶ Checking OpenClaw service ...
  ✓ OpenClaw container — 'democlaw-openclaw' is running
  ✓ OpenClaw dashboard reachable — HTTP 200 at http://localhost:18789
  ✓ OpenClaw dashboard content — HTML content verified (nnn bytes)

--------------------------------------
  Results: 10 passed, 0 failed, 0 warnings (10 total)
--------------------------------------
  Overall: HEALTHY
```

You can also inspect container state directly:

```bash
# Docker
docker ps --filter "name=democlaw"

# Podman
podman ps --filter "name=democlaw"
```

Expected output — both containers should show **Up** status:

```
CONTAINER ID   IMAGE                      COMMAND   STATUS         NAMES
a1b2c3d4e5f6   democlaw/vllm:latest       ...       Up 5 minutes   democlaw-vllm
b2c3d4e5f6a1   democlaw/openclaw:latest   ...       Up 4 minutes   democlaw-openclaw
```

### Access the OpenClaw web dashboard

Open your browser and navigate to:

```
http://localhost:18789
```

> **Custom port:** If you changed `OPENCLAW_HOST_PORT` in `.env`, replace `18789` with your configured port.

**On a headless Linux server** (no desktop environment), use SSH port-forwarding to access the dashboard from your local machine:

```bash
# Run this command on your LOCAL machine
ssh -L 18789:localhost:18789 user@your-server-address
```

Then open **http://localhost:18789** in your local browser while the SSH tunnel is active.

### Check service logs

Logs are the first place to look when a service does not start as expected:

```bash
# Follow vLLM logs — useful while the model is downloading/loading (~5 GB on first run)
docker logs -f democlaw-vllm          # Docker
podman logs -f democlaw-vllm          # Podman
make logs-vllm                        # via Makefile

# Follow OpenClaw logs
docker logs -f democlaw-openclaw      # Docker
podman logs -f democlaw-openclaw      # Podman
make logs-openclaw                    # via Makefile
```

### Quick API smoke test

Verify the vLLM API is responding without running the full healthcheck suite:

```bash
# Liveness probe — expects HTTP 200
curl -sf http://localhost:8000/health && echo "vLLM is up"

# List loaded models
curl http://localhost:8000/v1/models | python3 -m json.tool

# Validate all OpenAI-compatible API endpoints end-to-end
./scripts/validate-api.sh
```

### Basic troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `nvidia-smi not found` | NVIDIA driver not installed | `sudo apt install nvidia-driver-560` (Ubuntu) or see [Prerequisites](#prerequisites) |
| `Insufficient GPU VRAM` | GPU has < 8 GB VRAM | Use a GPU with ≥ 8 GB VRAM, or reduce `MAX_MODEL_LEN` in `.env` |
| vLLM container stuck on first run | Model downloading from HuggingFace (~5 GB) | Wait and monitor with `make logs-vllm`; progress shows in the log |
| `OpenClaw says "waiting for vLLM"` | vLLM model still loading | Normal on first launch; wait for model to finish loading |
| `HTTP 000` from healthcheck | Port blocked or container not started | Check `docker ps`, verify firewall allows the port, re-run `./scripts/start.sh` |
| Port 8000 or 18789 already in use | Another service occupies the port | Set `VLLM_HOST_PORT=8001` and/or `OPENCLAW_HOST_PORT=18790` in `.env` |
| Podman: `no GPU device found` | CDI spec not generated | Run `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` then retry |
| Dashboard loads but shows no model | vLLM URL misconfigured in OpenClaw | Check `VLLM_BASE_URL` in `.env`; default is `http://vllm:8000/v1` |

For more detailed troubleshooting steps, see the [Troubleshooting](#troubleshooting) section below.

---

## vLLM OpenAI-Compatible API

The vLLM server exposes a fully OpenAI-compatible REST API on **port 8000** (host default).  Any client that works with the OpenAI API — including the official Python/JS SDKs, `curl`, LangChain, LlamaIndex, and OpenClaw — can use it without modification by pointing at `http://localhost:8000/v1`.

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/health` | Liveness probe — returns `200 OK` when the server is accepting requests |
| `GET`  | `/v1/models` | List loaded models (OpenAI `GET /v1/models` format) |
| `POST` | `/v1/chat/completions` | Chat inference (OpenAI `POST /v1/chat/completions` format) |
| `POST` | `/v1/completions` | Text completion (OpenAI `POST /v1/completions` format) |
| `POST` | `/v1/embeddings` | Embeddings (when supported by the model) |

### Default port

| Setting | Default | Override |
|---------|---------|----------|
| Container-internal port | `8000` | `VLLM_PORT` |
| Host-published port | `8000` | `VLLM_HOST_PORT` |
| Base URL (from host) | `http://localhost:8000/v1` | `VLLM_BASE_URL` |
| Base URL (container→container) | `http://vllm:8000/v1` | `VLLM_BASE_URL` |

### Usage examples

#### Check server liveness

```bash
curl http://localhost:8000/health
# Expected: HTTP 200 (empty body)
```

#### List loaded models

```bash
curl http://localhost:8000/v1/models | python3 -m json.tool
```

Expected response shape:

```json
{
  "object": "list",
  "data": [
    {
      "id": "Qwen/Qwen3.5-9B-AWQ",
      "object": "model",
      "created": 1700000000,
      "owned_by": "vllm"
    }
  ]
}
```

#### Chat completion (curl)

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3.5-9B-AWQ",
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
  "model": "Qwen/Qwen3.5-9B-AWQ",
  "choices": [
    {
      "index": 0,
      "message": {"role": "assistant", "content": "The capital of France is Paris."},
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

#### Chat completion (Python — OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="EMPTY",          # vLLM accepts any non-empty value
)

response = client.chat.completions.create(
    model="Qwen/Qwen3.5-9B-AWQ",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user",   "content": "Explain vLLM in one sentence."},
    ],
    max_tokens=128,
    temperature=0.7,
)
print(response.choices[0].message.content)
```

#### Streaming chat completion (Python)

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="EMPTY")

with client.chat.completions.create(
    model="Qwen/Qwen3.5-9B-AWQ",
    messages=[{"role": "user", "content": "Count to 5."}],
    max_tokens=64,
    stream=True,
) as stream:
    for chunk in stream:
        delta = chunk.choices[0].delta.content or ""
        print(delta, end="", flush=True)
print()
```

### Validate the API

Use the included validation script to confirm all OpenAI-compatible endpoints are working correctly:

```bash
./scripts/validate-api.sh
```

This tests all three key endpoints (`/health`, `/v1/models`, `/v1/chat/completions`) and verifies the response structure matches the OpenAI API contract.  To skip the inference step (e.g. in CI without a GPU):

```bash
SKIP_INFERENCE_TEST=true ./scripts/validate-api.sh
```

You can also use the full health check which includes the same endpoint verification alongside container-status checks:

```bash
./scripts/healthcheck.sh --vllm-only
```

## Configuration

All settings are configurable via environment variables or a `.env` file. Copy `.env.example` to get started:

```bash
cp .env.example .env
```

### Key settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_RUNTIME` | *(auto-detect)* | Force `docker` or `podman` |
| `MODEL_NAME` | `Qwen/Qwen3.5-9B-AWQ` | HuggingFace model ID |
| `VLLM_HOST_PORT` | `8000` | vLLM API port on host |
| `OPENCLAW_HOST_PORT` | `18789` | OpenClaw dashboard port on host |
| `MAX_MODEL_LEN` | `8192` | Maximum sequence length |
| `GPU_MEMORY_UTILIZATION` | `0.90` | Fraction of GPU VRAM to use |
| `HF_CACHE_DIR` | `~/.cache/huggingface` | HuggingFace model cache directory |
| `HF_TOKEN` | *(empty)* | HuggingFace token for gated models |

See [`.env.example`](.env.example) for the full list of configurable parameters.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Linux Host                                          │
│                                                      │
│  ┌────────────────┐       ┌────────────────────────┐ │
│  │  vLLM Server   │       │  OpenClaw              │ │
│  │                │       │                        │ │
│  │  Qwen3.5-9B    │◄──────│  Web Dashboard         │ │
│  │  AWQ 4-bit     │ HTTP  │  (Node.js)             │ │
│  │                │       │                        │ │
│  │  :8000/v1      │       │  :18789                │ │
│  └───────┬────────┘       └───────┬────────────────┘ │
│          │  democlaw-net          │                   │
│          │  (container network)   │                   │
│  ────────┴────────────────────────┴──────────────     │
│                                                      │
│  Host ports: :8000 (vLLM API)  :18789 (Dashboard)    │
└──────────────────────────────────────────────────────┘
```

### Container details

**vLLM container** (`democlaw-vllm`):
- Base image: `vllm/vllm-openai:v0.8.3`
- Serves the Qwen3.5-9B AWQ 4-bit model
- OpenAI-compatible API at `/v1/chat/completions`, `/v1/models`, etc.
- GPU passthrough via `--gpus all` (Docker) or CDI (Podman)
- Built-in healthcheck on `/health` and `/v1/models`

**OpenClaw container** (`democlaw-openclaw`):
- Base image: Ubuntu 24.04 with Node.js 20
- Runs as non-root user
- Read-only filesystem (tmpfs for writable dirs)
- Connects to vLLM via the `democlaw-net` container network
- Waits for vLLM readiness before starting

### Security

Both containers follow a minimal-privilege model:
- `--cap-drop ALL` — no Linux capabilities
- `--security-opt no-new-privileges` — prevents privilege escalation
- OpenClaw runs as non-root with `--read-only` filesystem
- No unnecessary host mounts (only HuggingFace cache for vLLM)

## Idempotent Execution

The scripts are safe to run multiple times:
- Existing stopped containers are automatically removed and recreated
- Running containers are detected and left untouched (with a message)
- The container network is created only if it doesn't exist
- Images are built only if not already present

To force a full rebuild:

```bash
make clean    # Remove containers and images
make start    # Rebuild and start fresh
```

## Troubleshooting

### GPU not detected

```
ERROR: nvidia-smi not found in PATH.
```

Install the NVIDIA driver for your GPU:
```bash
sudo apt install nvidia-driver-560   # Ubuntu/Debian
sudo dnf install nvidia-driver       # Fedora/RHEL
```

### Insufficient VRAM

```
ERROR: Insufficient GPU VRAM: 6144 MiB detected, but 7500 MiB required.
```

The Qwen3.5-9B AWQ 4-bit model requires approximately 8 GB of VRAM. Options:
- Use a GPU with ≥ 8 GB VRAM
- Reduce `MAX_MODEL_LEN` in `.env` to lower memory usage
- Use a smaller model by changing `MODEL_NAME`

### vLLM takes a long time to start

On the first run, vLLM downloads the model from HuggingFace (~5 GB). Subsequent runs use the cached model from `HF_CACHE_DIR`. You can monitor progress with:

```bash
make logs-vllm
# or
docker logs -f democlaw-vllm
```

### OpenClaw says "waiting for vLLM"

OpenClaw waits for the vLLM server to become healthy before starting. This is normal during the first launch while the model loads. Check vLLM status:

```bash
./scripts/healthcheck.sh --vllm-only
```

### Port conflicts

If ports 8000 or 18789 are already in use, change them in `.env`:

```bash
VLLM_HOST_PORT=8001
OPENCLAW_HOST_PORT=18790
```

### Container runtime issues

Force a specific runtime:
```bash
CONTAINER_RUNTIME=podman ./scripts/start.sh
```

Check runtime GPU support:
```bash
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi   # Docker
podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.0-base nvidia-smi  # Podman
```

## Project Structure

```
democlaw/
├── scripts/
│   ├── start.sh              # Main orchestration script
│   ├── start-vllm.sh         # Launch vLLM container
│   ├── start-openclaw.sh     # Launch OpenClaw container
│   ├── stop.sh               # Stop and remove containers
│   ├── healthcheck.sh        # Verify both services are healthy
│   ├── validate-api.sh       # Validate vLLM OpenAI-compatible API endpoints
│   └── lib/
│       ├── runtime.sh        # Docker/Podman auto-detection library
│       └── gpu.sh            # NVIDIA GPU/CUDA validation library
├── vllm/
│   ├── Dockerfile            # vLLM server image
│   └── healthcheck.sh        # In-container healthcheck
├── openclaw/
│   ├── Dockerfile            # OpenClaw image (Ubuntu 24.04 + Node.js)
│   ├── entrypoint.sh         # Runtime config + vLLM wait logic
│   ├── healthcheck.sh        # In-container healthcheck
│   ├── config.json           # LLM provider config template
│   └── .dockerignore
├── .env.example              # Configurable parameters template
├── Makefile                  # Common operations shortcuts
├── LICENSE                   # Project license
└── README.md                 # This file
```

## License

This project is licensed under the terms of the [MIT License](LICENSE).
