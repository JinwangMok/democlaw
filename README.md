# DemoClaw

NVIDIA GPU에서 **Qwen3-4B AWQ 4비트** 모델을 자체 호스팅하는 [vLLM](https://github.com/vllm-project/vllm) 백엔드와 [OpenClaw](https://github.com/openclaw) AI 비서를 실행하기 위한 셸 스크립트 오케스트레이션입니다. docker-compose가 필요 없습니다.

Shell-script orchestration for running [OpenClaw](https://github.com/openclaw) AI assistant with a self-hosted [vLLM](https://github.com/vllm-project/vllm) backend serving **Qwen3-4B AWQ 4-bit** on NVIDIA GPUs — no docker-compose required.

## 개요 / Overview

DemoClaw는 공유 네트워크 위에 두 개의 컨테이너를 실행합니다:

DemoClaw launches two containers on a shared network:

| Container | Purpose | Host Port |
|-----------|---------|-----------|
| **vLLM** | Serves Qwen3-4B AWQ 4-bit via an OpenAI-compatible API | `localhost:8000` |
| **OpenClaw** | AI assistant web dashboard connected to vLLM | `localhost:18789` |

**Docker**와 **Podman** 모두 지원되며, 스크립트가 사용 가능한 런타임을 자동으로 감지합니다.

Both **Docker** and **Podman** are supported — the scripts auto-detect whichever runtime is available.

## 사전 요구사항 / Prerequisites

### 지원되는 Linux 배포판 / Supported Linux distributions

DemoClaw는 **Linux x86_64** 호스트가 필요합니다. 아래 배포판이 테스트되어 지원됩니다:

DemoClaw requires a **Linux x86_64** host. The following distributions are tested and supported:

| Distribution | Minimum Version | Notes |
|--------------|-----------------|-------|
| **Ubuntu** | 22.04 LTS (Jammy) | 24.04 LTS (Noble) also supported and recommended |
| **Debian** | 12 (Bookworm) | |
| **Fedora** | 38 | |
| **RHEL / CentOS Stream / Rocky / AlmaLinux** | 9 | |

> macOS는 **지원되지 않습니다**. Windows는 **Docker Desktop** (WSL2 백엔드)를 통해 지원됩니다 — [Windows 빠른 시작](#windows-quick-start) 참조.
>
> macOS is **not supported**. Windows is supported via **Docker Desktop** (which uses WSL2 backend) — see [Windows Quick Start](#windows-quick-start).

### 필수 소프트웨어 / Required software

| Requirement | Minimum Version | Details |
|-------------|-----------------|---------|
| **Docker** _or_ **Podman** | Docker ≥ 20.10 / Podman ≥ 4.1 | Only **one** runtime is required. Docker needs `--gpus` flag support (≥ 20.10); Podman needs CDI GPU support (≥ 4.1). Install Docker from the [official guide](https://docs.docker.com/engine/install/) or Podman from the [official guide](https://podman.io/docs/installation). |
| **NVIDIA Container Toolkit** | ≥ 1.14 | Bridges NVIDIA drivers into containers — required for both Docker and Podman GPU passthrough. [Install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) |
| **curl** | ≥ 7.68 | Used by healthcheck scripts (pre-installed on most distros) |
| **bash** | ≥ 4.0 | Required by all orchestration scripts |

> **Note:** Only one container runtime (Docker **or** Podman) is required — not both. The scripts auto-detect whichever is available.

### 하드웨어 및 드라이버 요구사항 / Hardware and driver requirements

| Requirement | Minimum | Recommended | Notes |
|-------------|---------|-------------|-------|
| **NVIDIA GPU** | 8 GB VRAM | 12 GB+ VRAM | The AWQ 4-bit model uses ~5–6 GB VRAM; ≥ 8 GB provides safe headroom. Examples: RTX 3070, RTX 3080, RTX 4060 Ti, RTX 4080, A10, L40S |
| **NVIDIA Driver** | 520 | 560+ | Driver ≥ 520 exposes CUDA 11.8 driver API; driver ≥ 535 exposes CUDA 12.2. Verify with `nvidia-smi`. |
| **CUDA driver API version** | 11.8 | 12.x | The CUDA version _reported by `nvidia-smi`_ — determined by your driver, **not** by a separately installed CUDA Toolkit (see note below). |
| **System RAM** | 16 GB | 32 GB+ | Required for model tokenization overhead and container runtime |
| **Disk space** | 15 GB free | 30 GB+ free | ~5 GB for model weights (cached in `HF_CACHE_DIR`), ~3 GB for container images, remainder for logs and temp files |
| **Internet access** | Required (first run) | — | Model weights (~5 GB) are downloaded from HuggingFace on first launch and cached locally for subsequent runs |

#### CUDA Toolkit과 CUDA 드라이버 API — 알아야 할 것 / CUDA Toolkit vs CUDA driver API — what you need to know

The NVIDIA CUDA ecosystem has two distinct components:

- **CUDA driver API** (host-side): Provided automatically by your NVIDIA driver. The version shown by `nvidia-smi` (e.g. `CUDA Version: 12.4`) is this value. **This is the only CUDA-related component required on the host.**
- **CUDA Toolkit** (compiler, libraries, headers): Used by developers to build CUDA applications from source. **You do NOT need to install the CUDA Toolkit on the host.** The vLLM container image (`vllm/vllm-openai`) bundles its own CUDA runtime libraries and runs entirely within the container.

In summary: install NVIDIA driver ≥ 520 and you have everything the host needs. CUDA 12.x Toolkit is packaged inside the `vllm/vllm-openai` container image.

### 사전 요구사항 확인 / Verify prerequisites

Run these commands before launching to confirm your environment is ready:

```bash
# 1. GPU driver — must return a table with your GPU and CUDA version
nvidia-smi

# 2. CUDA driver API version — must be ≥ 11.8
nvidia-smi | grep "CUDA Version"

# 3. Container runtime — at least one of these must work
docker --version
podman --version

# 4. NVIDIA Container Toolkit
nvidia-ctk --version

# 5. All-in-one environment check (uses the bundled Makefile target)
make env-check
```

### NVIDIA 드라이버 설치 / Installing the NVIDIA Driver

<details>
<summary>Ubuntu / Debian</summary>

```bash
# Check available NVIDIA driver versions
ubuntu-drivers devices

# Install the recommended driver automatically (Ubuntu)
sudo ubuntu-drivers autoinstall

# Or install a specific version (replace 560 with the version listed by ubuntu-drivers devices)
sudo apt-get install -y nvidia-driver-560

# Reboot to load the driver
sudo reboot

# Verify installation
nvidia-smi
```

</details>

<details>
<summary>Fedora / RHEL</summary>

```bash
# Fedora — enable RPM Fusion then install the driver
# Full guide: https://rpmfusion.org/Howto/NVIDIA
sudo dnf install akmod-nvidia
sudo reboot

# RHEL / CentOS Stream / Rocky / AlmaLinux
# Full guide: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/

# Verify installation
nvidia-smi
```

</details>

### NVIDIA Container Toolkit 설치 / Installing the NVIDIA Container Toolkit

The NVIDIA Container Toolkit is required on the host so the container runtime can pass the GPU through into containers. Install it **after** the driver is working (`nvidia-smi` succeeds).

<details>
<summary>Docker — Ubuntu / Debian</summary>

```bash
# Add the NVIDIA package repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# Configure Docker to use the NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify — should print your GPU info from inside a container
docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
```

</details>

<details>
<summary>Podman — Ubuntu / Debian</summary>

```bash
# Install toolkit (same packages as Docker variant)
sudo apt-get install -y nvidia-container-toolkit

# Generate CDI (Container Device Interface) spec so Podman can discover the GPU
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Verify CDI entries — look for "nvidia.com/gpu=0"
nvidia-ctk cdi list

# Verify — should print your GPU info from inside a container
podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
```

</details>

<details>
<summary>Fedora / RHEL (Docker or Podman)</summary>

```bash
# Enable the NVIDIA container toolkit repository
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo

sudo dnf install -y nvidia-container-toolkit

# For Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# For Podman (generate CDI spec)
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

</details>

## 빠른 시작 / Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/JinwangMok/democlaw.git
cd democlaw

# 2. (Optional) Copy and edit the environment file
cp .env.example .env
# Edit .env to customize ports, model, VRAM settings, etc.

# 3. Launch both containers (runtime auto-detected: docker or podman)
./scripts/start.sh

# — or force a specific runtime —
CONTAINER_RUNTIME=docker ./scripts/start.sh   # force Docker
CONTAINER_RUNTIME=podman ./scripts/start.sh   # force Podman
```

The script will:
1. Auto-detect Docker or Podman (or use `CONTAINER_RUNTIME` if set)
2. Validate your NVIDIA GPU and CUDA drivers — exits immediately with a clear error if absent
3. Build the container images (first run only; cached on subsequent runs)
4. Start the vLLM server and wait for model loading (~5 GB download on first run)
5. Start OpenClaw and connect it to vLLM via the `democlaw-net` network
6. Run healthchecks on both services

준비가 완료되면 브라우저에서 **http://localhost:18789** 을 열어 OpenClaw 대시보드에 접속하세요.

Once ready, open **http://localhost:18789** in your browser to access the OpenClaw dashboard.

## 설치 가이드 / Installation Guide

이 가이드는 새 Linux 머신에서 DemoClaw를 실행하기 위한 모든 단계를 안내합니다 — 저장소 클론부터 두 서비스의 정상 동작 확인까지.

This guide walks you through every step required to get DemoClaw running on a fresh Linux machine — from cloning the repository to verifying both services are healthy.

### 1단계 — 저장소 클론 / Step 1 — Clone the repository

```bash
git clone https://github.com/JinwangMok/democlaw.git
cd democlaw
```

### 2단계 — 환경 변수 설정 / Step 2 — Configure environment variables

Copy the bundled template to create your local `.env` file:

```bash
cp .env.example .env
```

Open `.env` in your editor and review the settings. The defaults work out-of-the-box for most machines, but the table below highlights the variables you are most likely to want to change:

| Variable | Default | When to change |
|----------|---------|----------------|
| `CONTAINER_RUNTIME` | *(auto-detect)* | Set to `docker` or `podman` to force a specific runtime |
| `MODEL_NAME` | `Qwen/Qwen3-4B-AWQ` | Change only if you want a different AWQ 4-bit model |
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
MAX_MODEL_LEN=16384
GPU_MEMORY_UTILIZATION=0.85
```

> All scripts automatically load `.env` from the project root at startup, so no `export` or `source` is needed.

### 3단계 — 환경 및 GPU 설정 확인 / Step 3 — Verify your environment and GPU setup

Before launching containers, run the bundled GPU preflight check to confirm all hardware and software prerequisites are in place. This step is critical — **the stack will not start if your GPU, CUDA drivers, or container toolkit are misconfigured**, and catching issues here saves debugging time later.

#### 3a — Quick environment check (summary)

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

#### 3b — Full GPU preflight validation

For a detailed check that verifies every GPU prerequisite — driver version, CUDA version, VRAM, and container toolkit integration — run the dedicated script:

```bash
./scripts/check-gpu.sh
```

This script checks (in order):

| Check | Requirement | What it verifies |
|-------|-------------|-----------------|
| 1 | Linux host OS | Must be running Linux (macOS/Windows not supported) |
| 2 | `nvidia-smi` | Must be in `PATH` and communicate with the driver |
| 3 | NVIDIA GPU | At least one physical GPU detected |
| 4 | NVIDIA driver | Version ≥ 520 (exposes CUDA 11.8 driver API) |
| 5 | CUDA version | ≥ 11.8, required by vLLM |
| 6 | GPU VRAM | ≥ 7500 MiB (~7.3 GB) for Qwen3-4B AWQ 4-bit |
| 7 | Container toolkit | `nvidia-container-toolkit` configured for detected runtime |

**Expected output when all checks pass:**

```
[check-gpu] Host OS: Linux 6.8.0-45-generic
[check-gpu] Detected container runtime: docker (Docker version 26.1.0, ...)
[check-gpu] NVIDIA SMI: found
[check-gpu] GPU hardware: 1 device(s) detected
[check-gpu] GPU[0]: NVIDIA GeForce RTX 4070 — 12288 MiB VRAM
[check-gpu] Driver version: 560.94 (minimum 520.0) — OK
[check-gpu] CUDA version: 12.4 (minimum 11.8) — OK
[check-gpu] GPU VRAM: 12288 MiB (minimum 7500 MiB) — OK
[check-gpu] NVIDIA Container Toolkit: configured for docker — OK

[check-gpu] ============================================================
[check-gpu]   GPU preflight PASSED — host is ready for DemoClaw
[check-gpu] ============================================================

[check-gpu]   Next step: start the DemoClaw stack with:
[check-gpu]     ./scripts/start.sh
```

Exit code: `0` — all checks passed, proceed to the next step.

**Common GPU check failure messages:**

| Error message | Cause | Fix |
|---------------|-------|-----|
| `ERROR: nvidia-smi not found in PATH` | NVIDIA driver not installed | Install NVIDIA driver — see [Prerequisites](#prerequisites) |
| `ERROR: No NVIDIA GPU devices detected` | GPU absent or driver not loaded | Check `lspci \| grep -i nvidia`; reboot after driver install |
| `ERROR: CUDA version 11.2 is below minimum 11.8` | Driver too old | Upgrade to NVIDIA driver ≥ 520 |
| `ERROR: Insufficient GPU VRAM: 6144 MiB detected, but 7500 MiB required` | GPU has < 8 GB VRAM | Use a GPU with ≥ 8 GB VRAM, or reduce `MAX_MODEL_LEN` in `.env` |
| `ERROR: nvidia-container-toolkit not configured for docker` | Toolkit missing | Run `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker` |

> **Note:** `check-gpu.sh` is also called automatically by `start.sh`, `start-vllm.sh`, and all orchestration scripts before launching any containers. If you skip this step, the start scripts will still catch GPU issues before pulling or running images — but running `check-gpu.sh` first gives faster feedback.

If `nvidia-smi` is not found or the NVIDIA runtime is missing, follow the full installation instructions in the [Prerequisites](#prerequisites) section above.

### 4단계 — 컨테이너 이미지 빌드 / Step 4 — Build the container images

Before launching, build both container images from the local Dockerfiles. This step is done automatically by `./scripts/start.sh` on the first run, but you can also build them explicitly:

```bash
# Build both images using the Makefile (recommended — runtime auto-detected)
make build

# Or build each image individually
make build-vllm      # builds democlaw/vllm:latest
make build-openclaw  # builds democlaw/openclaw:latest
```

**With Docker** (direct runtime commands):

```bash
docker build -t democlaw/vllm:latest     vllm/
docker build -t democlaw/openclaw:latest openclaw/
```

**With Podman** (direct runtime commands):

```bash
podman build -t democlaw/vllm:latest     vllm/
podman build -t democlaw/openclaw:latest openclaw/
```

> **Tip:** If you just run `./scripts/start.sh` or `make start` without building first, images are built automatically on the first run and reused on subsequent runs. Explicit `make build` is useful when you want to pre-pull and build before running (e.g. in CI, on slow networks, or to verify the Dockerfiles before deployment).

### 5단계 — Docker로 실행 / Step 5 — Launch with Docker

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
3. The vLLM server starts and downloads the Qwen3-4B AWQ 4-bit model weights from HuggingFace (~5 GB on first run; cached afterwards).
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

### 6단계 — Podman으로 실행 / Step 6 — Launch with Podman

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

---

### 7단계 — vLLM 컨테이너 개별 실행 / Step 7 — Launch the vLLM container (individual)

> **Skip this step if you already ran `make start` or `./scripts/start.sh` in Steps 5–6.** This section shows how to launch the vLLM server on its own, which is useful when you want to monitor model loading before starting OpenClaw, or when troubleshooting the vLLM service independently.

```bash
# Auto-detect runtime (Docker or Podman)
./scripts/start-vllm.sh

# Or force a specific runtime
CONTAINER_RUNTIME=docker ./scripts/start-vllm.sh
CONTAINER_RUNTIME=podman ./scripts/start-vllm.sh
```

**What the script does:**

| Phase | Action |
|-------|--------|
| 1 | Validates Linux host OS, container runtime, and NVIDIA GPU/CUDA drivers |
| 2 | Builds `democlaw/vllm:latest` from `vllm/Dockerfile` (skipped if image exists) |
| 3 | Downloads Qwen3-4B AWQ 4-bit weights from HuggingFace (~5 GB, first run only) |
| 4 | Starts the `democlaw-vllm` container on `democlaw-net` with GPU passthrough |
| 5 | Polls `GET /health` every 5 s until the server responds (timeout: 300 s) |
| 6 | Confirms `Qwen/Qwen3-4B-AWQ` appears in `GET /v1/models`, then exits |

**Expected output when the model is loaded and the server is healthy:**

```
[start-vllm] Phase 1/2: Waiting for /health endpoint at http://localhost:8000/health ...
[start-vllm]   ... waiting for /health (5/300s)
[start-vllm]   ... waiting for /health (10/300s)
...
[start-vllm] /health endpoint is responding.
[start-vllm] Phase 2/2: Verifying /v1/models endpoint lists 'Qwen/Qwen3-4B-AWQ' ...
[start-vllm] /v1/models responded successfully.
[start-vllm]   Available models: Qwen/Qwen3-4B-AWQ
[start-vllm] Expected model 'Qwen/Qwen3-4B-AWQ' confirmed.
[start-vllm]
[start-vllm] vLLM server is healthy and ready to serve requests.
[start-vllm]   API endpoint: http://localhost:8000/v1
[start-vllm]   Models API  : http://localhost:8000/v1/models
[start-vllm]   Health check: http://localhost:8000/health
```

**Verify vLLM is accepting requests before proceeding:**

```bash
# Liveness check — expects HTTP 200 (empty body)
curl -sf http://localhost:8000/health && echo "vLLM is up"

# List loaded models — confirm Qwen/Qwen3-4B-AWQ appears
curl http://localhost:8000/v1/models | python3 -m json.tool
```

> **First-run note:** On first launch, vLLM downloads ~5 GB of model weights. The download takes several minutes depending on your internet connection. Monitor progress with:
> ```bash
> docker logs -f democlaw-vllm   # Docker
> podman logs -f democlaw-vllm   # Podman
> make logs-vllm                 # via Makefile
> ```
> The server is ready when the log shows `INFO: Application startup complete.`

> **GPU error — what it looks like:**
> If `start-vllm.sh` cannot find a valid NVIDIA GPU or CUDA driver, it exits immediately with a message like:
> ```
> [start-vllm] ERROR: nvidia-smi not found in PATH. Install the NVIDIA driver and try again.
> ```
> See the [Prerequisites](#prerequisites) section for NVIDIA driver and container toolkit installation instructions.

---

### 8단계 — OpenClaw 컨테이너 개별 실행 / Step 8 — Launch the OpenClaw container (individual)

> **Skip this step if you already ran `make start` or `./scripts/start.sh` in Steps 5–6.** This section shows how to launch the OpenClaw dashboard container on its own, after the vLLM server is running.
>
> **Important:** The vLLM container (`democlaw-vllm`) must be running before you start OpenClaw. Confirm with `curl -sf http://localhost:8000/health` — it should return HTTP 200.

```bash
# Auto-detect runtime (Docker or Podman)
./scripts/start-openclaw.sh

# Or force a specific runtime
CONTAINER_RUNTIME=docker ./scripts/start-openclaw.sh
CONTAINER_RUNTIME=podman ./scripts/start-openclaw.sh
```

**What the script does:**

| Phase | Action |
|-------|--------|
| 1 | Detects the container runtime and verifies Linux host OS |
| 2 | Ensures the `democlaw-net` container network exists |
| 3 | Verifies `democlaw-vllm` is running and connected to `democlaw-net` |
| 4 | Builds `democlaw/openclaw:latest` from `openclaw/Dockerfile` (skipped if image exists) |
| 5 | Starts `democlaw-openclaw` on `democlaw-net`, publishing port `18789` on the host |
| 6 | The entrypoint writes an LLM provider config pointing at `http://vllm:8000/v1` and starts the Node.js web server |
| 7 | Polls `http://localhost:18789` every 3 s until it returns HTTP 200 (timeout: 120 s) |
| 8 | Validates the provider connection from within the container network, then exits |

**Expected output when the dashboard is ready:**

```
[start-openclaw] =======================================================
[start-openclaw]   Starting OpenClaw container
[start-openclaw] =======================================================
[start-openclaw]   Container  : democlaw-openclaw
[start-openclaw]   Image      : democlaw/openclaw:latest
[start-openclaw]   Network    : democlaw-net (alias: openclaw)
[start-openclaw]   Dashboard  : localhost:18789 -> container:18789
[start-openclaw]   vLLM URL   : http://vllm:8000/v1
[start-openclaw]   Model      : Qwen/Qwen3-4B-AWQ
[start-openclaw] =======================================================
[start-openclaw] Container 'democlaw-openclaw' started successfully.
[start-openclaw] Waiting for OpenClaw dashboard at http://localhost:18789 (timeout: 120s) ...
[start-openclaw]   ... waiting (3/120s)
[start-openclaw]
[start-openclaw] =============================================
[start-openclaw]   OpenClaw dashboard is ready!
[start-openclaw]   URL: http://localhost:18789
[start-openclaw] =============================================
[start-openclaw]
[start-openclaw] Provider connection confirmed — OpenClaw is fully ready.
```

Open **http://localhost:18789** in your browser to access the OpenClaw AI assistant dashboard.

> **Headless server:** If you are running on a server without a desktop environment, use SSH port-forwarding to access the dashboard from your local machine:
> ```bash
> # Run on your LOCAL machine — replace user@server with your SSH details
> ssh -L 18789:localhost:18789 user@your-server-address
> ```
> Then open **http://localhost:18789** in your local browser while the tunnel is active.

> **If OpenClaw times out waiting for vLLM:** This normally means the vLLM model is still loading. Check vLLM status with `./scripts/healthcheck.sh --vllm-only` and wait until the model appears in `GET /v1/models` before retrying `./scripts/start-openclaw.sh`.

---

### 9단계 — 설치 확인 / Step 9 — Verify the installation

Once `./scripts/start.sh` (or `make start`) exits with the **"Both services started successfully!"** banner — or after you have run both `./scripts/start-vllm.sh` and `./scripts/start-openclaw.sh` individually — run the bundled healthcheck script to confirm both containers are fully operational:

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
  ✓ vLLM model loaded — 'Qwen/Qwen3-4B-AWQ' found in /v1/models
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

### 10단계 — 스택 중지 / Step 10 — Stop the stack

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

## 사용법 / Usage

### Makefile 사용 / Using the Makefile

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

### 스크립트 직접 사용 / Using scripts directly

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

### 스크립트 실행 순서 / Script execution order

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

### 특정 컨테이너 런타임 강제 지정 / Forcing a specific container runtime

```bash
# Use Podman explicitly
CONTAINER_RUNTIME=podman ./scripts/start.sh

# Use Docker explicitly
CONTAINER_RUNTIME=docker ./scripts/start.sh
```

## 확인 및 사용 / Verification & Usage

`./scripts/start.sh` 실행이 **"Both services started successfully!"** 배너와 함께 완료된 후, 아래 단계로 스택이 정상인지 확인하고 브라우저에서 OpenClaw 대시보드에 접속하세요.

Once `./scripts/start.sh` exits with the **"Both services started successfully!"** banner, use the steps below to confirm the stack is healthy and to access the OpenClaw dashboard from your browser.

### 두 컨테이너 실행 확인 / Confirm both containers are running

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
  ✓ vLLM model loaded — 'Qwen/Qwen3-4B-AWQ' found in /v1/models
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

### OpenClaw 웹 대시보드 접속 / Access the OpenClaw web dashboard

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

### 서비스 로그 확인 / Check service logs

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

### 빠른 API 테스트 / Quick API smoke test

Verify the vLLM API is responding without running the full healthcheck suite:

```bash
# Liveness probe — expects HTTP 200
curl -sf http://localhost:8000/health && echo "vLLM is up"

# List loaded models
curl http://localhost:8000/v1/models | python3 -m json.tool

# Validate all OpenAI-compatible API endpoints end-to-end
./scripts/validate-api.sh
```

### 기본 문제 해결 / Basic troubleshooting

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

## 헬스체크 / Healthchecks

DemoClaw는 두 가지 범위의 헬스체크 스크립트를 제공합니다: **호스트 측 오케스트레이션** (터미널에서 실행하여 스택 확인)과 **컨테이너 내부 프로브** (컨테이너 런타임의 `HEALTHCHECK` 명령으로 실행).

DemoClaw ships four healthcheck scripts that cover two scopes: **host-side orchestration** (run from your terminal to verify a running stack) and **in-container probes** (executed by the container runtime's built-in `HEALTHCHECK` instruction).

### 시작 후 수동 헬스체크 실행 / Running Healthchecks Manually After Starting

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

### 개요 / Overview

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
| 7 | Model loaded | Verifies `Qwen/Qwen3-4B-AWQ` appears in `/v1/models` response |
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
  ✓ vLLM model loaded — 'Qwen/Qwen3-4B-AWQ' found in /v1/models
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
  ⚠ vLLM model loaded — 'Qwen/Qwen3-4B-AWQ' not found; available: my-other-model
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
    {"check": "vLLM model loaded",        "status": "pass", "detail": "'Qwen/Qwen3-4B-AWQ' found in /v1/models"},
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
| `MODEL_NAME` | `Qwen/Qwen3-4B-AWQ` | Expected model ID in `/v1/models` |
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

### 컨테이너 내부 헬스체크 / In-container healthchecks

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

### 헬스체크 결과 해석 / Interpreting healthcheck results

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

## vLLM OpenAI 호환 API / vLLM OpenAI-Compatible API

vLLM 서버는 **포트 8000** (기본값)에서 OpenAI 호환 REST API를 제공합니다. OpenAI API와 호환되는 모든 클라이언트(공식 Python/JS SDK, curl, LangChain, LlamaIndex, OpenClaw 등)가 `http://localhost:8000/v1`을 가리키면 수정 없이 사용할 수 있습니다.

The vLLM server exposes a fully OpenAI-compatible REST API on **port 8000** (host default).  Any client that works with the OpenAI API — including the official Python/JS SDKs, `curl`, LangChain, LlamaIndex, and OpenClaw — can use it without modification by pointing at `http://localhost:8000/v1`.

> **Full API reference:** [`docs/vllm-api.md`](docs/vllm-api.md) — base URLs, all endpoints, curl/Python/JS examples, authentication, and troubleshooting.

### 엔드포인트 / Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/health` | Liveness probe — returns `200 OK` when the server is accepting requests |
| `GET`  | `/v1/models` | List loaded models (OpenAI `GET /v1/models` format) |
| `POST` | `/v1/chat/completions` | Chat inference (OpenAI `POST /v1/chat/completions` format) |
| `POST` | `/v1/completions` | Text completion (OpenAI `POST /v1/completions` format) |
| `POST` | `/v1/embeddings` | Embeddings (when supported by the model) |

### 기본 포트 / Default port

| Setting | Default | Override |
|---------|---------|----------|
| Container-internal port | `8000` | `VLLM_PORT` |
| Host-published port | `8000` | `VLLM_HOST_PORT` |
| Base URL (from host) | `http://localhost:8000/v1` | `VLLM_BASE_URL` |
| Base URL (container→container) | `http://vllm:8000/v1` | `VLLM_BASE_URL` |

### 사용 예시 / Usage examples

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
      "id": "Qwen/Qwen3-4B-AWQ",
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

#### Streaming chat completion (Python)

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

### API 검증 / Validate the API

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

## 설정 레퍼런스 / Configuration Reference

모든 설정은 환경 변수 또는 프로젝트 루트의 `.env` 파일로 구성할 수 있습니다.

All settings are configurable via environment variables or a `.env` file in the project root. Copy the bundled template to get started:

```bash
cp .env.example .env
# Edit .env with your preferred text editor
```

Every script (`start.sh`, `start-vllm.sh`, `start-openclaw.sh`, `stop.sh`, `healthcheck.sh`, etc.) automatically loads `.env` at startup using `source` — no `export` or manual sourcing is required.

You can also pass any variable inline for a one-off override:

```bash
CONTAINER_RUNTIME=podman MAX_MODEL_LEN=16384 ./scripts/start.sh
```

---

### 포트 매핑 / Port Mappings

The following ports are published from containers to the Linux host:

| Service | Container-internal port | Host port (default) | Override variable | Access URL |
|---------|------------------------|---------------------|-------------------|------------|
| **vLLM API** | `8000` | `8000` | `VLLM_HOST_PORT` | `http://localhost:8000/v1` |
| **OpenClaw dashboard** | `18789` | `18789` | `OPENCLAW_HOST_PORT` | `http://localhost:18789` |

**Container-to-container communication** uses the shared `democlaw-net` bridge network. OpenClaw always reaches vLLM via the internal alias `http://vllm:8000/v1` regardless of what host ports are configured. The `VLLM_BASE_URL` variable controls this internal URL.

**Example — resolve port conflicts:**

```bash
# In .env
VLLM_HOST_PORT=8001
OPENCLAW_HOST_PORT=18790
```

After restarting, the vLLM API is at `http://localhost:8001/v1` and the dashboard at `http://localhost:18790`.

---

### 전체 환경 변수 레퍼런스 / Complete Environment Variable Reference

Variables are grouped by the component they configure. All variables are **optional** — the defaults work out-of-the-box on a machine with one NVIDIA GPU.

#### Runtime & Network

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_RUNTIME` | *(auto-detect)* | Force a specific container runtime. Valid values: `docker`, `podman`. When unset, scripts prefer `docker` if it is in `PATH`, then fall back to `podman`. |
| `DEMOCLAW_NETWORK` | `democlaw-net` | Name of the shared bridge network that connects the vLLM and OpenClaw containers. Created automatically if it does not exist. |

#### vLLM Server — Model

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL_NAME` | `Qwen/Qwen3-4B-AWQ` | HuggingFace model repository ID. Must be an AWQ 4-bit quantized model to stay within the 8 GB VRAM budget. |
| `QUANTIZATION` | `awq` | Quantization method passed to vLLM (`--quantization`). Must match the model format. |
| `DTYPE` | `float16` | Weight data type (`--dtype`). `float16` is required for AWQ models on most consumer GPUs. |
| `MAX_MODEL_LEN` | `8192` | Maximum context window in tokens (`--max-model-len`). Reduce (e.g. `4096`) to lower VRAM usage. |
| `GPU_MEMORY_UTILIZATION` | `0.90` | Fraction of GPU VRAM vLLM is allowed to use (0.0–1.0). Reduce to `0.80`–`0.85` if you see out-of-memory errors. |

#### vLLM Server — Container

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_CONTAINER_NAME` | `democlaw-vllm` | Name assigned to the vLLM container (`--name`). |
| `VLLM_IMAGE_TAG` | `democlaw/vllm:latest` | Local image tag built from `vllm/Dockerfile`. |
| `VLLM_HOST` | `0.0.0.0` | Address the vLLM HTTP server binds to inside the container. |
| `VLLM_PORT` | `8000` | Port the vLLM server listens on **inside** the container. |
| `VLLM_HOST_PORT` | `8000` | Port published on the **host** for direct API access (`http://localhost:VLLM_HOST_PORT/v1`). |
| `VLLM_API_KEY` | *(empty)* | Optional API key for the OpenAI-compatible endpoint. When empty, `EMPTY`, or `none`, vLLM runs in no-auth mode and accepts any request. Set to a real secret to require `Authorization: Bearer <key>` on every API call. |
| `VLLM_HEALTH_TIMEOUT` | `300` | Seconds `start-vllm.sh` waits for the `/health` endpoint to respond before giving up. Increase on slow machines or slow internet connections. |
| `SKIP_MODEL_PULL` | `false` | Set to `true` to skip the model pre-download step. Use this when the weights are already cached in `HF_CACHE_DIR`. |

#### HuggingFace Cache

| Variable | Default | Description |
|----------|---------|-------------|
| `HF_CACHE_DIR` | `~/.cache/huggingface` | Host directory bind-mounted into the vLLM container as `/root/.cache/huggingface`. Model weights (~5 GB) are stored here so they survive container restarts. Must have ≥ 10 GB free space. |
| `HF_TOKEN` | *(empty)* | HuggingFace access token. Required only for gated/private model repositories. Generate one at <https://huggingface.co/settings/tokens>. |

#### OpenClaw — Container

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW_CONTAINER_NAME` | `democlaw-openclaw` | Name assigned to the OpenClaw container (`--name`). |
| `OPENCLAW_IMAGE_TAG` | `democlaw/openclaw:latest` | Local image tag built from `openclaw/Dockerfile`. |
| `OPENCLAW_PORT` | `18789` | Port the OpenClaw web server listens on **inside** the container. |
| `OPENCLAW_HOST_PORT` | `18789` | Port published on the **host** for browser access (`http://localhost:OPENCLAW_HOST_PORT`). |
| `OPENCLAW_HEALTH_TIMEOUT` | `120` | Seconds `start-openclaw.sh` waits for the dashboard to respond with HTTP 200. |

#### OpenClaw — LLM Provider Connection

These variables configure how OpenClaw connects to the vLLM backend. Three parallel naming conventions are supported for maximum compatibility with different OpenAI SDK versions.

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_BASE_URL` | `http://vllm:8000/v1` | Base URL of the vLLM OpenAI-compatible API. Uses the container hostname `vllm` which resolves inside the `democlaw-net` network. Change only if you rename the vLLM container or use a non-default port. |
| `VLLM_MODEL_NAME` | `Qwen/Qwen3-4B-AWQ` | Model ID that OpenClaw sends in API requests. Must exactly match `MODEL_NAME` as returned by `/v1/models`. |
| `VLLM_API_KEY` | `EMPTY` | Placeholder API key passed to OpenClaw. vLLM accepts any non-empty value in no-auth mode; set to your real secret if `VLLM_API_KEY` on the server side is a real key. |
| `VLLM_MAX_TOKENS` | `4096` | Maximum tokens per LLM response requested by OpenClaw. |
| `VLLM_TEMPERATURE` | `0.7` | Sampling temperature (0.0 = deterministic, 1.0+ = more random). |
| `VLLM_HEALTH_RETRIES` | `60` | Number of times OpenClaw retries the vLLM health probe at container startup before giving up. |
| `VLLM_HEALTH_INTERVAL` | `5` | Seconds between each vLLM health probe retry from inside the OpenClaw container. |

#### Healthcheck Scripts

| Variable | Default | Script | Description |
|----------|---------|--------|-------------|
| `HEALTHCHECK_CURL_TIMEOUT` | `10` | `scripts/healthcheck.sh` | Per-request curl timeout in seconds. |
| `OPENCLAW_HEALTH_RETRIES` | `10` | `scripts/healthcheck.sh` | Retry attempts for the OpenClaw dashboard check. |
| `OPENCLAW_HEALTH_INTERVAL` | `3` | `scripts/healthcheck.sh` | Seconds between OpenClaw dashboard retries. |
| `VLLM_HEALTH_CURL_TIMEOUT` | `10` | `scripts/healthcheck_vllm.sh` | Per-request curl timeout for the vLLM poller. |
| `OPENCLAW_HEALTH_TIMEOUT` | `120` | `scripts/healthcheck_openclaw.sh` | Total seconds to wait before giving up on the dashboard. |
| `OPENCLAW_HEALTH_CURL_TIMEOUT` | `5` | `scripts/healthcheck_openclaw.sh` | Per-request curl timeout for dashboard polling. |

#### API Validation Script

| Variable | Default | Description |
|----------|---------|-------------|
| `CURL_TIMEOUT` | `10` | Per-request curl timeout in `scripts/validate-api.sh`. |
| `INFERENCE_TIMEOUT` | `30` | Timeout for the `POST /v1/chat/completions` inference test. |
| `SKIP_INFERENCE_TEST` | `false` | Set to `true` to skip the inference test (e.g. in CI without a GPU). |

#### Connection Validation Script

| Variable | Default | Description |
|----------|---------|-------------|
| `VALIDATE_RETRIES` | `12` | Retry attempts when checking vLLM provider reachability. |
| `VALIDATE_INTERVAL` | `5` | Seconds between connection validation retries. |
| `VALIDATE_TIMEOUT` | `10` | Per-request curl timeout for connection validation. |

#### GPU Validation

| Variable | Default | Description |
|----------|---------|-------------|
| `MIN_VRAM_MIB` | `7500` | Minimum GPU VRAM in MiB required to start the stack (~7.5 GB). |
| `MIN_DRIVER_VERSION` | `520.0` | Minimum NVIDIA kernel driver version (needed for CUDA ≥ 11.8). |
| `MIN_CUDA_VERSION` | `11.8` | Minimum CUDA driver API version required by vLLM. |

#### Stop Script

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOVE_NETWORK` | `false` | Set to `true` to remove the `democlaw-net` container network when running `./scripts/stop.sh`. By default the network is kept so a subsequent `start.sh` run starts faster. |

---

### Docker와 Podman 전환 / Switching Between Docker and Podman

DemoClaw supports both Docker and Podman identically. The scripts auto-detect which runtime is available; you only need to intervene if both are installed or to lock the runtime permanently.

#### Auto-detection behaviour

When `CONTAINER_RUNTIME` is **not** set, every script checks in this order:

1. `docker` — if it is in `PATH`, Docker is used.
2. `podman` — if `docker` is absent and `podman` is in `PATH`, Podman is used.
3. Neither found → the script prints a clear error and exits immediately.

#### Using Docker

```bash
# Option 1 — let auto-detection pick Docker (Docker must be in PATH)
./scripts/start.sh

# Option 2 — force Docker explicitly for a single run
CONTAINER_RUNTIME=docker ./scripts/start.sh

# Option 3 — lock Docker permanently in .env
echo "CONTAINER_RUNTIME=docker" >> .env
./scripts/start.sh
```

#### Using Podman

```bash
# Option 1 — let auto-detection pick Podman (Docker must NOT be in PATH)
./scripts/start.sh

# Option 2 — force Podman explicitly for a single run
CONTAINER_RUNTIME=podman ./scripts/start.sh

# Option 3 — lock Podman permanently in .env
echo "CONTAINER_RUNTIME=podman" >> .env
./scripts/start.sh
```

> **Podman prerequisite:** Before running with Podman you must generate the CDI (Container Device Interface) spec so Podman can discover the NVIDIA GPU:
>
> ```bash
> sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
> nvidia-ctk cdi list   # confirm "nvidia.com/gpu=0" appears
> ```
>
> Docker uses `--gpus all`; Podman uses `--device nvidia.com/gpu=all`. The scripts apply the correct flag automatically based on the detected runtime.

#### Differences between Docker and Podman in DemoClaw

| Aspect | Docker | Podman |
|--------|--------|--------|
| GPU passthrough flag | `--gpus all` | `--device nvidia.com/gpu=all` |
| GPU setup requirement | `sudo nvidia-ctk runtime configure --runtime=docker` | `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` |
| Daemon required | Yes (`dockerd`) | No (daemonless) |
| Root required | Depends on configuration | Rootless by default |
| `HEALTHCHECK` status field | `.State.Health.Status` | `.State.Health.Status` (same) |
| Network creation command | `docker network create` | `podman network create` |
| Minimum version | ≥ 20.10 | ≥ 4.1 |

All shell scripts in `scripts/` handle these differences internally via the `scripts/lib/runtime.sh` library — the user-facing commands are identical regardless of which runtime is active.

#### Verifying the active runtime

```bash
# Which runtime is auto-detected?
make env-check

# Or inspect the runtime detection library directly
CONTAINER_RUNTIME=podman bash -c 'source scripts/lib/runtime.sh; echo "Runtime: $RUNTIME"'
CONTAINER_RUNTIME=docker bash -c 'source scripts/lib/runtime.sh; echo "Runtime: $RUNTIME"'
```

---

### `.env` 설정 예시 / Example `.env` Configurations

**Minimal — use all defaults (auto-detect Docker or Podman):**

```bash
# .env — empty file; all defaults apply
```

**Lock to Podman with conservative VRAM settings:**

```bash
CONTAINER_RUNTIME=podman
MAX_MODEL_LEN=16384
GPU_MEMORY_UTILIZATION=0.85
```

**Resolve port conflicts (both ports already in use):**

```bash
VLLM_HOST_PORT=8001
OPENCLAW_HOST_PORT=18790
```

**Private HuggingFace model with custom cache directory:**

```bash
HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
HF_CACHE_DIR=/data/hf-cache
MODEL_NAME=my-org/my-private-awq-model
```

**Enable API key authentication on the vLLM endpoint:**

```bash
VLLM_API_KEY=my-very-secret-key
```

> When `VLLM_API_KEY` is set, all API clients (including OpenClaw) must include `Authorization: Bearer my-very-secret-key` in their requests. The scripts pass this key through to the OpenClaw container automatically via `VLLM_API_KEY`.

See [`.env.example`](.env.example) for the complete annotated template with every available variable.

## 아키텍처 / Architecture

아래 다이어그램은 DemoClaw의 전체 구조를 보여줍니다.

```
┌──────────────────────────────────────────────────────┐
│  Linux Host                                          │
│                                                      │
│  ┌────────────────┐       ┌────────────────────────┐ │
│  │  vLLM Server   │       │  OpenClaw              │ │
│  │                │       │                        │ │
│  │  Qwen3-4B    │◄──────│  Web Dashboard         │ │
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

### 컨테이너 상세 / Container details

**vLLM container** (`democlaw-vllm`):
- Base image: `vllm/vllm-openai:v0.8.3`
- Serves the Qwen3-4B AWQ 4-bit model
- OpenAI-compatible API at `/v1/chat/completions`, `/v1/models`, etc.
- GPU passthrough via `--gpus all` (Docker) or CDI (Podman)
- Built-in healthcheck on `/health` and `/v1/models`

**OpenClaw container** (`democlaw-openclaw`):
- Base image: Ubuntu 24.04 with Node.js 20
- Runs as non-root user
- Read-only filesystem (tmpfs for writable dirs)
- Connects to vLLM via the `democlaw-net` container network
- Waits for vLLM readiness before starting

### 보안 / Security

Both containers follow a minimal-privilege model:
- `--cap-drop ALL` — no Linux capabilities
- `--security-opt no-new-privileges` — prevents privilege escalation
- OpenClaw runs as non-root with `--read-only` filesystem
- No unnecessary host mounts (only HuggingFace cache for vLLM)

## 멱등성 실행 / Idempotent Execution

스크립트는 여러 번 실행해도 안전합니다:
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

## 문제 해결 / Troubleshooting

아래 체크리스트를 사용하여 가장 흔한 문제를 진단하세요.

Use the checklist below to diagnose the most common problems. For each issue, the error message shown is the exact text you will see in terminal output or in container logs.

### 두 서비스 빠른 상태 확인 / Quick-verify both services are healthy

Before investigating individual problems, run the full stack healthcheck to get an instant summary:

```bash
# Full stack — runtime, network, containers, API endpoints
./scripts/healthcheck.sh

# Machine-readable JSON (useful for scripting)
./scripts/healthcheck.sh --json

# vLLM only (fastest — useful while the model is still loading)
./scripts/healthcheck.sh --vllm-only
```

#### Verify the vLLM server is healthy

The vLLM server exposes three endpoints you can probe directly:

```bash
# 1. Liveness probe — expects HTTP 200 with an empty body
curl -sf http://localhost:8000/health && echo "vLLM OK"

# 2. List loaded models — confirm Qwen/Qwen3-4B-AWQ appears
curl -s http://localhost:8000/v1/models | python3 -m json.tool

# 3. End-to-end inference smoke test
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-4B-AWQ","messages":[{"role":"user","content":"Hi"}],"max_tokens":16}' \
  | python3 -m json.tool

# 4. Check the in-container HEALTHCHECK status
docker inspect --format '{{.State.Health.Status}}' democlaw-vllm
# podman inspect --format '{{.State.Health.Status}}' democlaw-vllm

# 5. Stream the vLLM logs
make logs-vllm
# docker logs -f democlaw-vllm
# podman logs -f democlaw-vllm
```

The server is fully ready when:
- `curl .../health` returns `HTTP 200`
- `/v1/models` lists `Qwen/Qwen3-4B-AWQ`
- The container logs contain `INFO: Application startup complete.`

#### Verify the OpenClaw dashboard is healthy

```bash
# 1. HTTP probe — expects HTTP 200 with HTML content
curl -sf http://localhost:18789 | head -5

# 2. In-container HEALTHCHECK status
docker inspect --format '{{.State.Health.Status}}' democlaw-openclaw
# podman inspect --format '{{.State.Health.Status}}' democlaw-openclaw

# 3. Stream the OpenClaw logs
make logs-openclaw
# docker logs -f democlaw-openclaw
# podman logs -f democlaw-openclaw
```

The dashboard is ready when `curl http://localhost:18789` returns `HTTP 200` and the page contains HTML content.

---

### GPU / 드라이버 오류 / GPU / driver errors

#### `ERROR: nvidia-smi not found in PATH`

The NVIDIA driver is not installed or not on `PATH`.

```bash
# Install on Ubuntu/Debian
sudo ubuntu-drivers autoinstall   # recommended
# or a specific version
sudo apt install nvidia-driver-560

# Install on Fedora/RHEL
sudo dnf install akmod-nvidia

# Reboot after installing the driver
sudo reboot

# Verify
nvidia-smi
```

See the [Prerequisites — Installing the NVIDIA Driver](#installing-the-nvidia-driver) section for full instructions.

#### `ERROR: No NVIDIA GPU devices detected`

The driver is installed but the GPU is not visible (driver not loaded after install, or GPU absent).

```bash
# Check whether the GPU is visible to the kernel
lspci | grep -i nvidia

# Check whether the NVIDIA kernel module is loaded
lsmod | grep nvidia

# If the module is missing, reload it (or reboot)
sudo modprobe nvidia
```

If `lspci` shows no NVIDIA device, the GPU may be physically absent, disabled in BIOS/UEFI, or not supported by the installed driver.

#### `ERROR: CUDA version X.Y is below minimum 11.8`

The installed NVIDIA driver is too old. The CUDA version reported by `nvidia-smi` is determined by your driver version.

```bash
# Check current driver and CUDA version
nvidia-smi

# Upgrade to a newer driver (Ubuntu)
sudo apt install nvidia-driver-560   # driver 560 → CUDA 12.4
sudo reboot
```

Driver ≥ 520 reports CUDA ≥ 11.8. Driver ≥ 535 reports CUDA ≥ 12.2.

#### `ERROR: Insufficient GPU VRAM: 6144 MiB detected, but 7500 MiB required`

The Qwen3-4B AWQ 4-bit model needs ~5–6 GB VRAM for weights plus overhead. A GPU with < 8 GB VRAM will likely fail.

Options:
1. **Use a GPU with ≥ 8 GB VRAM** — RTX 3070, RTX 3080, RTX 4060 Ti, RTX 4080, A10, L40S, etc.
2. **Reduce context length** — in `.env`, set `MAX_MODEL_LEN=16384` to cut VRAM overhead.
3. **Lower GPU memory utilisation** — set `GPU_MEMORY_UTILIZATION=0.85` in `.env`.
4. **Use a smaller model** — change `MODEL_NAME` to a 7B AWQ or 4B model.

```bash
# .env example for tight VRAM budgets
MAX_MODEL_LEN=16384
GPU_MEMORY_UTILIZATION=0.85
```

#### vLLM exits with `CUDA out of memory` during inference

The model loaded but a long prompt exceeded available VRAM during generation.

```bash
# Reduce context length and VRAM fraction
MAX_MODEL_LEN=16384
GPU_MEMORY_UTILIZATION=0.80
```

---

### 컨테이너 툴킷 오류 / Container toolkit errors

#### `ERROR: nvidia-container-toolkit not configured for docker`

The toolkit is not installed or not configured for Docker.

```bash
# Install the toolkit
sudo apt-get install -y nvidia-container-toolkit   # Ubuntu/Debian
# sudo dnf install -y nvidia-container-toolkit     # Fedora/RHEL

# Configure Docker and restart
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify
docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
```

#### `ERROR: nvidia-container-toolkit not configured for podman` / Podman: `no GPU device found`

The CDI spec for Podman is missing or stale.

```bash
# Generate (or regenerate) the CDI spec
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Confirm the GPU device entry exists
nvidia-ctk cdi list
# Should show: nvidia.com/gpu=0  (and nvidia.com/gpu=all)

# Verify Podman can see the GPU
podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
```

Run `sudo nvidia-ctk cdi generate ...` again whenever you update the NVIDIA driver.

#### `--gpus` flag not recognised (old Docker)

Docker versions older than 20.10 do not support `--gpus`. Upgrade Docker:

```bash
# Remove old Docker packages
sudo apt-get remove docker docker-engine docker.io containerd runc

# Install current Docker Engine
# Full guide: https://docs.docker.com/engine/install/

# Verify version (must be ≥ 20.10)
docker --version
```

---

### 컨테이너 런타임 오류 / Container runtime errors

#### `ERROR: No container runtime found. Install docker or podman.`

Neither `docker` nor `podman` is in `PATH`.

```bash
# Install Docker — https://docs.docker.com/engine/install/
# Install Podman — https://podman.io/docs/installation

# Force a specific runtime once installed
CONTAINER_RUNTIME=docker ./scripts/start.sh
CONTAINER_RUNTIME=podman ./scripts/start.sh
```

#### Docker daemon is not running

```bash
# Start the Docker daemon
sudo systemctl start docker
sudo systemctl enable docker   # auto-start on boot

# Verify
docker info
```

#### Permission denied when running Docker as a non-root user

```bash
# Add your user to the docker group
sudo usermod -aG docker "$USER"

# Apply the new group membership (log out/in, or use newgrp)
newgrp docker

# Verify
docker ps
```

---

### 네트워크 오류 / Network errors

#### Container network `democlaw-net` already exists but is broken

If a previous run left behind a stale network, remove it and let the scripts recreate it:

```bash
# Stop all DemoClaw containers first
./scripts/stop.sh

# Remove the network
docker network rm democlaw-net   # Docker
# podman network rm democlaw-net  # Podman

# Restart — the network will be recreated automatically
./scripts/start.sh
```

#### Port 8000 or 18789 already in use

```
Error response from daemon: Ports are not available: exposing port TCP 0.0.0.0:8000 -> ...
```

Another process is using the port. Either stop that process or change the ports in `.env`:

```bash
# Find what is using the port
sudo ss -tlnp | grep ':8000'
sudo ss -tlnp | grep ':18789'

# Or change the ports in .env
VLLM_HOST_PORT=8001
OPENCLAW_HOST_PORT=18790
```

---

### 모델 다운로드 / 시작 오류 / Model download / startup errors

#### vLLM takes a very long time to start (first run)

On first launch, vLLM downloads ~5 GB of model weights from HuggingFace. This is expected and takes several minutes on a typical connection. Monitor progress:

```bash
make logs-vllm
# or
docker logs -f democlaw-vllm
# or
podman logs -f democlaw-vllm
```

The server is ready when the log shows `INFO: Application startup complete.`

Subsequent runs skip the download because the weights are cached in `HF_CACHE_DIR` (default: `~/.cache/huggingface`).

#### HuggingFace download fails (rate-limit, timeout, or auth error)

```bash
# Check network access to HuggingFace
curl -I https://huggingface.co

# For gated models, set your HuggingFace token in .env
HF_TOKEN=hf_your_token_here
```

If you are behind a corporate proxy, set the `HTTP_PROXY` / `HTTPS_PROXY` environment variables in `.env`.

#### Permission denied on `HF_CACHE_DIR`

```bash
# Check permissions
ls -la ~/.cache/huggingface

# Fix ownership
sudo chown -R "$USER":"$USER" ~/.cache/huggingface

# Or point to a different cache directory in .env
HF_CACHE_DIR=/data/hf-cache
```

---

### OpenClaw 오류 / OpenClaw errors

#### OpenClaw says "waiting for vLLM" / times out

OpenClaw polls the vLLM `/health` endpoint before starting its web server. If vLLM is still loading the model, OpenClaw will keep retrying until `OPENCLAW_HEALTH_TIMEOUT` (default: 120 s) expires.

```bash
# Check vLLM health — wait until this passes
./scripts/healthcheck.sh --vllm-only

# Or watch vLLM logs until "Application startup complete."
make logs-vllm

# Increase the timeout if your machine is slow to load the model
OPENCLAW_HEALTH_TIMEOUT=300 ./scripts/start-openclaw.sh
```

#### OpenClaw dashboard loads but shows no model / "no provider configured"

The `VLLM_BASE_URL` setting in OpenClaw's config is wrong or the vLLM container is unreachable.

```bash
# Check OpenClaw logs for connection errors
make logs-openclaw

# Verify the vLLM URL from inside the OpenClaw container
docker exec democlaw-openclaw curl -sf http://vllm:8000/health && echo "vLLM reachable"

# Default URL (container-to-container, via democlaw-net)
VLLM_BASE_URL=http://vllm:8000/v1
```

#### OpenClaw container exits immediately after starting

```bash
# View the last 50 lines of logs
docker logs --tail 50 democlaw-openclaw

# Common causes:
# - Node.js version mismatch — rebuild the image: make build-openclaw
# - Bad config.json syntax — check openclaw/config.json
# - VLLM_BASE_URL unreachable at startup
```

---

### 일반 디버깅 / General debugging

#### Check both container states at a glance

```bash
# Docker
docker ps --filter "name=democlaw" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Podman
podman ps --filter "name=democlaw" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

#### Watch container health status in a loop

```bash
watch -n 5 'docker inspect --format "{{.Name}}: {{.State.Health.Status}}" democlaw-vllm democlaw-openclaw'
```

#### Run the GPU preflight check standalone

```bash
./scripts/check-gpu.sh
# or
make env-check
```

#### Full reset — stop everything and start fresh

```bash
make clean    # stops containers, removes images and network
make start    # rebuilds images and starts fresh
```

## 프로젝트 구조 / Project Structure

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

## 소형 모델 친화 스킬 / Small-Model-Friendly Skills

DemoClaw는 소형 AI 모델(Qwen3-4B-AWQ)을 사용합니다. 이 크기의 모델은 여러 단계를 거쳐야 하는 복잡한 작업에서 자주 실패합니다. **[openclaw-simple-skills](https://github.com/JinwangMok/openclaw-simple-skills)**는 이런 소형 모델에서도 **한 번의 명령으로 안정적으로 실행**되도록 설계된 스킬 모음입니다.

DemoClaw uses a small AI model (Qwen3-4B-AWQ). Models this size often fail on complex multi-step tasks. **[openclaw-simple-skills](https://github.com/JinwangMok/openclaw-simple-skills)** is a skill collection designed to run reliably in **a single command** on these small models.

### 사용 가능한 스킬 / Available Skills

| 스킬 | 하는 일 | Skill | Description |
|------|---------|-------|-------------|
| **word-count** | 파일의 줄 수, 단어 수, 글자 수를 셉니다 | **word-count** | Count lines, words, and characters |
| **disk-usage** | 폴더가 차지하는 용량을 보여줍니다 | **disk-usage** | Show folder disk space usage |
| **text-search** | 파일들 안에서 특정 단어를 찾습니다 | **text-search** | Find a word in files |
| **simple-file-backup** | 파일을 날짜 붙여서 백업합니다 | **simple-file-backup** | Create a dated backup copy |
| **simple-file-tree** | 폴더 안의 파일 목록을 트리로 보여줍니다 | **simple-file-tree** | Show folder contents as a tree |

### 왜 이 스킬이 특별한가요? / Why Are These Skills Special?

소형 AI 모델이 실수 없이 실행할 수 있도록, 엄격한 설계 규칙을 따릅니다:

These skills follow strict design rules so small AI models can run them without mistakes:

| 규칙 / Rule | 설명 / Description |
|-------------|---------------------|
| 한 번에 끝남 | 하나의 명령으로 완료됩니다. 여러 단계를 거치지 않습니다 / Completes in one command, no chaining |
| 입력값 2개 이하 | 복잡한 옵션이 없습니다. 최대 2개만 입력하면 됩니다 / Max 2 inputs, no complex options |
| 인터넷 불필요 | 네트워크 연결이나 API 키 없이 작동합니다 / Works without internet or API keys |
| 결과가 항상 동일 | 같은 입력이면 같은 결과가 나옵니다 / Same input always gives same output |
| 기본 도구만 사용 | Linux에 기본 설치된 `wc`, `du`, `grep`, `cp`, `find`만 사용합니다 / Uses only standard Linux tools |

---

### 사용 방법 A: OpenClaw 웹 대시보드에서 대화로 사용하기

**가장 쉬운 방법입니다.** DemoClaw를 실행한 후 브라우저에서 AI에게 말로 요청하면 됩니다.

This is the **easiest method**. After starting DemoClaw, just ask the AI in your browser.

#### 1단계: 컨테이너 안에 스킬 설치하기 (최초 1회)

DemoClaw를 시작한 뒤, 터미널에서 아래 명령을 실행하세요. 이 명령은 OpenClaw 컨테이너 안에 스킬 파일들을 다운로드합니다.

After starting DemoClaw, run this in your terminal. It downloads the skill files into the OpenClaw container.

```bash
# Docker를 사용하는 경우 / If using Docker:
docker exec democlaw-openclaw bash -c \
  "cd /home/openclaw && git clone https://github.com/JinwangMok/openclaw-simple-skills.git"

# Podman을 사용하는 경우 / If using Podman:
podman exec democlaw-openclaw bash -c \
  "cd /home/openclaw && git clone https://github.com/JinwangMok/openclaw-simple-skills.git"
```

> **참고**: `git`이 컨테이너에 없다면, 아래와 같이 설치할 수 있습니다:
> ```bash
> docker exec -u root democlaw-openclaw apt-get update
> docker exec -u root democlaw-openclaw apt-get install -y git
> ```

#### 2단계: 브라우저에서 AI에게 요청하기

**http://localhost:18789** 을 열고, 채팅창에 아래처럼 입력하세요:

Open **http://localhost:18789** and type in the chat:

| 이렇게 입력하세요 / Type this | 하는 일 / What it does |
|------------------------------|----------------------|
| `bash /home/openclaw/openclaw-simple-skills/word-count/run.sh /app/config/config.json` | config.json 파일의 줄 수/단어 수/글자 수를 셉니다 |
| `bash /home/openclaw/openclaw-simple-skills/disk-usage/run.sh /home/openclaw` | 홈 디렉토리의 용량을 보여줍니다 |
| `bash /home/openclaw/openclaw-simple-skills/text-search/run.sh "vllm" /app` | /app 폴더에서 "vllm"이라는 단어를 찾습니다 |
| `bash /home/openclaw/openclaw-simple-skills/file-backup/run.sh /app/config/config.json` | config.json을 날짜 붙여서 백업합니다 |
| `bash /home/openclaw/openclaw-simple-skills/file-tree/run.sh /app 2` | /app 폴더의 구조를 2단계 깊이까지 보여줍니다 |

> **팁**: 자연어로도 요청할 수 있습니다. 예: *"config.json 파일이 몇 줄인지 세줘"* — 하지만 소형 모델에서는 정확한 명령어를 직접 입력하는 것이 더 확실합니다.
>
> **Tip**: You can also ask in natural language (e.g., *"Count lines in config.json"*), but with small models, typing the exact command is more reliable.

---

### 사용 방법 B: 컨테이너 터미널에서 직접 실행하기

컨테이너 안에 들어가서 직접 스킬을 실행하는 방법입니다. 터미널 사용에 익숙하다면 이 방법이 더 자유롭습니다.

Enter the container and run skills directly. If you're comfortable with the terminal, this gives you more control.

#### 1단계: 컨테이너에 접속하기

```bash
# Docker
docker exec -it democlaw-openclaw bash

# Podman
podman exec -it democlaw-openclaw bash
```

이제 컨테이너 안에 들어왔습니다. 프롬프트가 `openclaw@...:` 로 바뀐 것을 확인하세요.

You are now inside the container. You should see the prompt change to `openclaw@...:`.

#### 2단계: 스킬 다운로드하기 (최초 1회)

```bash
cd ~
git clone https://github.com/JinwangMok/openclaw-simple-skills.git
cd openclaw-simple-skills
```

#### 3단계: 스킬 실행해보기

```bash
# 이 파일이 몇 줄, 몇 단어인지 세기
bash word-count/run.sh README.md

# 현재 디렉토리의 용량 확인
bash disk-usage/run.sh .

# "skill"이라는 단어가 어디에 있는지 찾기
bash text-search/run.sh "skill" .

# README.md를 날짜 붙여서 백업하기
bash file-backup/run.sh README.md

# 폴더 구조를 트리로 보기
bash file-tree/run.sh . 2
```

#### 4단계: 파일 편집이 필요할 때 (선택사항)

컨테이너 안에서 파일을 만들거나 수정하고 싶다면, 기본 편집기를 설치하세요:

If you want to create or edit files inside the container:

```bash
# 컨테이너 밖에서 (다른 터미널에서) 실행하세요:
# Run this OUTSIDE the container (in another terminal):
docker exec -u root democlaw-openclaw apt-get update
docker exec -u root democlaw-openclaw apt-get install -y vim

# 다시 컨테이너 안에서 파일 편집:
# Then inside the container:
vim my_notes.txt
```

#### 나올 때 / To exit

```bash
exit
```

---

### ClawHub에서 설치하기 / Install from ClawHub

OpenClaw의 스킬 마켓플레이스인 ClawHub에서도 설치할 수 있습니다:

You can also install from ClawHub, OpenClaw's skill marketplace:

```bash
clawhub install word-count
clawhub install disk-usage
clawhub install text-search
clawhub install simple-file-backup
clawhub install simple-file-tree
```

> 각 스킬의 상세한 사용법과 한글/영어 매뉴얼은 [openclaw-simple-skills](https://github.com/JinwangMok/openclaw-simple-skills) 저장소의 각 스킬 폴더 안 `MANUAL.md`를 참고하세요.
>
> For detailed usage and bilingual manuals, see each skill's `MANUAL.md` in the [openclaw-simple-skills](https://github.com/JinwangMok/openclaw-simple-skills) repository.

## 참고 자료 / References

### 업스트림 프로젝트 / Upstream projects

| Project | Description | Links |
|---------|-------------|-------|
| **vLLM** | High-throughput LLM inference engine with OpenAI-compatible API | [GitHub](https://github.com/vllm-project/vllm) · [Docs](https://docs.vllm.ai) · [Docker Hub](https://hub.docker.com/r/vllm/vllm-openai) |
| **Qwen3-4B-AWQ** | Alibaba's Qwen 2.5 series 7B model, AWQ 4-bit quantised for 8 GB VRAM | [HuggingFace](https://huggingface.co/Qwen/Qwen3-4B-AWQ) · [Qwen GitHub](https://github.com/QwenLM/Qwen3) · [Model card](https://huggingface.co/Qwen/Qwen3-4B-AWQ) |
| **OpenClaw** | Open-source AI assistant web dashboard | [GitHub](https://github.com/openclaw/openclaw) |
| **NVIDIA Container Toolkit** | GPU passthrough for Docker and Podman | [GitHub](https://github.com/NVIDIA/nvidia-container-toolkit) · [Install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) |
| **NVIDIA CDI** | Container Device Interface spec for Podman GPU passthrough | [CDI spec](https://github.com/cncf-tags/container-device-interface) · [nvidia-ctk cdi docs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html) |

### vLLM

[vLLM](https://github.com/vllm-project/vllm) is a fast, memory-efficient LLM serving library developed at UC Berkeley. It uses PagedAttention to achieve high throughput inference and exposes a fully OpenAI-compatible REST API, allowing any OpenAI SDK client to work with locally-hosted models without code changes. The official container image `vllm/vllm-openai` bundles the complete CUDA runtime, so no host-side CUDA Toolkit installation is required.

- Documentation: <https://docs.vllm.ai>
- GitHub: <https://github.com/vllm-project/vllm>
- Docker Hub: <https://hub.docker.com/r/vllm/vllm-openai>
- Supported models list: <https://docs.vllm.ai/en/latest/models/supported_models.html>

### Qwen / Qwen3-4B-AWQ

[Qwen](https://github.com/QwenLM/Qwen3) is Alibaba Cloud's open-source large language model family. The **Qwen3-4B-AWQ** variant is a 4-billion-parameter model quantised to 4-bit using the [AWQ (Activation-aware Weight Quantization)](https://arxiv.org/abs/2306.00978) method, reducing the on-GPU memory footprint from ~14 GB (fp16) to ~5 GB while preserving most of the model quality.

- Model card: <https://huggingface.co/Qwen/Qwen3-4B-AWQ>
- Qwen GitHub: <https://github.com/QwenLM/Qwen3>
- Qwen Blog: <https://qwenlm.github.io>
- AWQ paper: <https://arxiv.org/abs/2306.00978>

### OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) is an open-source AI assistant web application. It provides a browser-based chat interface that connects to any OpenAI-compatible API endpoint, making it a natural fit for self-hosted vLLM backends.

- GitHub: <https://github.com/openclaw/openclaw>

### NVIDIA Container Toolkit

The [NVIDIA Container Toolkit](https://github.com/NVIDIA/nvidia-container-toolkit) enables GPU passthrough from the host into Docker and Podman containers. For Docker it configures a custom runtime via `nvidia-ctk runtime configure`; for Podman it generates a CDI (Container Device Interface) spec at `/etc/cdi/nvidia.yaml`.

- Install guide: <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html>
- GitHub: <https://github.com/NVIDIA/nvidia-container-toolkit>
- CDI support guide: <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html>

### 추가 읽을거리 / Further reading

- [OpenAI API Reference](https://platform.openai.com/docs/api-reference) — the API contract that vLLM's `/v1/` endpoints implement
- [AWQ: Activation-aware Weight Quantization](https://arxiv.org/abs/2306.00978) — the quantisation technique used by `Qwen3-4B-AWQ`
- [PagedAttention paper](https://arxiv.org/abs/2309.06180) — the memory-management technique behind vLLM's efficiency
- [HuggingFace model hub](https://huggingface.co/models?pipeline_tag=text-generation&sort=downloads) — browse other AWQ-quantised models compatible with vLLM

## Windows 빠른 시작 / Windows Quick Start

DemoClaw supports Windows via **Docker Desktop** (WSL2 backend). PowerShell and batch scripts are provided.

### 사전 요구사항 (Windows) / Prerequisites (Windows)

| Requirement | Details |
|-------------|---------|
| **Docker Desktop** | [Install](https://docs.docker.com/desktop/install/windows-install/) with WSL2 backend enabled |
| **NVIDIA GPU** | 8 GB+ VRAM with latest [Game Ready / Studio driver](https://www.nvidia.com/Download/index.aspx) |
| **Git** | [Git for Windows](https://git-scm.com/download/win) |

### Launch (Windows)

```powershell
# Clone
git clone https://github.com/JinwangMok/democlaw.git
cd democlaw

# Option A: PowerShell
.\scripts\start.ps1

# Option B: Batch (double-click or from CMD)
.\scripts\start.bat
```

The scripts mirror the Linux `start.sh` behavior: pull images from Docker Hub (fallback to local build), destroy/recreate containers, health-check both services, then print the dashboard URL.

---

## 모델 사전 다운로드 / Pre-download Models

To avoid waiting for model download during container startup, pre-download model weights with the provided scripts. The vLLM container mounts the local cache, so downloads only happen once.

### Linux / macOS

```bash
# Default model (Qwen/Qwen3-4B-AWQ)
./scripts/download-models.sh

# Custom model
./scripts/download-models.sh "Qwen/Qwen2.5-7B-Instruct-AWQ"

# With HuggingFace token (for gated models)
HF_TOKEN=hf_xxx ./scripts/download-models.sh
```

### Windows

```powershell
# PowerShell
.\scripts\download-models.ps1

# With custom model
.\scripts\download-models.ps1 -ModelName "Qwen/Qwen2.5-7B-Instruct-AWQ"

# Batch (double-click or from CMD)
.\scripts\download-models.bat
```

The scripts download model weights to `~/.cache/huggingface` (Linux) or `%USERPROFILE%\.cache\huggingface` (Windows) and verify SHA256 checksums. On subsequent runs, existing files are verified and skipped if intact.

---

## 커스텀 스킬 / Custom Skills

OpenClaw supports **custom skills** — Python scripts that extend the AI agent's capabilities. Skills let the agent call your code to perform tasks like querying databases, calling external APIs, processing files, or running computations.

This section is a complete user guide covering skill structure, a working example, the bundled template, step-by-step creation instructions, and testing.

### 스킬 구조 / Skill Structure

Every skill lives in its own directory and contains exactly two files:

```
my_skill/
├── skill.yaml      # Skill manifest — name, description, version, I/O schema
└── my_script.py    # Python entry point — reads JSON stdin, writes JSON stdout
```

| File | Purpose |
|------|---------|
| `skill.yaml` | Declares the skill's metadata and its input/output JSON schemas. OpenClaw reads this file to understand what the skill expects and returns. |
| `*.py` (entry point) | The Python script that OpenClaw executes. It receives input as a JSON object on `stdin` and must print a JSON result to `stdout`. |

### 스킬 입출력 프로토콜 / Skill I/O Protocol

All skills follow a simple JSON-in / JSON-out protocol:

```
┌──────────┐   JSON stdin    ┌────────────┐   JSON stdout   ┌──────────┐
│ OpenClaw │ ───────────────> │ skill.py   │ ───────────────> │ OpenClaw │
│  agent   │                 │ (your code)│                  │  agent   │
└──────────┘                 └────────────┘                  └──────────┘
```

- **Input**: OpenClaw passes a JSON object matching `input_schema` via `stdin`.
- **Output**: The skill prints a JSON object matching `output_schema` to `stdout`.
- **Errors**: On failure, write `{"status": "error", "error": "message"}` to `stderr` and exit with code `1`.

### Example: Hello World Skill

A minimal working skill is bundled at `examples/skills/hello_world/`:

**`examples/skills/hello_world/skill.yaml`**:

```yaml
name: hello_world
description: "A simple greeting skill that demonstrates custom skill creation"
version: "1.0.0"
author: "DemoClaw"
entry_point: hello.py
input_schema:
  type: object
  properties:
    name:
      type: string
      description: "Name to greet"
      default: "World"
output_schema:
  type: object
  properties:
    message:
      type: string
      description: "Greeting message"
```

**`examples/skills/hello_world/hello.py`**:

```python
#!/usr/bin/env python3
"""Hello World custom skill for OpenClaw."""
import sys
import json

def main():
    input_data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}
    name = input_data.get("name", "World")
    result = {"message": f"Hello, {name}! This is a custom OpenClaw skill."}
    print(json.dumps(result))

if __name__ == "__main__":
    main()
```

**Test it standalone** (no OpenClaw needed):

```bash
# Default input (no name)
echo '{}' | python examples/skills/hello_world/hello.py
# → {"message": "Hello, World! This is a custom OpenClaw skill."}

# Custom input
echo '{"name": "Alice"}' | python examples/skills/hello_world/hello.py
# → {"message": "Hello, Alice! This is a custom OpenClaw skill."}
```

### Skill Template

A ready-to-copy template is provided at `examples/skills/template/`. It includes error handling, logging, and a clear `run()` function to fill in.

**`examples/skills/template/skill.yaml`**:

```yaml
name: my_custom_skill
description: "Describe what your skill does"
version: "1.0.0"
author: "Your Name"
entry_point: skill_template.py
input_schema:
  type: object
  properties:
    param1:
      type: string
      description: "Description of parameter"
output_schema:
  type: object
  properties:
    status:
      type: string
    result:
      type: string
```

**`examples/skills/template/skill_template.py`**:

```python
#!/usr/bin/env python3
"""
Custom Skill Template for OpenClaw
===================================
Copy this directory and modify to create your own skill.

Input: JSON from stdin
Output: JSON to stdout
"""
import sys
import json
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def run(input_data: dict) -> dict:
    """Main skill logic. Modify this function.

    Args:
        input_data: Input parameters from OpenClaw
    Returns:
        dict: Result to return to OpenClaw
    """
    # TODO: Implement your skill logic here
    return {"status": "success", "result": "Replace this with your skill output"}

def main():
    try:
        input_data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}
        result = run(input_data)
        print(json.dumps(result))
    except Exception as e:
        error = {"status": "error", "error": str(e)}
        print(json.dumps(error), file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
```

### Creating Your Own Skill — Step by Step

#### Step 1 — Copy the template

```bash
# Create a skills directory and copy the template
mkdir -p my_skills
cp -r examples/skills/template my_skills/weather_lookup
```

#### Step 2 — Edit `skill.yaml`

Rename and describe your skill, define the input parameters it accepts, and the output it returns:

```yaml
# my_skills/weather_lookup/skill.yaml
name: weather_lookup
description: "Look up current weather for a given city"
version: "1.0.0"
author: "Your Name"
entry_point: weather.py
input_schema:
  type: object
  properties:
    city:
      type: string
      description: "City name (e.g. Seoul, New York)"
  required:
    - city
output_schema:
  type: object
  properties:
    status:
      type: string
    city:
      type: string
    temperature:
      type: string
    condition:
      type: string
```

#### Step 3 — Implement the entry point

Rename `skill_template.py` to match `entry_point` in your YAML, then implement the `run()` function:

```python
#!/usr/bin/env python3
# my_skills/weather_lookup/weather.py
"""Weather lookup skill for OpenClaw."""
import sys
import json
import urllib.request
import urllib.error

def run(input_data: dict) -> dict:
    city = input_data.get("city", "")
    if not city:
        return {"status": "error", "error": "city parameter is required"}

    try:
        url = f"https://wttr.in/{city}?format=j1"
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
        current = data["current_condition"][0]
        return {
            "status": "success",
            "city": city,
            "temperature": f"{current['temp_C']}°C / {current['temp_F']}°F",
            "condition": current["weatherDesc"][0]["value"],
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}

def main():
    try:
        input_data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}
        result = run(input_data)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}), file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
```

#### Step 4 — Test standalone

Always test your skill outside OpenClaw first:

```bash
# Test with valid input
echo '{"city": "Seoul"}' | python my_skills/weather_lookup/weather.py
# → {"status": "success", "city": "Seoul", "temperature": "18°C / 64°F", "condition": "Partly cloudy"}

# Test with missing input
echo '{}' | python my_skills/weather_lookup/weather.py
# → {"status": "error", "error": "city parameter is required"}

# Test with pipe from curl (simulates OpenClaw invocation)
echo '{"city": "London"}' | python my_skills/weather_lookup/weather.py | python -m json.tool
```

#### Step 5 — Mount into OpenClaw container

To make your skill available to the running OpenClaw agent, mount your skills directory into the container. Add the volume mount to your `.env` or pass it directly:

```bash
# Option A — Set the skills path in .env
echo 'OPENCLAW_SKILLS_DIR=./my_skills' >> .env
./scripts/start.sh

# Option B — Mount manually when running the container
docker run -v "$(pwd)/my_skills:/app/skills:ro" democlaw/openclaw:latest
```

After mounting, restart OpenClaw (`./scripts/start.sh` handles this automatically) for the agent to discover the new skill.

### Skill Manifest Reference (`skill.yaml`)

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique skill identifier (lowercase, underscores allowed) |
| `description` | Yes | Human-readable description shown to the AI agent |
| `version` | Yes | Semantic version string (e.g. `"1.0.0"`) |
| `author` | No | Author name or organization |
| `entry_point` | Yes | Python filename to execute (relative to skill directory) |
| `input_schema` | Yes | JSON Schema defining accepted input parameters |
| `output_schema` | Yes | JSON Schema defining the returned result structure |

### Skill Development Tips

- **Input**: Always read JSON from `sys.stdin` — OpenClaw passes input as a single JSON object
- **Output**: Always write JSON to `sys.stdout` — OpenClaw parses the result as JSON
- **Errors**: Write error JSON to `sys.stderr` and exit with code `1`; OpenClaw will report the error to the user
- **Dependencies**: Keep skills self-contained where possible. If you need third-party packages, include a `requirements.txt` in the skill directory
- **Testing**: Always test standalone before mounting: `echo '{"key":"value"}' | python your_skill.py`
- **Idempotency**: Skills may be called multiple times with the same input — ensure your logic is safe to repeat
- **Timeouts**: Long-running skills should handle timeouts gracefully; OpenClaw enforces a per-skill execution timeout
- **No side-channel output**: Do not print non-JSON text to `stdout` — it will break parsing. Use `logging` (writes to `stderr`) for debug messages

---

## ClawHub — 스킬 마켓플레이스 / ClawHub — Skill Marketplace

[ClawHub](https://clawhub.com) is the community marketplace for OpenClaw skills. You can browse, download, and publish reusable skills created by the community.

### Installing ClawHub CLI

```bash
# Install via npm (requires Node.js ≥ 18)
npm install -g clawhub

# Verify installation
clawhub --version
```

### Downloading Skills from ClawHub

```bash
# Search for skills by keyword
clawhub search "weather"
clawhub search "database"
clawhub search "summarize"

# Download and install a skill into your skills directory
clawhub install weather-lookup
clawhub install text-summarizer

# Install a specific version
clawhub install weather-lookup@1.2.0

# List all installed skills
clawhub list

# Update all installed skills to their latest versions
clawhub update

# Update a specific skill
clawhub update weather-lookup

# Remove an installed skill
clawhub uninstall weather-lookup
```

Installed skills are placed in the `~/.openclaw/skills/` directory by default. To use a different directory:

```bash
# Set a custom skills directory
clawhub config set skills_dir ./my_skills

# Or specify per-command
clawhub install weather-lookup --dir ./my_skills
```

### Publishing Skills to ClawHub

Share your custom skills with the community:

```bash
# Navigate to your skill directory
cd my_skills/weather_lookup

# Initialize for publishing (creates .clawhub metadata)
clawhub init

# Validate the skill structure before publishing
clawhub validate

# Publish to ClawHub (requires a ClawHub account)
clawhub login
clawhub publish
```

### Using Downloaded Skills with DemoClaw

Skills installed via ClawHub are automatically placed in OpenClaw's skill discovery path. To integrate them with your DemoClaw setup:

1. **Install skills** using `clawhub install <skill-name>`
2. **Point OpenClaw to the skills directory** — set `OPENCLAW_SKILLS_DIR` in your `.env`:
   ```bash
   # Use the default ClawHub install path
   OPENCLAW_SKILLS_DIR=~/.openclaw/skills
   ```
3. **Restart the stack** — run `./scripts/start.sh` (idempotent: destroys and recreates containers)
4. **Verify** — the agent will list available skills when you ask it "what skills do you have?"

> **Tip:** You can mix ClawHub-installed skills with your own custom skills by symlinking or copying them into the same directory.

---

## Docker Hub 이미지 / Docker Hub Images

Pre-built images are published to Docker Hub for faster startup (no local build required):

| Image | Tag | Description |
|-------|-----|-------------|
| `jinwangmok/democlaw-vllm` | `v1.0.0` | vLLM server with Qwen3-4B-AWQ support |
| `jinwangmok/democlaw-openclaw` | `v1.0.0` | OpenClaw web dashboard |

The `start.sh` (and `start.ps1`) scripts automatically pull these images. If Docker Hub is unreachable, they fall back to building locally from the `vllm/` and `openclaw/` Dockerfiles.

To force a local build, set:
```bash
DEMOCLAW_VLLM_IMAGE=democlaw/vllm:local DEMOCLAW_OPENCLAW_IMAGE=democlaw/openclaw:local ./scripts/start.sh
```

---

## 커스텀 스킬 실습 가이드 (Hands-on Tutorial)

이 가이드는 OpenClaw에서 커스텀 스킬을 만들고 등록하는 과정을 단계별로 실습합니다.

> **사전 조건**: DemoClaw 스택이 실행 중이어야 합니다.
> ```bash
> ./scripts/start.sh   # Linux
> .\scripts\start.ps1  # Windows
> ```

### 실습 1: Hello World 스킬 이해하기

프로젝트에 포함된 예제 스킬의 구조를 먼저 살펴봅시다.

#### 1-1. 스킬 디렉토리 구조 확인

```bash
tree examples/skills/
# examples/skills/
# ├── hello_world/
# │   ├── hello.py         ← Python 스크립트 (실행 코드)
# │   └── skill.yaml       ← 스킬 매니페스트 (메타데이터)
# └── template/
#     ├── skill_template.py ← 템플릿 스크립트
#     └── skill.yaml        ← 템플릿 매니페스트
```

#### 1-2. 스킬 매니페스트 (skill.yaml) 이해

```yaml
name: hello_world                    # 스킬 고유 이름 (영문 소문자 + 밑줄)
description: "간단한 인사 스킬"        # AI가 스킬 선택시 참고하는 설명
version: "1.0.0"                     # 시맨틱 버전
author: "DemoClaw"                   # 작성자
entry_point: hello.py                # 실행할 Python 파일
input_schema:                        # 입력 JSON 스키마
  type: object
  properties:
    name:
      type: string
      description: "인사할 대상 이름"
      default: "World"
output_schema:                       # 출력 JSON 스키마
  type: object
  properties:
    message:
      type: string
      description: "인사 메시지"
```

**핵심 포인트:**
- `entry_point`: AI가 이 스킬을 호출하면 실행되는 파일
- `input_schema`: AI가 어떤 파라미터를 넘겨야 하는지 정의
- `output_schema`: AI가 받을 결과의 형태 정의
- `description`: AI가 "이 스킬을 사용할지 말지" 판단할 때 참고

#### 1-3. Python 스크립트 (hello.py) 이해

```python
#!/usr/bin/env python3
"""Hello World 커스텀 스킬"""
import sys
import json

def main():
    # 1. stdin에서 JSON 입력 읽기 (OpenClaw이 전달)
    input_data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}

    # 2. 입력에서 파라미터 추출
    name = input_data.get("name", "World")

    # 3. 결과를 JSON으로 stdout에 출력 (OpenClaw이 수신)
    result = {"message": f"Hello, {name}! This is a custom OpenClaw skill."}
    print(json.dumps(result))

if __name__ == "__main__":
    main()
```

**핵심 패턴: `stdin → 처리 → stdout`**
- **입력**: `sys.stdin`에서 JSON 읽기
- **출력**: `print(json.dumps(result))`로 JSON 쓰기
- **에러**: `sys.stderr`에 쓰고 `sys.exit(1)`

#### 1-4. 로컬에서 테스트

스킬을 OpenClaw에 등록하기 전에, 단독으로 테스트할 수 있습니다:

```bash
# 기본 테스트 (입력 없음 → "World" 사용)
echo '{}' | python3 examples/skills/hello_world/hello.py
# 출력: {"message": "Hello, World! This is a custom OpenClaw skill."}

# 이름 지정 테스트
echo '{"name": "Alice"}' | python3 examples/skills/hello_world/hello.py
# 출력: {"message": "Hello, Alice! This is a custom OpenClaw skill."}

# 한글 테스트
echo '{"name": "진왕"}' | python3 examples/skills/hello_world/hello.py
# 출력: {"message": "Hello, 진왕! This is a custom OpenClaw skill."}
```

---

### 실습 2: 나만의 스킬 만들기 — 계산기 스킬

간단한 계산기 스킬을 직접 만들어 봅시다.

#### 2-1. 스킬 디렉토리 생성

```bash
mkdir -p my_skills/calculator
```

#### 2-2. Python 스크립트 작성

`my_skills/calculator/calculator.py` 파일을 만듭니다:

```python
#!/usr/bin/env python3
"""
계산기 스킬 — 두 숫자의 사칙연산을 수행합니다.

입력 예시: {"a": 10, "b": 3, "op": "add"}
출력 예시: {"result": 13, "expression": "10 + 3 = 13"}
"""
import sys
import json

OPERATIONS = {
    "add":      lambda a, b: a + b,
    "subtract": lambda a, b: a - b,
    "multiply": lambda a, b: a * b,
    "divide":   lambda a, b: a / b if b != 0 else None,
}

SYMBOLS = {"add": "+", "subtract": "-", "multiply": "*", "divide": "/"}

def run(input_data: dict) -> dict:
    a = input_data.get("a", 0)
    b = input_data.get("b", 0)
    op = input_data.get("op", "add")

    if op not in OPERATIONS:
        return {"error": f"지원하지 않는 연산: {op}. 사용 가능: {list(OPERATIONS.keys())}"}

    if op == "divide" and b == 0:
        return {"error": "0으로 나눌 수 없습니다."}

    result = OPERATIONS[op](a, b)
    symbol = SYMBOLS[op]
    return {
        "result": result,
        "expression": f"{a} {symbol} {b} = {result}"
    }

def main():
    try:
        input_data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}
        output = run(input_data)
        print(json.dumps(output, ensure_ascii=False))
    except Exception as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
```

#### 2-3. 매니페스트 작성

`my_skills/calculator/skill.yaml` 파일을 만듭니다:

```yaml
name: calculator
description: "두 숫자의 사칙연산(덧셈, 뺄셈, 곱셈, 나눗셈)을 수행하는 계산기"
version: "1.0.0"
author: "실습자"
entry_point: calculator.py
input_schema:
  type: object
  required: ["a", "b"]
  properties:
    a:
      type: number
      description: "첫 번째 숫자"
    b:
      type: number
      description: "두 번째 숫자"
    op:
      type: string
      description: "연산 종류"
      enum: ["add", "subtract", "multiply", "divide"]
      default: "add"
output_schema:
  type: object
  properties:
    result:
      type: number
      description: "계산 결과"
    expression:
      type: string
      description: "수식 표현 (예: 10 + 3 = 13)"
    error:
      type: string
      description: "에러 메시지 (실패시)"
```

#### 2-4. 로컬 테스트

```bash
# 덧셈
echo '{"a": 10, "b": 3, "op": "add"}' | python3 my_skills/calculator/calculator.py
# 출력: {"result": 13, "expression": "10 + 3 = 13"}

# 곱셈
echo '{"a": 7, "b": 8, "op": "multiply"}' | python3 my_skills/calculator/calculator.py
# 출력: {"result": 56, "expression": "7 * 8 = 56"}

# 나눗셈
echo '{"a": 100, "b": 3, "op": "divide"}' | python3 my_skills/calculator/calculator.py
# 출력: {"result": 33.333..., "expression": "100 / 3 = 33.333..."}

# 0으로 나누기 (에러 처리 확인)
echo '{"a": 5, "b": 0, "op": "divide"}' | python3 my_skills/calculator/calculator.py
# 출력: {"error": "0으로 나눌 수 없습니다."}
```

---

### 실습 3: 외부 API를 호출하는 스킬 — 날씨 조회

실제 API를 호출하는 스킬을 만들어 봅시다. (무료 API 사용)

#### 3-1. 스킬 생성

```bash
mkdir -p my_skills/weather
```

`my_skills/weather/weather.py`:

```python
#!/usr/bin/env python3
"""
날씨 조회 스킬 — wttr.in 무료 API를 사용합니다.
API 키가 필요 없어 실습에 적합합니다.

입력: {"city": "Seoul"}
출력: {"city": "Seoul", "temperature": "15°C", "condition": "Partly cloudy", ...}
"""
import sys
import json
import urllib.request
import urllib.error

def get_weather(city: str) -> dict:
    """wttr.in API로 날씨 조회"""
    url = f"https://wttr.in/{city}?format=j1"

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "DemoClaw-Skill/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as e:
        return {"error": f"API 요청 실패: {e}"}
    except json.JSONDecodeError:
        return {"error": "API 응답을 파싱할 수 없습니다."}

    current = data.get("current_condition", [{}])[0]
    area = data.get("nearest_area", [{}])[0]

    return {
        "city": area.get("areaName", [{"value": city}])[0]["value"],
        "country": area.get("country", [{"value": ""}])[0]["value"],
        "temperature": f"{current.get('temp_C', '?')}°C",
        "feels_like": f"{current.get('FeelsLikeC', '?')}°C",
        "condition": current.get("weatherDesc", [{"value": "?"}])[0]["value"],
        "humidity": f"{current.get('humidity', '?')}%",
        "wind": f"{current.get('windspeedKmph', '?')} km/h",
    }

def main():
    try:
        input_data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}
        city = input_data.get("city", "Seoul")
        result = get_weather(city)
        print(json.dumps(result, ensure_ascii=False))
    except Exception as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
