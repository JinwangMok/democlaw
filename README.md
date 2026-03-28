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

### Step 4 — Build the container images

Before launching, build both container images from the local Dockerfiles. This step is done automatically by `./scripts/start.sh` on the first run, but you can also build them explicitly:

```bash
# Build both images using the Makefile (recommended)
make build

# Or build each image individually
make build-vllm      # builds democlaw/vllm:latest
make build-openclaw  # builds democlaw/openclaw:latest

# Or use the container runtime directly
docker build -t democlaw/vllm:latest     vllm/
docker build -t democlaw/openclaw:latest openclaw/
# (substitute "docker" with "podman" if using Podman)
```

> **Tip:** If you just run `./scripts/start.sh` or `make start` without building first, images are built automatically on the first run and reused on subsequent runs. Explicit `make build` is useful when you want to pre-pull and build before running (e.g. in CI, on slow networks, or to verify the Dockerfiles before deployment).

### Step 5 — Launch with Docker

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

### Step 6 — Launch with Podman

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

### Step 7 — Verify the installation

Once `./scripts/start.sh` (or `make start`) exits with the **"Both services started successfully!"** banner, run the bundled healthcheck script to confirm both containers are fully operational:

```bash
# Run the full healthcheck (all services)
./scripts/healthcheck.sh

# Or via the Makefile
make health
```

**Expected output — everything healthy:**

```
======================================
  DemoClaw Health Check
======================================

▶ Checking container runtime ...
  ✓ Container runtime — docker available (Docker version 26.1.0, build a5ee5b1)
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
  ✓ OpenClaw dashboard content — HTML content verified (42381 bytes)

--------------------------------------
  Results: 10 passed, 0 failed, 0 warnings (10 total)
--------------------------------------
  Overall: HEALTHY
```

Exit code: `0`

> **First-launch timing:** On the first run, vLLM downloads ~5 GB of model weights. Running the healthcheck immediately after `start.sh` completes may show `Overall: DEGRADED` — the `⚠ vLLM container health — HEALTHCHECK still starting` warning is normal while the runtime's built-in health probe completes. All API endpoint checks (`/health`, `/v1/models`, `/v1/chat/completions`) should already pass. Wait 2–3 minutes and re-run to see `Overall: HEALTHY`.

**Check vLLM only during model loading** (faster; skips the OpenClaw checks):

```bash
./scripts/healthcheck.sh --vllm-only
```

**Machine-readable JSON output** (useful for CI or monitoring):

```bash
./scripts/healthcheck.sh --json
```

