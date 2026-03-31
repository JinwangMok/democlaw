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

# LLM API (use curl.exe on Windows PowerShell)
curl http://localhost:8000/v1/models

# OpenClaw dashboard — open in browser
# http://localhost:18789 (or the tokenized URL from start output)
```

### Stop

```bash
# Linux
./scripts/stop.sh

# Windows
scripts\stop.bat
```

## Use Cases

스택을 시작한 후 (`./scripts/start.sh` 또는 `scripts\start.bat`), 브라우저에서 대시보드 URL을 열고 Chat에서 다음과 같이 활용할 수 있습니다.

After starting the stack, open the dashboard URL in your browser and try these in the Chat:

### 1. 날씨 확인 (Weather Check)

출근 전 날씨를 확인하고 우산이 필요한지 물어봅니다.

```
서울 오늘 날씨 어때? 우산 가져가야 할까?
```

에이전트가 `web_search` 도구로 실시간 날씨를 검색하고, 비 예보 여부와 우산 조언을 한국어로 답변합니다.

### 2. 뉴스 리서치 (News Research)

업계 최신 동향을 빠르게 파악합니다.

```
2026년 3월 AI 업계 최신 뉴스 3개를 검색해서 요약해줘. 각 뉴스의 핵심을 한 줄로.
```

에이전트가 `web_search`로 최신 기사를 검색하고, 각 뉴스를 한 줄로 요약합니다.

### 3. 코드 작성 (Code Generation)

업무 자동화용 스크립트를 작성합니다.

```
Write a Python function that calculates compound interest.
Parameters: principal, annual_rate, years, compounds_per_year.
Include an example usage.
```

에이전트가 함수 코드와 사용 예시를 생성합니다.

### Built-in Agent Tools

OpenClaw 에이전트는 다음 도구를 기본 탑재하고 있습니다:

| Tool | Description |
|------|-------------|
| `web_search` | 웹 검색 (날씨, 뉴스, 정보 조회) |
| `web_fetch` | URL 내용 가져오기 (컨테이너 네트워크 환경에 따라 제한될 수 있음) |
| `read` / `write` | 워크스페이스 파일 읽기/쓰기 |

### Available Skills

`openclaw skills list` 명령으로 사용 가능한 스킬을 확인할 수 있습니다. 기본 제공 스킬 중 별도 설정 없이 사용 가능한 것들:

| Skill | Description |
|-------|-------------|
| `weather` | 날씨 및 기상 예보 (API 키 불필요) |
| `healthcheck` | 시스템 보안 점검 |
| `skill-creator` | 커스텀 스킬 생성/편집 |

> **Note:** 대부분의 번들 스킬 (Slack, GitHub, Notion 등)은 별도 CLI 설치 및 인증이 필요합니다. `openclaw skills list`에서 "△ needs setup"으로 표시됩니다.

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

## MCP (Model Context Protocol)

### Current Limitation

OpenClaw v2026.3.28은 **stdio transport MCP 서버만 지원**합니다. SSE 및 Streamable HTTP transport는 아직 지원되지 않습니다.

OpenClaw v2026.3.28 only supports **stdio transport** for MCP servers. SSE and Streamable HTTP are not yet supported.

이는 별도 컨테이너에서 네트워크(SSE)를 통해 MCP 서버를 연결하는 사이드카 패턴이 현재 작동하지 않음을 의미합니다. OpenClaw 로그에서 다음과 같은 메시지를 확인할 수 있습니다:

```
[bundle-mcp] skipped server "markitdown" because only stdio MCP servers are supported right now.
```

### What Works: stdio MCP

stdio MCP는 OpenClaw 컨테이너 **내부에서** 프로세스로 실행되는 MCP 서버입니다. `config/mcporter.json`에 다음 형식으로 등록합니다:

```json
{
  "servers": {
    "my-tool": {
      "command": "uvx",
      "args": ["my-mcp-package"]
    }
  }
}
```

> **Note:** 이를 위해서는 해당 MCP 서버 패키지가 OpenClaw 컨테이너 안에 설치되어 있어야 합니다. 현재 DemoClaw의 OpenClaw 이미지에는 추가 MCP 서버가 번들되어 있지 않습니다.

### What Does NOT Work: SSE Sidecar

`markitdown/` 디렉토리에 SSE transport를 지원하는 MCP 서버 예제가 포함되어 있으나, OpenClaw가 SSE를 지원하지 않아 현재는 사용할 수 없습니다.

The `markitdown/` directory contains a working SSE MCP server, but OpenClaw cannot connect to it because only stdio transport is supported. This server is preserved as a reference implementation for when OpenClaw adds SSE support.

### Web UI에서 MCP 설정 확인

등록된 MCP 서버는 웹 UI에서 확인할 수 있습니다:

1. **Settings** > **Infrastructure** > **Mcp** 탭 (오른쪽 끝)
2. **MCP Servers** 섹션에서 등록된 서버 확인
3. **+ Add Entry**로 새 서버 추가 가능 (stdio `command` 필드 필요)

> **Note:** 웹 UI에서 Save하면 게이트웨이가 재시작됩니다. 약 20초 후 토큰 URL로 다시 접속하세요.

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