```

`my_skills/weather/skill.yaml`:

```yaml
name: weather
description: "도시 이름으로 현재 날씨를 조회합니다 (기온, 습도, 체감온도, 바람)"
version: "1.0.0"
author: "실습자"
entry_point: weather.py
input_schema:
  type: object
  properties:
    city:
      type: string
      description: "날씨를 조회할 도시 이름 (영문)"
      default: "Seoul"
output_schema:
  type: object
  properties:
    city:
      type: string
    country:
      type: string
    temperature:
      type: string
    feels_like:
      type: string
    condition:
      type: string
    humidity:
      type: string
    wind:
      type: string
```

#### 3-2. 테스트

```bash
# 서울 날씨
echo '{"city": "Seoul"}' | python3 my_skills/weather/weather.py
# 출력 예: {"city": "Seoul", "temperature": "15°C", "condition": "Partly cloudy", ...}

# 도쿄 날씨
echo '{"city": "Tokyo"}' | python3 my_skills/weather/weather.py

# 뉴욕 날씨
echo '{"city": "New York"}' | python3 my_skills/weather/weather.py
```

---

### 실습 4: 스킬을 OpenClaw에 등록하기

만든 스킬을 OpenClaw 컨테이너에 등록하는 방법입니다.

#### 4-1. 스킬 파일을 컨테이너에 복사

```bash
# 계산기 스킬 복사
docker cp my_skills/calculator democlaw-openclaw:/app/skills/calculator

