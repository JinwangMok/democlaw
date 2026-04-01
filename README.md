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
git clone https://github.com/JinwangMok/democlaw.git
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
git clone https://github.com/JinwangMok/democlaw.git
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

### Discord Pairing

Discord 봇에 DM을 보내면 페어링 코드가 발급됩니다. 이 코드는 `openclaw devices list`가 아닌 `openclaw pairing` 시스템으로 관리되므로, 별도 명령으로 승인해야 합니다.

When you DM the Discord bot, it issues a pairing code. This code is managed by the `openclaw pairing` system (separate from `openclaw devices`), so use the `--pairing` flag to approve it.

```bash
# Linux
./scripts/device-approve.sh --pairing discord <CODE>

# Windows
scripts\device-approve.bat --pairing discord <CODE>
```

또는 컨테이너에서 직접 실행할 수도 있습니다:

Or run directly inside the container:

```bash
docker exec democlaw-openclaw openclaw pairing approve discord <CODE>
```

## MCP (Model Context Protocol) Sidecar

OpenClaw는 MCP 서버를 통해 외부 도구를 사용할 수 있습니다. DemoClaw는 [supergateway](https://github.com/supercorp-ai/supergateway)를 사용하여 별도 컨테이너의 SSE MCP 서버를 OpenClaw에 연결합니다.

```
OpenClaw (stdio) → supergateway (SSE→stdio bridge) → MCP sidecar container (SSE)
```

### Example: MarkItDown MCP

[MarkItDown](https://github.com/microsoft/markitdown)은 PDF, DOCX, HTML 등을 Markdown으로 변환하는 MCP 서버입니다. 공식 Docker Hub 이미지 `mcp/markitdown`을 사용합니다.

#### Step 1: MarkItDown 컨테이너 실행

```bash
# Linux
docker run -d \
    --name markitdown \
    --network democlaw-net \
    --network-alias markitdown \
    --restart unless-stopped \
    -p 3001:3001 \
    mcp/markitdown --http --host 0.0.0.0 --port 3001
```

```powershell
# Windows
docker run -d --name markitdown --network democlaw-net --network-alias markitdown --restart unless-stopped -p 3001:3001 mcp/markitdown --http --host 0.0.0.0 --port 3001
```

#### Step 2: 웹 UI에서 MCP 서버 등록

1. 브라우저에서 OpenClaw 대시보드를 엽니다.
2. **Settings** > **Infrastructure** > **Mcp** 탭 (오른쪽 끝으로 스크롤).
3. **MCP Servers** > **+ Add Entry** 클릭.
4. 다음 정보를 입력합니다:
   - **Name**: `markitdown`
   - **Command**: `supergateway`
   - **Args**: `--sse` 와 `http://markitdown:3001/sse` (각각 별도 항목으로 + Add)
5. **Save** 클릭 → 게이트웨이가 자동 재시작됩니다.
6. 약 20초 후 토큰 URL로 다시 접속합니다.

#### Step 3: Chat에서 사용

새 세션에서 다음과 같이 사용합니다:

```
Call convert_to_markdown with uri http://info.cern.ch
```

에이전트가 `convert_to_markdown` MCP 도구를 호출하여 웹 페이지를 마크다운으로 변환합니다.

> **Note:** HTTPS URL은 컨테이너 환경에 따라 SSL 인증서 오류가 발생할 수 있습니다. HTTP URL을 사용하세요.

### 추가 MCP 서버 연결하기

다른 SSE MCP 서버도 같은 패턴으로 연결할 수 있습니다.

#### Step 1: MCP 서버 컨테이너를 democlaw-net에 실행

```bash
docker run -d \
    --name my-mcp-server \
    --network democlaw-net \
    --network-alias my-mcp \
    -p 4000:4000 \
    my-org/my-mcp-image --http --host 0.0.0.0 --port 4000
```

#### Step 2: 웹 UI에서 등록

Infrastructure > Mcp > + Add Entry:
- **Name**: `my-mcp`
- **Command**: `supergateway`
- **Args**: `--sse` + `http://my-mcp:4000/sse`

Save 후 자동 재시작.

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                    democlaw-net                       │
│                                                     │
│  ┌───────────────────────────────┐                  │
│  │ OpenClaw container            │                  │
│  │                               │                  │
│  │  openclaw-gateway             │                  │
│  │    └─ supergateway (stdio)  ──┼──► markitdown    │
│  │    └─ supergateway (stdio)  ──┼──► my-mcp        │
│  └───────────────────────────────┘                  │
│                                                     │
│  ┌────────────┐  ┌────────────┐                     │
│  │ markitdown │  │  my-mcp    │                     │
│  │ SSE :3001  │  │  SSE :4000 │                     │
│  └────────────┘  └────────────┘                     │
└─────────────────────────────────────────────────────┘
```

### Web UI에서 MCP 설정 확인

등록된 MCP 서버는 웹 UI에서 확인할 수 있습니다:

1. **Settings** > **Infrastructure** > **Mcp** 탭 (오른쪽 끝)
2. **MCP Servers** 섹션에서 등록된 서버 확인

> **Note:** 웹 UI에서 Save하면 게이트웨이가 재시작됩니다. 약 20초 후 토큰 URL로 다시 접속하세요.

## Data Persistence

기본적으로 OpenClaw의 설정, 디바이스 페어링, 인증 정보는 컨테이너 내부에만 저장됩니다. 컨테이너를 재시작하면 모든 상태가 초기화됩니다.

By default, OpenClaw settings, device pairings, and credentials are stored inside the container. Restarting the container resets all state.

### Setup

`OPENCLAW_DATA_DIR`을 설정하면 이 데이터를 호스트에 영속화할 수 있습니다.

Set `OPENCLAW_DATA_DIR` to persist this data on the host.

```bash
cp .env.example .env   # if not already done
```

`.env` 파일에서 / In your `.env` file:

```bash
OPENCLAW_DATA_DIR=/path/to/openclaw-data
```

Windows:
```
OPENCLAW_DATA_DIR=C:\Users\YourName\.openclaw-data
```

### How it works

- `start.sh` / `start.bat`이 `OPENCLAW_DATA_DIR`을 감지하면 해당 디렉토리를 컨테이너의 `/home/openclaw/.openclaw`에 읽기/쓰기 모드로 마운트합니다.
- 변수가 설정되지 않으면 마운트 없이 실행됩니다 (기본 동작, 모든 상태는 일시적).
- 지정된 디렉토리가 존재하지 않으면 자동 생성됩니다.

- When `OPENCLAW_DATA_DIR` is set, `start.sh` / `start.bat` mounts it to `/home/openclaw/.openclaw` in read-write mode.
- When unset, no mount occurs and all state is ephemeral (default behavior).
- If the directory does not exist, it is created automatically.

컨테이너를 재시작해도 다음 항목이 유지됩니다:

The following data is preserved across container restarts:

| Data | Description |
|------|-------------|
| `devices/` | Device and Discord pairing info |
| `credentials/` | Authentication tokens |
| `openclaw.json` | Settings (MCP servers, agents, etc.) |
| `identity/` | Instance identity |

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
| `OPENCLAW_DATA_DIR` | *(unset)* | Host directory to persist OpenClaw settings/pairings |
| `OPENCLAW_WORKSPACE_DIR` | *(unset)* | Host directory to mount into OpenClaw |

See `.env.example` for the full list.

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