For the full expected output for each healthcheck state (HEALTHY, DEGRADED, UNHEALTHY), JSON output format, exit codes, and all supported flags, see the [Healthchecks](#healthchecks) section.

Additional verification commands:

```bash
# Validate the vLLM OpenAI-compatible API endpoints
./scripts/validate-api.sh
# or via Makefile
make validate-api

# Quick curl to confirm vLLM is responding
curl http://localhost:8000/health                  # expects HTTP 200
curl http://localhost:8000/v1/models | python3 -m json.tool

# Open the OpenClaw dashboard in your browser
xdg-open http://localhost:18789   # Linux desktop
# or navigate to http://localhost:18789 in any browser
```

### Step 8 — Stop the stack

```bash
make stop
# or
./scripts/stop.sh
```

To also remove the built images and the shared network (clean slate for the next run):

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

### Script execution order

**Recommended order for a first-time deployment:**

```
Step 1  Verify GPU and runtime       make env-check
                                  or ./scripts/check-gpu.sh

Step 2  Build container images       make build
                                  or docker build -t democlaw/vllm:latest     vllm/
                                     docker build -t democlaw/openclaw:latest openclaw/

Step 3  Start both services          make start
         (recommended — handles     or ./scripts/start.sh
          all sub-steps below)

Step 4  Verify the stack is healthy  make status
                                  or ./scripts/healthcheck.sh

Step 5  Stop when finished           make stop
                                  or ./scripts/stop.sh
```

`start.sh` handles Steps 3a–3d internally and in the correct order:

```
start.sh
  ├── [1] Auto-detect container runtime (lib/runtime.sh)
  ├── [2] Validate NVIDIA GPU / CUDA drivers (lib/gpu.sh)
  │         → exits with error if GPU absent — no CPU fallback
  ├── [3] Phase 1: start-vllm.sh
  │         → pulls / starts vLLM container
  │         → waits for /health endpoint (up to VLLM_HEALTH_TIMEOUT seconds)
  ├── [4] Phase 2: start-openclaw.sh
  │         → starts OpenClaw container
  │         → waits for dashboard HTTP 200 (up to OPENCLAW_HEALTH_TIMEOUT seconds)
  └── [5] Phase 3: healthcheck.sh
            → runs full end-to-end health check on both services
```

**Manual step-by-step** (useful for debugging individual services):

```bash
# 1. GPU check — exits non-zero if GPU/CUDA absent
./scripts/check-gpu.sh

# 2. Start vLLM (includes GPU validation and health wait)
./scripts/start-vllm.sh

# 3. Start OpenClaw only after vLLM is healthy
./scripts/start-openclaw.sh

# 4. Verify both are running
./scripts/healthcheck.sh

# 5. Stop when finished
./scripts/stop.sh
```

> **Important:** Always start `start-vllm.sh` before `start-openclaw.sh`.
> OpenClaw polls the vLLM `/health` endpoint at startup and will time out
> if vLLM is not reachable yet.

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

## Healthchecks

DemoClaw ships four healthcheck scripts that cover two scopes: **host-side orchestration** (run from your terminal to verify a running stack) and **in-container probes** (executed by the container runtime's built-in `HEALTHCHECK` instruction).

### Running Healthchecks Manually After Starting

After `./scripts/start.sh` (or `make start`) completes, run the following commands from the project root to verify both services are healthy:

```bash
# Full stack check — runtime, network, containers, and all API endpoints
./scripts/healthcheck.sh

# Via Makefile
make health

# Check vLLM only (useful while the model is still loading)
./scripts/healthcheck.sh --vllm-only

# JSON output for scripted/CI use
./scripts/healthcheck.sh --json

# Force a specific container runtime (if auto-detection is not desired)
CONTAINER_RUNTIME=podman ./scripts/healthcheck.sh
CONTAINER_RUNTIME=docker ./scripts/healthcheck.sh
```

The script exits `0` when all checks pass (or only warnings remain) and `1` when one or more checks fail.

> **First-launch note:** On the very first run, vLLM downloads ~5 GB of model weights from HuggingFace. The in-container `HEALTHCHECK` may remain in the `starting` state for several minutes after the API endpoints are already serving requests. Running the healthcheck immediately after `start.sh` may show `Overall: DEGRADED` with a `⚠ HEALTHCHECK still starting` warning. This is expected — wait 2–3 minutes and re-run to see `Overall: HEALTHY`.

### Overview

| Script | Scope | Purpose |
|--------|-------|---------|
| `scripts/healthcheck.sh` | Host | Full stack check — runtime, network, both containers, all API endpoints |
| `scripts/healthcheck_openclaw.sh` | Host | Poll-until-ready for the OpenClaw dashboard (used by start scripts) |
| `vllm/healthcheck.sh` | In-container | Docker/Podman `HEALTHCHECK` for the vLLM container |
| `openclaw/healthcheck.sh` | In-container | Docker/Podman `HEALTHCHECK` for the OpenClaw container |

---

### `scripts/healthcheck.sh` — Full stack health check

The primary health-check script. Inspects the container runtime, the shared network, both containers, and all vLLM API endpoints.

#### Usage

```bash
# Check all services (default)
./scripts/healthcheck.sh

# Check vLLM only (skip OpenClaw)
./scripts/healthcheck.sh --vllm-only

# Output results as machine-readable JSON
./scripts/healthcheck.sh --json

# Force a specific container runtime
CONTAINER_RUNTIME=podman ./scripts/healthcheck.sh

# Combine flags
./scripts/healthcheck.sh --vllm-only --json

# Via the Makefile (runs ./scripts/healthcheck.sh internally)
make health
make status
make health-check
```

#### What is checked

| # | Check | Description |
|---|-------|-------------|
| 1 | Container runtime | Verifies `docker` or `podman` is in `PATH` and responds |
| 2 | Container network | Confirms `democlaw-net` exists |
| 3 | vLLM container state | Container must be in `running` state |
| 4 | vLLM container health | Docker/Podman `HEALTHCHECK` status (`healthy` / `starting` / `unhealthy`) |
| 5 | `GET /health` | vLLM liveness endpoint — expects HTTP 200 |
| 6 | `GET /v1/models` | OpenAI-compatible models list — expects HTTP 200 with ≥ 1 model |
| 7 | Model loaded | Verifies `Qwen/Qwen3.5-9B-AWQ` appears in `/v1/models` response |
| 8 | `POST /v1/chat/completions` | End-to-end inference smoke test — expects HTTP 200 with valid response |
| 9 | OpenClaw container state | Container must be in `running` state |
| 10 | OpenClaw dashboard | HTTP 2xx at `http://localhost:18789` with non-empty HTML content |

> Checks 9–10 are skipped when `--vllm-only` is passed.

#### Expected output — HEALTHY

When all services are running and the model has finished loading:

```
======================================
  DemoClaw Health Check
======================================

▶ Checking container runtime ...
  ✓ Container runtime — docker available (Docker version 26.1.0, build a5ee5b1)
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
  ✓ OpenClaw dashboard content — HTML content verified (42381 bytes)

--------------------------------------
  Results: 10 passed, 0 failed, 0 warnings (10 total)
--------------------------------------
  Overall: HEALTHY
```

Exit code: **`0`**

#### Expected output — DEGRADED (warnings only)

A `DEGRADED` result occurs when no checks outright fail but one or more produce warnings — for example, the container `HEALTHCHECK` is still in its initial `starting` phase (model loading) or the model ID in `/v1/models` does not match `MODEL_NAME`:

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
  ⚠ vLLM container health — HEALTHCHECK still starting (model may be loading)
▶ Checking vLLM health endpoint ...
  ✓ vLLM /health endpoint — HTTP 200
▶ Checking vLLM /v1/models endpoint ...
  ✓ vLLM /v1/models endpoint — HTTP 200 — 1 model(s) available
  ⚠ vLLM model loaded — 'Qwen/Qwen3.5-9B-AWQ' not found; available: my-other-model
...

--------------------------------------
  Results: 8 passed, 0 failed, 2 warnings (10 total)
--------------------------------------
  Overall: DEGRADED
```

Exit code: **`0`**

#### Expected output — UNHEALTHY (one or more failures)

```
======================================
  DemoClaw Health Check
======================================

▶ Checking container runtime ...
  ✓ Container runtime — docker available (Docker version 26.1.0, ...)
▶ Checking container network ...
  ✗ Container network — 'democlaw-net' not found
▶ Checking vLLM service ...
  ✗ vLLM container — Container 'democlaw-vllm' does not exist
▶ Checking vLLM health endpoint ...
  ✗ vLLM /health endpoint — HTTP 000 (expected 200) at http://localhost:8000/health
▶ Checking OpenClaw service ...
  ✗ OpenClaw container — Container 'democlaw-openclaw' does not exist
  ✗ OpenClaw dashboard reachable — No response at http://localhost:18789 (port 18789)

--------------------------------------
  Results: 1 passed, 5 failed, 0 warnings (6 total)
--------------------------------------
  Overall: UNHEALTHY
```

Exit code: **`1`**

#### JSON output mode (`--json`)

Pass `--json` to get a single-line machine-readable JSON object instead of human-readable text.  Useful for CI pipelines, monitoring agents, or scripted checks.

```bash
./scripts/healthcheck.sh --json | python3 -m json.tool
```

Example JSON output (healthy):

```json
{
  "status": "pass",
  "checks_total": 10,
  "checks_passed": 10,
  "checks_failed": 0,
  "checks_warned": 0,
  "results": [
    {"check": "Container runtime",        "status": "pass", "detail": "docker available (Docker version 26.1.0, ...)"},
    {"check": "Container network",        "status": "pass", "detail": "'democlaw-net' exists"},
    {"check": "vLLM container",           "status": "pass", "detail": "'democlaw-vllm' is running"},
    {"check": "vLLM container health",    "status": "pass", "detail": "Docker HEALTHCHECK reports healthy"},
    {"check": "vLLM /health endpoint",    "status": "pass", "detail": "HTTP 200"},
    {"check": "vLLM /v1/models endpoint", "status": "pass", "detail": "HTTP 200 — 1 model(s) available"},
    {"check": "vLLM model loaded",        "status": "pass", "detail": "'Qwen/Qwen3.5-9B-AWQ' found in /v1/models"},
    {"check": "vLLM chat completions",    "status": "pass", "detail": "Inference working — HTTP 200 with valid response"},
    {"check": "OpenClaw container",       "status": "pass", "detail": "'democlaw-openclaw' is running"},
    {"check": "OpenClaw dashboard reachable", "status": "pass", "detail": "HTTP 200 at http://localhost:18789"},
    {"check": "OpenClaw dashboard content",  "status": "pass", "detail": "HTML content verified (42381 bytes)"}
  ]
}
```

The top-level `"status"` field is `"pass"` (all checks passed), `"warn"` (warnings only), or `"fail"` (at least one failure).

#### Exit codes

| Exit code | Meaning |
|-----------|---------|
| `0` | All checks passed **or** only warnings (HEALTHY / DEGRADED) |
| `1` | One or more checks failed (UNHEALTHY) |
| `1` | Runtime not found — script cannot proceed |

#### Environment variables

All defaults can be overridden via environment variables or a `.env` file:

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_RUNTIME` | *(auto-detect)* | Force `docker` or `podman` |
| `VLLM_HOST_PORT` | `8000` | Host port for vLLM API |
| `OPENCLAW_HOST_PORT` | `18789` | Host port for OpenClaw dashboard |
| `VLLM_CONTAINER_NAME` | `democlaw-vllm` | Name of the vLLM container |
| `OPENCLAW_CONTAINER_NAME` | `democlaw-openclaw` | Name of the OpenClaw container |
| `DEMOCLAW_NETWORK` | `democlaw-net` | Name of the shared container network |
| `MODEL_NAME` | `Qwen/Qwen3.5-9B-AWQ` | Expected model ID in `/v1/models` |
| `HEALTHCHECK_CURL_TIMEOUT` | `10` | Per-request curl timeout in seconds |

---

### `scripts/healthcheck_openclaw.sh` — Poll until OpenClaw is ready

A focused polling script that repeatedly checks the OpenClaw dashboard URL until it responds with HTTP 200 or the timeout expires. Used internally by `scripts/start-openclaw.sh` after the container starts.

#### Usage

```bash
# Poll with defaults (120 s timeout, 3 s interval)
./scripts/healthcheck_openclaw.sh

# Custom timeout and interval
OPENCLAW_HEALTH_TIMEOUT=60 OPENCLAW_HEALTH_INTERVAL=5 ./scripts/healthcheck_openclaw.sh

# Custom port
OPENCLAW_HOST_PORT=18790 ./scripts/healthcheck_openclaw.sh
```

#### Expected output — Dashboard becomes ready

```
[healthcheck-openclaw] Polling OpenClaw dashboard at http://localhost:18789
[healthcheck-openclaw]   Timeout   : 120s
[healthcheck-openclaw]   Interval  : 3s
[healthcheck-openclaw]   Per-request curl timeout: 5s
[healthcheck-openclaw]   ... HTTP 000 — not ready yet (0s elapsed, 120s remaining)
[healthcheck-openclaw]   ... HTTP 000 — not ready yet (3s elapsed, 117s remaining)
[healthcheck-openclaw]   ... HTTP 200 — not ready yet (6s elapsed, ...)

[healthcheck-openclaw] =============================================
[healthcheck-openclaw]   OpenClaw dashboard is reachable!
[healthcheck-openclaw]   URL  : http://localhost:18789
[healthcheck-openclaw]   HTTP : 200
[healthcheck-openclaw] =============================================
```

Exit code: **`0`**

#### Expected output — Timeout exceeded

```
[healthcheck-openclaw] Polling OpenClaw dashboard at http://localhost:18789
[healthcheck-openclaw]   Timeout   : 120s
[healthcheck-openclaw]   Interval  : 3s
[healthcheck-openclaw]   Per-request curl timeout: 5s
[healthcheck-openclaw]   ... HTTP 000 — not ready yet (0s elapsed, 120s remaining)
...
[healthcheck-openclaw] WARNING:
[healthcheck-openclaw] WARNING: OpenClaw dashboard did not respond with HTTP 200 within 120s.
[healthcheck-openclaw] WARNING:   URL          : http://localhost:18789
[healthcheck-openclaw] WARNING:   Last HTTP    : 000
[healthcheck-openclaw] WARNING:
[healthcheck-openclaw] WARNING: Possible causes:
[healthcheck-openclaw] WARNING:   - The OpenClaw container is not running. Start it with:
[healthcheck-openclaw] WARNING:       ./scripts/start-openclaw.sh
[healthcheck-openclaw] WARNING:   - The container is still initialising. Increase OPENCLAW_HEALTH_TIMEOUT and retry.
[healthcheck-openclaw] WARNING:   - The vLLM server is not reachable; OpenClaw may be waiting for it.
[healthcheck-openclaw] WARNING:   - Port 18789 is blocked by a firewall or in use by another process.
```

Exit code: **`1`**

#### Exit codes

| Exit code | Meaning |
|-----------|---------|
| `0` | Dashboard responded HTTP 200 within the timeout |
| `1` | Timeout exceeded without a successful response |
| `1` | `curl` is not found in `PATH` |

#### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW_HOST_PORT` | `18789` | Port the OpenClaw dashboard is published on |
| `OPENCLAW_HEALTH_TIMEOUT` | `120` | Total seconds to wait before giving up |
| `OPENCLAW_HEALTH_INTERVAL` | `3` | Seconds between polling attempts |
| `OPENCLAW_HEALTH_CURL_TIMEOUT` | `5` | Per-request curl timeout in seconds |

---

### In-container healthchecks

Each container image bundles its own lightweight healthcheck script that the Docker/Podman `HEALTHCHECK` instruction calls at regular intervals (every 30 s by default). These run **inside** the container and are not meant to be invoked manually, but understanding them helps interpret `docker ps` / `podman ps` health status.

#### `vllm/healthcheck.sh`

Executed inside `democlaw-vllm`. Verifies:

1. `GET /health` responds with HTTP 200 (liveness)
2. `GET /v1/models` returns valid JSON with at least one loaded model

```
# Healthy — exits 0 (silent on success)

# Unhealthy — message written to stderr, exits 1:
UNHEALTHY: /health endpoint not responding
UNHEALTHY: /v1/models endpoint not responding
UNHEALTHY: /v1/models returned no models
```

View the current health status reported by the runtime:

```bash
docker inspect --format '{{.State.Health.Status}}' democlaw-vllm
# → healthy  |  starting  |  unhealthy

podman inspect --format '{{.State.Health.Status}}' democlaw-vllm
```

#### `openclaw/healthcheck.sh`

Executed inside `democlaw-openclaw`. Verifies:

1. The dashboard HTTP endpoint responds with a 2xx status code
2. The response body contains non-empty HTML content

```
# Healthy — exits 0 (silent on success)

# Unhealthy — message written to stderr, exits 1:
UNHEALTHY: Dashboard not responding at http://localhost:18789/
UNHEALTHY: Dashboard returned HTTP 503
UNHEALTHY: Dashboard returned empty body
UNHEALTHY: Dashboard response does not contain expected content
```

View the current health status:

```bash
docker inspect --format '{{.State.Health.Status}}' democlaw-openclaw
# → healthy  |  starting  |  unhealthy
```

---

### Interpreting healthcheck results

| Container health status | Meaning | Action |
|-------------------------|---------|--------|
| `healthy` | All in-container checks pass | ✅ No action needed |
| `starting` | Checks are still running (normal on first launch while model loads) | ⏳ Wait and retry |
| `unhealthy` | At least one check failed | ❌ Check container logs |
| `none` | No `HEALTHCHECK` configured or not supported by the runtime | — |

Quick reference commands:

```bash
# Inspect both container health states at once
docker inspect --format '{{.Name}}: {{.State.Health.Status}}' democlaw-vllm democlaw-openclaw

# Full host-side health report (all checks + API endpoints)
./scripts/healthcheck.sh

# vLLM only (faster, useful during model loading)
./scripts/healthcheck.sh --vllm-only

# Machine-readable JSON (for CI or monitoring)
./scripts/healthcheck.sh --json

# Watch container states loop (Ctrl+C to stop)
watch -n 5 'docker ps --filter "name=democlaw" --format "table {{.Names}}\t{{.Status}}"'
```

---

## vLLM OpenAI-Compatible API

The vLLM server exposes a fully OpenAI-compatible REST API on **port 8000** (host default).  Any client that works with the OpenAI API — including the official Python/JS SDKs, `curl`, LangChain, LlamaIndex, and OpenClaw — can use it without modification by pointing at `http://localhost:8000/v1`.

> **Full API reference:** [`docs/vllm-api.md`](docs/vllm-api.md) — base URLs, all endpoints, curl/Python/JS examples, authentication, and troubleshooting.

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
│   ├── start.sh                 # Main orchestration script (vLLM + OpenClaw)
│   ├── start-vllm.sh            # Launch vLLM container (GPU validation, model pull, health wait)
│   ├── start-openclaw.sh        # Launch OpenClaw container (with health wait)
│   ├── stop.sh                  # Stop and remove all containers
│   ├── healthcheck.sh           # Verify both services are healthy
│   ├── healthcheck_vllm.sh      # Healthcheck for the vLLM service only
│   ├── healthcheck_openclaw.sh  # Healthcheck for the OpenClaw service only
│   ├── validate-api.sh          # Validate vLLM OpenAI-compatible API endpoints
│   ├── check-gpu.sh             # Standalone NVIDIA GPU/CUDA preflight validation
│   ├── run_vllm.sh              # Raw vLLM container launch (no health wait)
│   └── lib/
│       ├── runtime.sh           # Docker/Podman auto-detection library
│       └── gpu.sh               # NVIDIA GPU/CUDA validation library
├── vllm/
│   ├── Dockerfile               # vLLM server image (based on vllm/vllm-openai)
│   ├── entrypoint.sh            # Container entrypoint with model arguments
│   └── healthcheck.sh           # In-container healthcheck
├── openclaw/
│   ├── Dockerfile               # OpenClaw image (Ubuntu 24.04 + Node.js 20)
│   ├── entrypoint.sh            # Runtime config + vLLM wait logic
│   ├── healthcheck.sh           # In-container healthcheck
│   ├── config.json              # LLM provider config template
│   └── .dockerignore
├── .github/
│   └── workflows/
│       └── ci-shellcheck.yml    # CI: shellcheck linting (no GPU runner)
├── .env.example                 # Configurable parameters template
├── Makefile                     # Common operations shortcuts
├── LICENSE                      # Project license
└── README.md                    # This file
```

## License

This project is licensed under the terms of the [MIT License](LICENSE).