# 날씨 스킬 복사
docker cp my_skills/weather democlaw-openclaw:/app/skills/weather

# 복사 확인
docker exec democlaw-openclaw ls /app/skills/
```

#### 4-2. OpenClaw에서 스킬 확인

```bash
# 등록된 스킬 목록 확인
docker exec democlaw-openclaw openclaw skills list 2>/dev/null || \
  echo "스킬 목록 명령이 없으면 웹 대시보드에서 확인하세요."
```

#### 4-3. 웹 대시보드에서 테스트

1. 브라우저에서 대시보드 열기: `http://localhost:18789`
2. 채팅창에서 AI에게 스킬 사용 요청:
   - `"서울 날씨 알려줘"` → 날씨 스킬 호출
   - `"123 곱하기 456 계산해줘"` → 계산기 스킬 호출

---

### 실습 5: 나만의 스킬 아이디어

다음 아이디어를 참고하여 자신만의 스킬을 만들어 보세요:

| 난이도 | 스킬 아이디어 | 힌트 |
|--------|--------------|------|
| ★☆☆ | **주사위 굴리기** | `random.randint(1, 6)` |
| ★☆☆ | **문자열 뒤집기** | `text[::-1]` |
| ★★☆ | **환율 변환기** | 무료 API: `api.exchangerate-api.com` |
| ★★☆ | **해시 생성기** | `hashlib.sha256(text.encode()).hexdigest()` |
| ★★★ | **뉴스 요약** | RSS 피드 파싱 + 텍스트 요약 |
| ★★★ | **DB 조회** | `sqlite3` 모듈로 로컬 DB 쿼리 |

