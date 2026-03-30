# DemoClaw

NVIDIA GPU에서 [llama.cpp](https://github.com/ggerganov/llama.cpp) + [OpenClaw](https://github.com/openclaw) AI 비서를 실행하는 컨테이너 오케스트레이션.

Container orchestration for running [OpenClaw](https://github.com/openclaw) AI assistant with a self-hosted [llama.cpp](https://github.com/ggerganov/llama.cpp) backend on NVIDIA GPUs.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    democlaw-net                          │
│                                                         │
│  ┌───────────┐   ┌────────────┐   ┌──────────────────┐ │
│  │ llama.cpp │   │ MarkItDown │   │    OpenClaw       │ │
│  │ :8000     │   │ MCP :3001  │   │    :18789         │ │
│  │ (LLM/GPU) │   │ (doc conv) │   │ (AI dashboard)   │ │
│  └─────▲─────┘   └─────▲──────┘   └───┬──────────┬───┘ │
│        │                │              │          │      │
│        └────────────────┴──────────────┘          │      │
│                   OpenClaw calls both             │      │
└─────────────────────────────────────────────────────────┘
```

| Container | Purpose | Host Port |
|-----------|---------|-----------|
| **llama.cpp** | Qwen3.5-9B Q4_K_M GGUF via OpenAI-compatible API (CUDA) | `localhost:8000` |
| **MarkItDown** | MCP server — PDF/DOCX/HTML to Markdown conversion | `localhost:3001` |
| **OpenClaw** | AI assistant web dashboard | `localhost:18789` |

## Minimum Requirements

### Hardware

| | Minimum | Recommended |
|---|---------|-------------|
| **GPU** | NVIDIA 8 GB VRAM (RTX 3070, RTX 4060 Ti) | 12 GB+ VRAM |
| **NVIDIA Driver** | 520+ (CUDA 11.8) | 560+ (CUDA 12.x) |
| **RAM** | 16 GB | 32 GB+ |
| **Disk** | 15 GB free | 30 GB+ free |

### Software

| | Linux | Windows 11 |
|---|-------|------------|
| **OS** | Ubuntu 22.04+, Debian 12+, Fedora 38+, RHEL 9+ | Windows 11 (22H2+) |
| **Container Runtime** | Docker 20.10+ **or** Podman 4.1+ | [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/) (WSL2 backend) |
| **GPU Support** | [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) | Docker Desktop GPU support (built-in) |
| **Shell** | bash 4.0+ (pre-installed) | Git Bash (included with [Git for Windows](https://git-scm.com/download/win)) |
| **curl** | pre-installed | pre-installed (Windows 11) |

> CUDA Toolkit은 호스트에 설치할 필요 없습니다. llama.cpp 컨테이너 이미지에 포함되어 있습니다.
>
> You do NOT need the CUDA Toolkit on the host. It is bundled inside the llama.cpp container image.

## Quick Start

### Linux

```bash
git clone https://github.com/democlaw/democlaw.git
cd democlaw

# (Optional) Copy and edit environment config
cp .env.example .env

# (Optional) Pre-download the model to see progress (~5.7 GB, first run only)
./scripts/download-model.sh

# Start the full stack (downloads model automatically if not pre-cached)
./scripts/start.sh

# Open the dashboard URL printed at the end
# Click "Connect" on first visit (auto-approved within ~2 seconds)
```

### Windows 11

```powershell
git clone https://github.com/democlaw/democlaw.git
cd democlaw

# Start the full stack
scripts\start.bat

# Open the dashboard URL printed at the end
```

### Verify

```bash
# GPU check
nvidia-smi

# LLM API
curl http://localhost:8000/v1/models

# MarkItDown MCP
curl http://localhost:3001/health

# OpenClaw dashboard
open http://localhost:18789   # or the tokenized URL from start output
```

### Stop

```bash
# Linux
./scripts/stop.sh

# Windows
scripts\stop.bat
```

## Adding MCP Servers

DemoClaw supports adding MCP tool servers as sidecar containers. OpenClaw discovers them via `config/mcporter.json`.

### Step 1: Find or build an MCP server container

Any MCP server that supports **SSE transport** over HTTP works. Example: a Docker Hub image like `myorg/my-mcp-server:latest`.

### Step 2: Register in `config/mcporter.json`

```json
{
  "servers": {
    "markitdown": {
      "transport": "sse",
      "url": "http://markitdown:3001/sse",
      "description": "MarkItDown document converter"
    },
    "my-new-tool": {
      "transport": "sse",
      "url": "http://my-new-tool:4000/sse",
      "description": "Description of your MCP server"
    }
  }
}
```

The `url` uses the **container network alias** (not `localhost`), since containers communicate over the shared `democlaw-net` network.

### Step 3: Add to `scripts/start.sh`

Add the container startup before the OpenClaw phase. Follow the MarkItDown pattern:

```bash
# In start.sh, before "Phase 4: Start OpenClaw":

"${RUNTIME}" run -d \
    --name "democlaw-my-new-tool" \
    --network "${NETWORK}" \
    --network-alias my-new-tool \
    --restart unless-stopped \
    -p 4000:4000 \
    -e "PORT=4000" \
    "myorg/my-mcp-server:latest"
```

For Windows, add the equivalent block in `scripts/start.bat`.

### Step 4: Add to `scripts/stop.sh`

Add the container name to the cleanup loop:

```bash
for cname in democlaw-openclaw democlaw-markitdown democlaw-my-new-tool democlaw-llamacpp; do
```

Update `scripts/stop.bat` similarly.

### Step 5: Start and verify

```bash
./scripts/start.sh
# Check your MCP server health
curl http://localhost:4000/health
```

OpenClaw will discover the new tool via mcporter and make it available to the AI agent.

## Configuration

All settings are configurable via environment variables. Copy `.env.example` to `.env` and edit:

```bash
cp .env.example .env
```

Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_RUNTIME` | auto-detect | Force `docker` or `podman` |
| `MODEL_REPO` | `unsloth/Qwen3.5-9B-GGUF` | HuggingFace model repo |
| `MODEL_FILE` | `Qwen3.5-9B-Q4_K_M.gguf` | GGUF model filename |
| `CTX_SIZE` | `32768` | Context length (tokens) |
| `LLAMACPP_PORT` | `8000` | llama.cpp API port |
| `OPENCLAW_PORT` | `18789` | OpenClaw dashboard port |
| `MARKITDOWN_PORT` | `3001` | MarkItDown MCP server port |
| `MODEL_DIR` | `~/.cache/democlaw/models` | Host model cache directory |

See `.env.example` for the full list.

## Make Targets

```
make start       Start full stack
make stop        Stop all containers
make restart     Restart full stack
make build       Build all container images
make status      Show container states
make logs        Tail logs (SERVICE=llamacpp|openclaw|markitdown)
make shell       Exec into container (SERVICE=llamacpp|openclaw|markitdown)
make clean       Remove containers, images, and volumes
make env-check   Validate GPU and runtime setup
make help        Show all targets
```

## Project Structure

```
democlaw/
├── llamacpp/           # llama.cpp container (Dockerfile, entrypoint, healthcheck)
├── openclaw/           # OpenClaw container (Dockerfile, entrypoint, healthcheck)
├── markitdown/         # MarkItDown MCP server (Dockerfile, server.py, entrypoint)
├── config/
│   └── mcporter.json   # MCP server registry (volume-mounted into OpenClaw)
├── scripts/
│   ├── start.sh        # Full stack startup (Linux)
│   ├── start.bat       # Full stack startup (Windows)
│   ├── stop.sh         # Stack teardown (Linux)
│   ├── stop.bat        # Stack teardown (Windows)
│   ├── download-model.sh   # Pre-download model weights
│   └── reference/
│       └── image.sh    # Image pull-or-build library (sourced by start.sh)
├── examples/skills/    # Custom OpenClaw skill templates
├── docs/               # API and config reference
├── .env.example        # Environment configuration template
└── Makefile            # Container lifecycle targets
```

## License

MIT
