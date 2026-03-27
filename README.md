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

| Requirement | Details |
|-------------|---------|
| **OS** | Linux (x86_64) |
| **NVIDIA GPU** | ≥ 8 GB VRAM (e.g., RTX 3070, RTX 4060 Ti, A10, etc.) |
| **NVIDIA Driver** | Installed and functional (`nvidia-smi` must work) |
| **CUDA** | ≥ 11.8 (reported by `nvidia-smi`) |
| **Container Runtime** | [Docker](https://docs.docker.com/engine/install/) **or** [Podman](https://podman.io/docs/installation) |
| **NVIDIA Container Toolkit** | [Installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) |
| **curl** | For healthchecks (pre-installed on most distros) |
| **bash** | ≥ 4.0 |

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
```

### Forcing a specific container runtime

```bash
# Use Podman explicitly
CONTAINER_RUNTIME=podman ./scripts/start.sh

# Use Docker explicitly
CONTAINER_RUNTIME=docker ./scripts/start.sh
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