#### 스킬 개발 체크리스트

- [ ] `skill.yaml` 작성 (name, description, entry_point, input/output schema)
- [ ] Python 스크립트 작성 (stdin JSON → stdout JSON 패턴)
- [ ] 에러 처리 추가 (try/except → stderr + exit 1)
- [ ] 로컬 테스트 통과 (`echo '...' | python3 my_skill.py`)
- [ ] 컨테이너에 복사 (`docker cp`)
- [ ] 대시보드에서 동작 확인

---

### 자주 묻는 질문 (FAQ)

**Q: 스킬에서 pip 패키지를 사용하고 싶은데요?**
A: `requirements.txt`를 스킬 디렉토리에 넣고, 컨테이너 안에서 설치합니다:
```bash
docker exec democlaw-openclaw pip install -r /app/skills/my_skill/requirements.txt
```

**Q: 스킬이 호출되지 않아요.**
A: `description`을 구체적으로 작성하세요. AI는 description을 보고 어떤 스킬을 쓸지 판단합니다.

**Q: 스킬 디버깅은 어떻게 하나요?**
A: 로컬에서 `echo '입력' | python3 script.py`로 테스트하세요. `logging` 모듈로 디버그 로그를 stderr에 출력하면 OpenClaw 로그에서 볼 수 있습니다.

**Q: 스킬끼리 데이터를 공유할 수 있나요?**
A: 파일 시스템이나 환경 변수를 통해 공유할 수 있습니다. 스킬 간 직접 호출은 지원되지 않습니다.
