# DemoClaw

NVIDIA GPU에서 [llama.cpp](https://github.com/ggerganov/llama.cpp) + [OpenClaw](https://github.com/openclaw) AI 비서를 실행하는 컨테이너 오케스트레이션.

Container orchestration for running [OpenClaw](https://github.com/openclaw) AI assistant with a self-hosted [llama.cpp](https://github.com/ggerganov/llama.cpp) backend on NVIDIA GPUs.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                  democlaw-net                     │
│                                                  │
│  ┌───────────┐            ┌──────────────────┐   │
│  │ llama.cpp │            │    OpenClaw       │   │
│  │ :8000     │◄───────────│    :18789         │   │
│  │ (LLM/GPU) │            │ (AI dashboard)   │   │
│  └───────────┘            └──────────────────┘   │
│                                  │               │
│        ┌─────────────────────────┘               │
│        │  MCP sidecar containers (optional)      │
│        ▼                                         │
│  ┌────────────┐  ┌────────────┐                  │
│  │ MarkItDown │  │  your-mcp  │  ...             │
│  │ MCP :3001  │  │    :4000   │                  │
│  └────────────┘  └────────────┘                  │
└──────────────────────────────────────────────────┘
```

| Container | Purpose | Host Port |
|-----------|---------|-----------|
| **llama.cpp** | Qwen3.5-9B Q4_K_M GGUF via OpenAI-compatible API (CUDA) | `localhost:8000` |
| **OpenClaw** | AI assistant web dashboard | `localhost:18789` |
| *MCP sidecars* | Optional tool servers (e.g., MarkItDown) | user-defined |

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

## Device Approval

첫 번째 디바이스 페어링은 컨테이너 내부에서 자동 승인됩니다. 이후 추가 디바이스는 호스트에서 승인해야 합니다.

The first device pairing is auto-approved inside the container. Additional devices must be approved from the host.

```bash
# Linux — interactive mode (list + select)
./scripts/device-approve.sh

# Linux — list pending devices only
./scripts/device-approve.sh --list

# Linux — approve a specific device by ID
./scripts/device-approve.sh <device-id>
```

```powershell
# Windows
scripts\device-approve.bat
scripts\device-approve.bat --list
scripts\device-approve.bat <device-id>
```

## Adding MCP Sidecar Containers

OpenClaw는 MCP (Model Context Protocol) 서버를 통해 외부 도구를 사용할 수 있습니다. MCP 서버는 독립적인 컨테이너로 실행하고, 같은 `democlaw-net` 네트워크에 연결하면 OpenClaw가 자동으로 인식합니다.

OpenClaw can use external tools via MCP servers. Run MCP servers as independent containers on the same `democlaw-net` network, and OpenClaw discovers them automatically.

### Example: MarkItDown MCP Server

[MarkItDown](https://github.com/microsoft/markitdown)은 PDF, DOCX, PPTX, HTML 등을 Markdown으로 변환하는 MCP 서버입니다.

#### Option A: Custom SSE image (recommended for DemoClaw)

DemoClaw의 커스텀 이미지는 SSE transport를 지원하므로 컨테이너 간 네트워크 통신이 가능합니다.

```bash
# Linux
docker run -d \
    --name markitdown \
    --network democlaw-net \
    --network-alias markitdown \
    --restart unless-stopped \
    -p 3001:3001 \
    -e "MARKITDOWN_PORT=3001" \
    -e "MARKITDOWN_HOST=0.0.0.0" \
    docker.io/jinwangmok/democlaw-markitdown:v1.1.0
```

```powershell
# Windows
docker run -d --name markitdown --network democlaw-net --network-alias markitdown --restart unless-stopped -p 3001:3001 -e "MARKITDOWN_PORT=3001" -e "MARKITDOWN_HOST=0.0.0.0" docker.io/jinwangmok/democlaw-markitdown:v1.1.0
```

Health check:
```bash
curl http://localhost:3001/health
# {"status": "ok", "service": "markitdown-mcp"}
```

#### Option B: Official Docker Hub image

Docker Hub의 공식 MCP 카탈로그에 `mcp/markitdown` 이미지가 있습니다. 단, 이 이미지는 **STDIO transport**만 지원하므로 컨테이너 간 네트워크 통신이 아닌 Claude Desktop 등의 STDIO 기반 MCP 클라이언트에 적합합니다.

```bash
# STDIO transport — for use with Claude Desktop or other STDIO-based MCP clients
docker run -i --rm mcp/markitdown
```

> **Note:** DemoClaw의 OpenClaw는 SSE transport로 MCP 서버에 접근하므로, 네트워크 기반 사이드카 용도에는 Option A를 사용하세요.

### Step 1: Run the MCP server container

MCP 서버 컨테이너를 `democlaw-net` 네트워크에 연결하여 실행합니다. `--network-alias`는 OpenClaw가 컨테이너를 찾는 데 사용하는 호스트명입니다.

```bash
docker run -d \
    --name "democlaw-my-tool" \
    --network democlaw-net \
    --network-alias my-tool \
    --restart unless-stopped \
    -p 4000:4000 \
    myorg/my-mcp-server:latest
```

### Step 2: Register in `config/mcporter.json`

`config/mcporter.json`에 MCP 서버를 등록합니다. `url`에는 컨테이너 네트워크 별칭을 사용합니다 (`localhost`가 아님).

```json
{
  "servers": {
    "markitdown": {
      "transport": "sse",
      "url": "http://markitdown:3001/sse",
      "description": "MarkItDown document converter"
    },
    "my-tool": {
      "transport": "sse",
      "url": "http://my-tool:4000/sse",
      "description": "Description of your MCP server"
    }
  }
}
```

### Step 3: Restart OpenClaw

mcporter.json을 수정한 후 OpenClaw를 재시작하면 새 MCP 서버를 인식합니다.

```bash
# Stop and restart the stack (MCP sidecar containers are not affected)
./scripts/stop.sh
./scripts/start.sh
```

### Step 4: Register via OpenClaw Web UI

mcporter.json 외에 OpenClaw 웹 UI에서도 MCP 서버를 등록할 수 있습니다.

You can also register MCP servers directly through the OpenClaw web dashboard:

1. 브라우저에서 OpenClaw 대시보드를 엽니다 (`http://localhost:18789` 또는 start 출력의 토큰 URL).
2. 좌측 사이드바에서 **Settings** (설정)을 클릭합니다.
3. **MCP Servers** 섹션으로 이동합니다.
4. **Add Server** 버튼을 클릭합니다.
5. 다음 정보를 입력합니다:
   - **Name**: `markitdown` (또는 원하는 이름)
   - **Transport**: `SSE`
   - **URL**: `http://markitdown:3001/sse` (컨테이너 네트워크 별칭 사용)
6. **Save**를 클릭하면 즉시 적용됩니다 (재시작 불필요).

> **Tip:** 웹 UI에서 등록한 MCP 서버는 OpenClaw의 내부 설정에 저장됩니다. `mcporter.json`은 컨테이너 시작 시 초기 등록에만 사용됩니다.

### Step 5: Verify

```bash
# Check the MCP server health
curl http://localhost:3001/health

# Verify OpenClaw discovered the tools — check the dashboard
# The AI agent should now have access to the MCP server's tools
```

## Workspace Volume Mount

OpenClaw 컨테이너의 워크스페이스를 호스트 디렉토리와 연결하려면 `.env`에 `OPENCLAW_WORKSPACE_DIR`을 설정합니다.

To mount a host directory into the OpenClaw container at `/app/workspace`:

### Setup

```bash
cp .env.example .env
```

`.env` 파일에서 다음 줄의 주석을 해제하고 경로를 지정합니다:

```bash
# Host directory to mount into OpenClaw container at /app/workspace
OPENCLAW_WORKSPACE_DIR=/path/to/your/workspace
```

Windows:
```
OPENCLAW_WORKSPACE_DIR=C:\Users\YourName\workspace
```

### How it works

- `start.sh` / `start.bat`이 `OPENCLAW_WORKSPACE_DIR` 환경변수를 감지하면 해당 디렉토리를 OpenClaw 컨테이너의 `/app/workspace`에 읽기/쓰기 모드로 마운트합니다.
- 변수가 설정되지 않으면 볼륨 마운트 없이 실행됩니다 (기본 동작).
- 지정된 디렉토리가 존재하지 않으면 경고를 출력하고 마운트를 건너뜁니다.

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
| `MODEL_DIR` | `~/.cache/democlaw/models` | Host model cache directory |
| `OPENCLAW_WORKSPACE_DIR` | *(unset)* | Host directory to mount into OpenClaw |

See `.env.example` for the full list.

## Make Targets

```
make start       Start full stack
make stop        Stop all containers
make restart     Restart full stack
make build       Build container images (llama.cpp + OpenClaw)
make status      Show container states
make logs        Tail logs (SERVICE=llamacpp|openclaw)
make shell       Exec into container (SERVICE=llamacpp|openclaw)
make clean       Remove containers, images, and volumes
make env-check   Validate GPU and runtime setup
make help        Show all targets
```

## Project Structure

```
democlaw/
├── llamacpp/           # llama.cpp container (Dockerfile, entrypoint, healthcheck)
├── openclaw/           # OpenClaw container (Dockerfile, entrypoint, healthcheck)
├── markitdown/         # MarkItDown MCP server (standalone example sidecar)
├── config/
│   └── mcporter.json   # MCP server registry (volume-mounted into OpenClaw)
├── scripts/
│   ├── start.sh            # Full stack startup (Linux)
│   ├── start.bat           # Full stack startup (Windows)
│   ├── stop.sh             # Stack teardown (Linux)
│   ├── stop.bat            # Stack teardown (Windows)
│   ├── device-approve.sh   # Approve pending devices from host (Linux)
│   ├── device-approve.bat  # Approve pending devices from host (Windows)
│   ├── download-model.sh   # Pre-download model weights
│   └── reference/
│       └── image.sh        # Image pull-or-build library (sourced by start.sh)
├── examples/skills/    # Custom OpenClaw skill templates
├── docs/               # API and config reference
├── .env.example        # Environment configuration template
└── Makefile            # Container lifecycle targets
```

## License

MIT
