#!/usr/bin/env bash
# =============================================================================
# start.sh -- Full E2E startup for the DemoClaw stack (llama.cpp + OpenClaw)
#
# This single script handles the entire lifecycle:
#   1. Clean up old containers/network
#   2. Acquire images (pull from Docker Hub first; local build fallback)
#   3. Create network
#   4. Start llama.cpp server, wait for /health + /v1/models
#   5. Start OpenClaw, wait for dashboard
#   6. Print tokenized dashboard URL
#
# Usage:
#   ./scripts/start.sh
# =============================================================================
set -euo pipefail

log()   { echo "[start] $*"; }
error() { echo "[start] ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Load .env file if present (overrides defaults below)
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck source=/dev/null
    set -a; source "${ENV_FILE}"; set +a
    log "Loaded config from ${ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Unified model cache: ${PROJECT_ROOT}/.data
#
# All engines (llama.cpp GGUF + vLLM NVFP4A16) cache weights under this single
# project-local directory. Set before sourcing apply-profile.sh so the DGX
# Spark NVMe auto-detection short-circuits (user explicit > auto-detect).
# ---------------------------------------------------------------------------
MODEL_DIR="${MODEL_DIR:-${PROJECT_ROOT}/.data}"
export MODEL_DIR
mkdir -p "${MODEL_DIR}"

# ---------------------------------------------------------------------------
# Hardware-aware model/config selection
# ---------------------------------------------------------------------------
# apply-profile.sh detects hardware (or uses HARDWARE_PROFILE from .env),
# then sets model and runtime defaults for the appropriate Gemma 4 variant.
# Variables already set in .env are NOT overridden (user settings win).
if [ -f "${SCRIPT_DIR}/apply-profile.sh" ]; then
    # shellcheck source=apply-profile.sh
    source "${SCRIPT_DIR}/apply-profile.sh"
else
    log "WARNING: apply-profile.sh not found. Using hardcoded defaults."
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LLAMACPP_IMAGE="${DEMOCLAW_LLAMACPP_IMAGE:-docker.io/jinwangmok/democlaw-llamacpp:latest}"
OPENCLAW_IMAGE="${DEMOCLAW_OPENCLAW_IMAGE:-docker.io/jinwangmok/democlaw-openclaw:latest}"
NETWORK="democlaw-net"
LLAMACPP_CONTAINER="democlaw-llamacpp"
OPENCLAW_CONTAINER="democlaw-openclaw"
VLLM_CONTAINER="democlaw-vllm"

# LLM engine selection — set by apply-profile.sh based on hardware detection.
# vllm = vLLM (DGX Spark), llamacpp = llama.cpp (consumer GPU)
LLM_ENGINE="${LLM_ENGINE:-llamacpp}"

# vLLM config — defaults set by apply-profile.sh for DGX Spark.
# The DGX Spark path runs a custom NVFP4A16-quantized Gemma 4 26B A4B MoE
# via jinwangmok/democlaw-spark-gemma4 (Reddit community workaround for GB10
# sm_121). The model weights + gemma4_patched.py are cloned from HuggingFace
# into ${MODEL_DIR}/${VLLM_HF_LOCAL_DIR}/ during pre-download.
VLLM_IMAGE="${VLLM_IMAGE:-docker.io/jinwangmok/democlaw-spark-gemma4:latest}"
VLLM_HF_REPO="${VLLM_HF_REPO:-bg-digitalservices/Gemma-4-26B-A4B-it-NVFP4A16}"
VLLM_HF_LOCAL_DIR="${VLLM_HF_LOCAL_DIR:-Gemma-4-26B-A4B-it-NVFP4A16}"
VLLM_PATCHED_PY_NAME="${VLLM_PATCHED_PY_NAME:-gemma4_patched.py}"
VLLM_CONTAINER_PATCHED_PY="${VLLM_CONTAINER_PATCHED_PY:-/usr/local/lib/python3.12/dist-packages/vllm/model_executor/models/gemma4.py}"
VLLM_CONTAINER_MODEL_PATH="${VLLM_CONTAINER_MODEL_PATH:-/models/gemma-4}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_GPU_MEM_UTIL="${VLLM_GPU_MEM_UTIL:-0.40}"
VLLM_QUANTIZATION="${VLLM_QUANTIZATION:-modelopt}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:---kv-cache-dtype fp8 --moe-backend marlin --enable-auto-tool-choice --tool-call-parser gemma4 --trust-remote-code}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-262144}"
VLLM_HEALTH_TIMEOUT="${VLLM_HEALTH_TIMEOUT:-3600}"

# Model config — defaults now set by apply-profile.sh based on hardware detection.
# These fallbacks are only reached if apply-profile.sh was not sourced.
MODEL_NAME="${MODEL_NAME:-gemma-4-E4B-it}"
MODEL_REPO="${MODEL_REPO:-unsloth/gemma-4-E4B-it-GGUF}"
MODEL_FILE="${MODEL_FILE:-gemma-4-E4B-it-Q4_K_M.gguf}"

# llama.cpp tuning — defaults now set by apply-profile.sh based on hardware.
CTX_SIZE="${CTX_SIZE:-131072}"
N_GPU_LAYERS="${N_GPU_LAYERS:-99}"
FLASH_ATTN="${FLASH_ATTN:-1}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q4_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q4_0}"

# Ports — LLM port is 8000 for both engines
LLM_PORT="8000"
LLAMACPP_PORT="8000"
OPENCLAW_PORT="18789"

# Timeouts (seconds) — LLAMACPP_HEALTH_TIMEOUT may be set by apply-profile.sh
LLAMACPP_HEALTH_TIMEOUT="${LLAMACPP_HEALTH_TIMEOUT:-1800}"
OPENCLAW_HEALTH_TIMEOUT=300   # longer: gateway init (onboard + plugin load) can take time

# Model directory (host path mounted into the container)
# Already set above to ${PROJECT_ROOT}/.data (pre-apply-profile).

# ---------------------------------------------------------------------------
# Detect container runtime
# ---------------------------------------------------------------------------
RUNTIME=""
if [ -n "${CONTAINER_RUNTIME:-}" ] && command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
    RUNTIME="${CONTAINER_RUNTIME}"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    error "No container runtime found. Install docker or podman."
fi

GPU_FLAGS=(--gpus all)
HOSTNAME_LLM=(--hostname llamacpp)
HOSTNAME_OPENCLAW=(--hostname openclaw)
SHM_FLAGS=(--shm-size 1g)

# Detect if the runtime is actually podman (covers podman-docker aliases)
_is_podman=false
if [ "${RUNTIME}" = "podman" ]; then
    _is_podman=true
elif "${RUNTIME}" --version 2>/dev/null | grep -qi podman; then
    _is_podman=true
fi

if [ "${_is_podman}" = "true" ]; then
    GPU_FLAGS=(--device nvidia.com/gpu=all)
    # Podman rootful inherits host UTS/IPC namespaces; --hostname and --shm-size are invalid
    HOSTNAME_LLM=()
    HOSTNAME_OPENCLAW=()
    SHM_FLAGS=()
fi

log "========================================================"
log "  DemoClaw Stack -- Full E2E Startup"
log "========================================================"
log "Runtime: ${RUNTIME}"
if [ "${LLM_ENGINE}" = "vllm" ]; then
    log "Engine : vLLM (NVFP4A16 + modelopt)"
    log "Model  : ${MODEL_NAME} (${VLLM_HF_REPO})"
else
    log "Engine : llama.cpp (CUDA backend)"
    log "Model  : ${MODEL_NAME} (GGUF)"
fi

# ---------------------------------------------------------------------------
# Validate NVIDIA GPU
# ---------------------------------------------------------------------------
log "Checking NVIDIA GPU ..."
command -v nvidia-smi >/dev/null 2>&1 || error "nvidia-smi not found. Install NVIDIA drivers."
nvidia-smi >/dev/null 2>&1 || error "nvidia-smi failed. Check NVIDIA driver installation."
log "NVIDIA GPU OK."

# ===========================================================================
# Phase 0: Clean up old containers and network
# ===========================================================================
log ""
log "--- Phase 0: Cleanup ---"

for cname in "${OPENCLAW_CONTAINER}" "${LLAMACPP_CONTAINER}" "${VLLM_CONTAINER}"; do
    if "${RUNTIME}" container inspect "${cname}" >/dev/null 2>&1; then
        log "Removing old container '${cname}' ..."
        "${RUNTIME}" rm -f "${cname}" >/dev/null 2>&1 || true
    fi
done

if "${RUNTIME}" network inspect "${NETWORK}" >/dev/null 2>&1; then
    log "Removing old network '${NETWORK}' ..."
    "${RUNTIME}" network rm "${NETWORK}" >/dev/null 2>&1 || true
fi

# ===========================================================================
# Phase 0.5: Pre-download model weights into ${MODEL_DIR}
#
# Ensures weights are cached on the host BEFORE the LLM container starts so
# container entrypoints never block on a first-run download. Cache hits on
# subsequent runs skip the network entirely.
# ===========================================================================
log ""
log "--- Phase 0.5: Pre-download model weights (${MODEL_DIR}) ---"

if [ "${LLM_ENGINE}" = "vllm" ]; then
    # DGX Spark: clone the NVFP4A16 HF repo (weights + gemma4_patched.py).
    VLLM_LOCAL_MODEL_DIR="${MODEL_DIR}/${VLLM_HF_LOCAL_DIR}"
    VLLM_PATCHED_PY_HOST="${VLLM_LOCAL_MODEL_DIR}/${VLLM_PATCHED_PY_NAME}"

    if [ -f "${VLLM_PATCHED_PY_HOST}" ] && \
       ls "${VLLM_LOCAL_MODEL_DIR}"/*.safetensors >/dev/null 2>&1; then
        log "vLLM model cache already present at ${VLLM_LOCAL_MODEL_DIR} — skipping clone."
    else
        log "Cloning HF repo '${VLLM_HF_REPO}' -> ${VLLM_LOCAL_MODEL_DIR}"
        command -v git >/dev/null 2>&1 || error "git not found — install git + git-lfs to fetch vLLM weights."
        if ! command -v git-lfs >/dev/null 2>&1; then
            log "WARNING: git-lfs not detected. Large weight files may be stubs."
            log "  Install git-lfs and re-run: https://git-lfs.github.com/"
        else
            git lfs install --skip-repo >/dev/null 2>&1 || true
        fi

        if [ -d "${VLLM_LOCAL_MODEL_DIR}/.git" ]; then
            log "Existing clone detected — resuming via 'git lfs pull'."
            ( cd "${VLLM_LOCAL_MODEL_DIR}" && git lfs pull ) \
                || error "git lfs pull failed in ${VLLM_LOCAL_MODEL_DIR}"
        else
            rm -rf "${VLLM_LOCAL_MODEL_DIR}"
            HF_CLONE_URL="${VLLM_HF_CLONE_URL:-https://huggingface.co/${VLLM_HF_REPO}}"
            git clone "${HF_CLONE_URL}" "${VLLM_LOCAL_MODEL_DIR}" \
                || error "git clone failed: ${HF_CLONE_URL}"
        fi
    fi

    if [ ! -f "${VLLM_PATCHED_PY_HOST}" ]; then
        error "Patched model file missing: ${VLLM_PATCHED_PY_HOST}"
    fi
    log "vLLM weights ready: ${VLLM_LOCAL_MODEL_DIR}"
else
    # llama.cpp: pre-download GGUF (+ mmproj) via download-model.sh.
    if [ -x "${SCRIPT_DIR}/download-model.sh" ]; then
        MODEL_DIR="${MODEL_DIR}" \
        MODEL_REPO="${MODEL_REPO}" \
        MODEL_FILE="${MODEL_FILE}" \
        HF_TOKEN="${HF_TOKEN:-}" \
            "${SCRIPT_DIR}/download-model.sh" --model-dir "${MODEL_DIR}" \
            || error "Pre-download of GGUF model failed."
    else
        log "WARNING: download-model.sh not executable — relying on container entrypoint to fetch model."
    fi
fi

# ===========================================================================
# Phase 1: Acquire images (pull from Docker Hub first; local build fallback)
# ===========================================================================
log ""
log "--- Phase 1: Acquire images ---"

# Source the shared image acquisition library
_img_log()   { log "$@"; }
_img_warn()  { log "WARNING: $*"; }
_img_error() { error "$@"; }
source "${SCRIPT_DIR}/reference/image.sh"

if [ "${LLM_ENGINE}" = "vllm" ]; then
    log "Pulling vLLM image '${VLLM_IMAGE}' ..."
    "${RUNTIME}" pull "${VLLM_IMAGE}" || error "Failed to pull vLLM image: ${VLLM_IMAGE}"
else
    ensure_image "${LLAMACPP_IMAGE}" "${PROJECT_ROOT}/llamacpp"
fi
ensure_image "${OPENCLAW_IMAGE}" "${PROJECT_ROOT}/openclaw"

log "Images ready."

# ---------------------------------------------------------------------------
# Container GPU preflight
#
# Host `nvidia-smi` passing is not enough: vLLM / llama.cpp need the NVIDIA
# Container Toolkit to inject libcuda.so.1 into the container. Without it,
# vLLM dies at engine init with "Failed to infer device type" / "Failed core
# proc(s): {}". We run a smoke test against the just-pulled LLM image and,
# if it fails, print a fix and optionally auto-install the toolkit.
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/reference/gpu-preflight.sh"
if [ "${LLM_ENGINE}" = "vllm" ]; then
    gpu_preflight_require "${VLLM_IMAGE}"
else
    gpu_preflight_require "${LLAMACPP_IMAGE}"
fi

# ===========================================================================
# Phase 2: Create network + start LLM engine
# ===========================================================================
log ""
log "--- Phase 2: Start LLM engine (${LLM_ENGINE}) ---"

log "Creating network '${NETWORK}' ..."
"${RUNTIME}" network create "${NETWORK}" || error "Failed to create network."

mkdir -p "${MODEL_DIR}"

# --- Container name and network alias depend on engine ---
if [ "${LLM_ENGINE}" = "vllm" ]; then
    LLM_CONTAINER="${VLLM_CONTAINER}"
    LLM_ALIAS="vllm"
    LLM_HEALTH_TIMEOUT="${VLLM_HEALTH_TIMEOUT}"
else
    LLM_CONTAINER="${LLAMACPP_CONTAINER}"
    LLM_ALIAS="llamacpp"
    LLM_HEALTH_TIMEOUT="${LLAMACPP_HEALTH_TIMEOUT}"
fi

if [ "${LLM_ENGINE}" = "vllm" ]; then
    # -----------------------------------------------------------------------
    # vLLM engine (DGX Spark) — NVFP4A16 Gemma 4 26B A4B MoE
    #
    # Interface parity with llama.cpp path: same port (${LLM_PORT}=8000),
    # same network (democlaw-net), same network-alias (vllm), served-model
    # name == ${MODEL_NAME} so OpenClaw's LLAMACPP_MODEL_NAME reaches both
    # engines identically. Only the image, the local model path, and the
    # python model patch differ.
    # -----------------------------------------------------------------------
    log "Starting vLLM container ..."
    log "  Image      : ${VLLM_IMAGE}"
    log "  Served as  : ${MODEL_NAME}"
    log "  Model dir  : ${VLLM_LOCAL_MODEL_DIR}"
    log "  Patched py : ${VLLM_PATCHED_PY_HOST}"
    log "  Quant      : ${VLLM_QUANTIZATION}"
    log "  GPU mem    : ${VLLM_GPU_MEM_UTIL}"
    log "  Context    : ${VLLM_MAX_MODEL_LEN} tokens"

    # Disable glob expansion for safe VLLM_EXTRA_ARGS word splitting
    set -f
    # Mirror HOSTNAME_LLM behavior for vLLM: docker sets --hostname vllm, podman inherits host UTS
    HOSTNAME_VLLM=(--hostname vllm)
    if [ "${_is_podman}" = "true" ]; then
        HOSTNAME_VLLM=()
    fi
    MSYS_NO_PATHCONV=1 "${RUNTIME}" run -d \
        --name "${VLLM_CONTAINER}" \
        --network "${NETWORK}" \
        "${HOSTNAME_VLLM[@]}" \
        --network-alias vllm \
        "${GPU_FLAGS[@]}" \
        --restart unless-stopped \
        --ipc host \
        -p "${VLLM_PORT}:${VLLM_PORT}" \
        -e "VLLM_NVFP4_GEMM_BACKEND=marlin" \
        -e "HF_HOME=/data/models" \
        -e "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}" \
        -v "${MODEL_DIR}:/data/models:rw" \
        -v "${VLLM_LOCAL_MODEL_DIR}:${VLLM_CONTAINER_MODEL_PATH}:ro" \
        -v "${VLLM_PATCHED_PY_HOST}:${VLLM_CONTAINER_PATCHED_PY}:ro" \
        "${VLLM_IMAGE}" \
        vllm serve "${VLLM_CONTAINER_MODEL_PATH}" \
        --served-model-name "${MODEL_NAME}" \
        --host 0.0.0.0 \
        --port "${VLLM_PORT}" \
        --gpu-memory-utilization "${VLLM_GPU_MEM_UTIL}" \
        --dtype auto \
        --quantization "${VLLM_QUANTIZATION}" \
        --max-model-len "${VLLM_MAX_MODEL_LEN}" \
        ${VLLM_EXTRA_ARGS} \
        || error "Failed to start vLLM container."
    set +f

    log "vLLM container started. Waiting for health ..."
else
    # -----------------------------------------------------------------------
    # llama.cpp engine (consumer GPU)
    # -----------------------------------------------------------------------
    log "Starting llama.cpp container ..."
    log "  Model      : ${MODEL_REPO}/${MODEL_FILE}"
    log "  Context    : ${CTX_SIZE} tokens"
    log "  GPU layers : ${N_GPU_LAYERS}"
    log "  Flash attn : ${FLASH_ATTN}"
    log "  KV cache   : K=${CACHE_TYPE_K}, V=${CACHE_TYPE_V}"
    log "  Model dir  : ${MODEL_DIR}"

    MSYS_NO_PATHCONV=1 "${RUNTIME}" run -d \
        --name "${LLAMACPP_CONTAINER}" \
        --network "${NETWORK}" \
        "${HOSTNAME_LLM[@]}" \
        --network-alias llamacpp \
        "${GPU_FLAGS[@]}" \
        --restart unless-stopped \
        "${SHM_FLAGS[@]}" \
        -p "${LLAMACPP_PORT}:${LLAMACPP_PORT}" \
        -v "${MODEL_DIR}:/models:rw" \
        -e "MODEL_PATH=/models/${MODEL_FILE}" \
        -e "MODEL_REPO=${MODEL_REPO}" \
        -e "MODEL_FILE=${MODEL_FILE}" \
        -e "MODEL_ALIAS=${MODEL_NAME}" \
        -e "LLAMA_HOST=0.0.0.0" \
        -e "LLAMA_PORT=${LLAMACPP_PORT}" \
        -e "CTX_SIZE=${CTX_SIZE}" \
        -e "N_GPU_LAYERS=${N_GPU_LAYERS}" \
        -e "FLASH_ATTN=${FLASH_ATTN}" \
        -e "CACHE_TYPE_K=${CACHE_TYPE_K}" \
        -e "CACHE_TYPE_V=${CACHE_TYPE_V}" \
        -e "AUTO_DETECT_MODEL=0" \
        "${LLAMACPP_IMAGE}" || error "Failed to start llama.cpp container."

    log "llama.cpp container started. Waiting for health ..."
fi

# ---------------------------------------------------------------------------
# Wait for LLM engine /health
# ---------------------------------------------------------------------------
elapsed=0
while [ "${elapsed}" -lt "${LLM_HEALTH_TIMEOUT}" ]; do
    state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${LLM_CONTAINER}" 2>/dev/null || echo "unknown")
    if [ "${state}" = "exited" ] || [ "${state}" = "dead" ]; then
        log "ERROR: ${LLM_ENGINE} container exited unexpectedly."
        "${RUNTIME}" logs --tail 30 "${LLM_CONTAINER}" 2>&1 || true
        exit 1
    fi

    if curl -sf "http://localhost:${LLM_PORT}/health" >/dev/null 2>&1; then
        log "${LLM_ENGINE} /health OK."
        break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
    if [ $((elapsed % 30)) -eq 0 ]; then
        log "  ... ${LLM_ENGINE} loading (${elapsed}/${LLM_HEALTH_TIMEOUT}s)"
    fi
done

if [ "${elapsed}" -ge "${LLM_HEALTH_TIMEOUT}" ]; then
    error "${LLM_ENGINE} did not become healthy within ${LLM_HEALTH_TIMEOUT}s. Check logs: ${RUNTIME} logs ${LLM_CONTAINER}"
fi

# ---------------------------------------------------------------------------
# Verify /v1/models returns HTTP 200 with the expected model loaded
# ---------------------------------------------------------------------------
log "Checking /v1/models for model '${MODEL_NAME}' ..."
MODELS_URL="http://localhost:${LLM_PORT}/v1/models"
MODELS_TIMEOUT=60
models_elapsed=0
models_verified=false

while [ "${models_elapsed}" -lt "${MODELS_TIMEOUT}" ]; do
    tmpfile=$(mktemp)
    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time 10 "${MODELS_URL}" 2>/dev/null || echo "000")
    response=$(cat "${tmpfile}" 2>/dev/null || echo "")
    rm -f "${tmpfile}"

    if [ "${http_code}" = "200" ] && [ -n "${response}" ]; then
        model_check=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = [m.get('id','') for m in data.get('data', [])]
    if models:
        print('found:' + ','.join(models))
    else:
        print('empty')
except Exception:
    print('error')
" 2>/dev/null || echo "error")

        case "${model_check}" in
            found:*)
                models_listed="${model_check#found:}"
                log "${LLM_ENGINE} /v1/models returned HTTP 200."
                log "  Available models: ${models_listed}"
                models_verified=true
                break
                ;;
            empty)
                ;;
        esac
    fi

    sleep 5
    models_elapsed=$((models_elapsed + 5))
    if [ $((models_elapsed % 15)) -eq 0 ]; then
        log "  ... waiting for /v1/models (${models_elapsed}/${MODELS_TIMEOUT}s, HTTP ${http_code})"
    fi
done

if [ "${models_verified}" != "true" ]; then
    log "WARNING: /v1/models did not confirm model readiness within ${MODELS_TIMEOUT}s."
    log "  Last HTTP status: ${http_code:-000}"
    log "  The model may still be loading. Check: curl ${MODELS_URL}"
    log "  Container logs: ${RUNTIME} logs -f ${LLM_CONTAINER}"
fi

# ===========================================================================
# Phase 3: Start OpenClaw
# ===========================================================================
log ""
log "--- Phase 3: Start OpenClaw ---"

log "Starting OpenClaw container ..."

# Context size passed to OpenClaw depends on engine
if [ "${LLM_ENGINE}" = "vllm" ]; then
    OC_CTX_SIZE="${VLLM_MAX_MODEL_LEN}"
else
    OC_CTX_SIZE="${CTX_SIZE}"
fi

# mcporter configuration — mount from host if it exists
MCPORTER_MOUNT=()
MCPORTER_CONFIG="${PROJECT_ROOT}/config/mcporter.json"
if [ -f "${MCPORTER_CONFIG}" ]; then
    MCPORTER_MOUNT=(-v "${MCPORTER_CONFIG}:/app/config/mcporter.json:ro")
    log "  mcporter config: ${MCPORTER_CONFIG} -> /app/config/mcporter.json"
fi

# Data persistence mount — persist OpenClaw settings, pairings, credentials
DATA_MOUNT=()
if [ -n "${OPENCLAW_DATA_DIR:-}" ]; then
    if [ -d "${OPENCLAW_DATA_DIR}" ] || mkdir -p "${OPENCLAW_DATA_DIR}" 2>/dev/null; then
        DATA_MOUNT=(-v "${OPENCLAW_DATA_DIR}:/home/openclaw/.openclaw:rw")
        log "  data mount: ${OPENCLAW_DATA_DIR} -> /home/openclaw/.openclaw"
    else
        log "WARNING: OPENCLAW_DATA_DIR='${OPENCLAW_DATA_DIR}' could not be created. Skipping mount."
    fi
fi

# Workspace volume mount — bind host directory into OpenClaw container
WORKSPACE_MOUNT=()
if [ -n "${OPENCLAW_WORKSPACE_DIR:-}" ]; then
    if [ -d "${OPENCLAW_WORKSPACE_DIR}" ]; then
        WORKSPACE_MOUNT=(-v "${OPENCLAW_WORKSPACE_DIR}:/app/workspace:rw")
        log "  workspace mount: ${OPENCLAW_WORKSPACE_DIR} -> /app/workspace"
    else
        log "WARNING: OPENCLAW_WORKSPACE_DIR='${OPENCLAW_WORKSPACE_DIR}' does not exist. Skipping mount."
    fi
fi

MSYS_NO_PATHCONV=1 "${RUNTIME}" run -d \
    --name "${OPENCLAW_CONTAINER}" \
    --network "${NETWORK}" \
    "${HOSTNAME_OPENCLAW[@]}" \
    --network-alias openclaw \
    --restart unless-stopped \
    -p "${OPENCLAW_PORT}:${OPENCLAW_PORT}" \
    -p 18791:18791 \
    "${MCPORTER_MOUNT[@]}" \
    "${DATA_MOUNT[@]}" \
    "${WORKSPACE_MOUNT[@]}" \
    -e "LLAMACPP_BASE_URL=http://${LLM_ALIAS}:${LLM_PORT}/v1" \
    -e "LLAMACPP_API_KEY=EMPTY" \
    -e "LLAMACPP_MODEL_NAME=${MODEL_NAME}" \
    -e "OPENCLAW_PORT=${OPENCLAW_PORT}" \
    -e "CTX_SIZE=${OC_CTX_SIZE}" \
    "${OPENCLAW_IMAGE}" || error "Failed to start OpenClaw container."

log "OpenClaw container started. Waiting for dashboard ..."

# ---------------------------------------------------------------------------
# Wait for OpenClaw gateway to respond on its port
#
# The dashboard root (/) returns HTTP 500 without an auth token — this is
# normal.  We only need to confirm the gateway process is listening: any
# HTTP response (200, 500, 302, …) means the gateway is up.  HTTP 000
# means the port is not yet open (connection refused / timeout).
# ---------------------------------------------------------------------------
oc_elapsed=0
oc_http_code="000"
while [ "${oc_elapsed}" -lt "${OPENCLAW_HEALTH_TIMEOUT}" ]; do
    state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${OPENCLAW_CONTAINER}" 2>/dev/null || echo "unknown")
    if [ "${state}" = "exited" ] || [ "${state}" = "dead" ]; then
        log "ERROR: OpenClaw container exited unexpectedly."
        "${RUNTIME}" logs --tail 20 "${OPENCLAW_CONTAINER}" 2>&1 || true
        exit 1
    fi

    oc_http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 "http://localhost:${OPENCLAW_PORT}/" 2>/dev/null || echo "000")

    if [ "${oc_http_code}" != "000" ]; then
        log "OpenClaw gateway is responding (HTTP ${oc_http_code})."
        break
    fi

    sleep 3
    oc_elapsed=$((oc_elapsed + 3))
    if [ $((oc_elapsed % 15)) -eq 0 ]; then
        log "  ... waiting for OpenClaw gateway (${oc_elapsed}/${OPENCLAW_HEALTH_TIMEOUT}s)"
    fi
done

if [ "${oc_http_code}" = "000" ]; then
    error "OpenClaw gateway did not respond within ${OPENCLAW_HEALTH_TIMEOUT}s. Check logs: ${RUNTIME} logs ${OPENCLAW_CONTAINER}"
fi

# ===========================================================================
# Phase 4: All health-checks passed — print dashboard URL
# ===========================================================================

# Resolve dashboard URL: retry until the gateway is ready to report its URL
DASHBOARD_URL=""
log "Retrieving tokenized dashboard URL ..."
for _url_attempt in $(seq 1 6); do
    # Method 1: openclaw dashboard --no-open (look for URL with token)
    _raw=$("${RUNTIME}" exec "${OPENCLAW_CONTAINER}" openclaw dashboard --no-open 2>&1 || true)
    DASHBOARD_URL=$(echo "${_raw}" | grep -oE 'https?://[^ ]*token=[^ ]*' | head -1 || true)
    # Fallback: any URL from the output (may lack token)
    if [ -z "${DASHBOARD_URL}" ]; then
        DASHBOARD_URL=$(echo "${_raw}" | grep -oE 'https?://[^ ]+' | head -1 || true)
        # Only accept if it contains a token
        if ! echo "${DASHBOARD_URL}" | grep -q 'token='; then
            DASHBOARD_URL=""
        fi
    fi

    # Method 2: search container logs for the tokenized URL
    if [ -z "${DASHBOARD_URL}" ]; then
        DASHBOARD_URL=$("${RUNTIME}" logs "${OPENCLAW_CONTAINER}" 2>&1 \
            | grep -oE "https?://[^ ]*token=[^ ]*" | tail -1 || true)
    fi

    if [ -n "${DASHBOARD_URL}" ]; then
        break
    fi
    log "  ... URL not ready yet (attempt ${_url_attempt}/6), retrying in 10s"
    sleep 10
done

# Normalize: replace 127.0.0.1 and 0.0.0.0 with localhost for host access
if [ -n "${DASHBOARD_URL}" ]; then
    DASHBOARD_URL=$(echo "${DASHBOARD_URL}" | sed -e 's/127\.0\.0\.1/localhost/' -e 's/0\.0\.0\.0/localhost/')
fi

# Fallback: plain URL without token
if [ -z "${DASHBOARD_URL}" ]; then
    DASHBOARD_URL="http://localhost:${OPENCLAW_PORT}"
    log "WARNING: Could not retrieve tokenized dashboard URL."
    log "  Try manually: ${RUNTIME} exec ${OPENCLAW_CONTAINER} openclaw dashboard --no-open"
fi

LLM_API_URL="http://localhost:${LLM_PORT}/v1"

# --- GIST Dream AI Lab Banner ---
printf '\n'
printf ' \033[1;34m ██████  ██████  ███████  █████  ███   ███        █████  ██\033[0m \033[1;33m✦\033[0m\n'
printf ' \033[1;34m ██   ██ ██   ██ ██      ██   ██ ████ ████       ██   ██ ██\033[0m\n'
printf ' \033[1;34m ██   ██ ██████  █████   ███████ ██ ███ ██ ───── ███████ ██\033[0m\n'
printf ' \033[1;34m ██   ██ ██   ██ ██      ██   ██ ██     ██       ██   ██ ██\033[0m\n'
printf ' \033[1;34m ██████  ██   ██ ███████ ██   ██ ██     ██       ██   ██ ██\033[0m\n'
printf '\n'
printf ' \033[0;37m*~*~────────────────────────:══:────────────────────────~*~*\033[0m\n'
printf '\n'
printf ' \033[1;31m  ██████ \033[1;37m ██ ███████ ████████\033[0m\n'
printf ' \033[1;31m ██      \033[1;37m ██ ██         ██\033[0m\n'
printf ' \033[1;31m ██   ███\033[1;37m ██ ███████    ██\033[0m\n'
printf ' \033[1;31m ██    ██\033[1;37m ██      ██    ██\033[0m\n'
printf ' \033[1;31m  ██████ \033[1;37m ██ ███████    ██\033[0m\n'
printf '\n'
printf ' \033[0;37m Welcome to GIST Dream AI Lab.\033[0m\n'
printf ' \033[0;37m Gwangju Institute of Science and Technology.\033[0m\n'
printf '\n'
# --- DemoClaw Status ---
printf ' \033[1;36m ____                         ____ _\033[0m\n'
printf ' \033[1;36m|  _ \\  ___ _ __ ___   ___   / ___| | __ ___      __\033[0m\n'
printf ' \033[1;36m| | | |/ _ \\ '"'"'_ ` _ \\ / _ \\ | |   | |/ _` \\ \\ /\\ / /\033[0m\n'
printf ' \033[1;36m| |_| |  __/ | | | | | (_) || |___| | (_| |\\ V  V /\033[0m\n'
printf ' \033[1;36m|____/ \\___|_| |_| |_|\\___/  \\____|_|\\__,_| \\_/\\_/\033[0m\n'
printf '\n'
printf ' \033[1;32m >>> All systems operational <<<\033[0m\n'
printf '\n'
printf ' \033[0;37m──────────────────────────────────────────────────────────\033[0m\n'
printf '  \033[1;33mServices\033[0m\n'
printf '    LLM API  : %s\n' "${LLM_API_URL}"
if [ "${LLM_ENGINE}" = "vllm" ]; then
    printf '    Engine   : vLLM (NVFP4A16)\n'
    printf '    Model    : %s (%s)\n' "${MODEL_NAME}" "${VLLM_HF_REPO}"
    printf '    Context  : %s tokens\n' "${VLLM_MAX_MODEL_LEN}"
else
    printf '    Engine   : llama.cpp (CUDA)\n'
    printf '    Model    : %s (%s)\n' "${MODEL_NAME}" "${MODEL_REPO}"
    printf '    Context  : %s tokens\n' "${CTX_SIZE}"
fi
printf '    Runtime  : %s\n' "${RUNTIME}"
printf '\n'
printf '  \033[1;33mDashboard\033[0m\n'
printf '    %s\n' "${DASHBOARD_URL}"
printf '\n'
printf '  \033[0;90mFirst connect: click "Connect" in the browser.\033[0m\n'
printf '  \033[0;90mStop: ./scripts/stop.sh\033[0m\n'
printf ' \033[0;37m──────────────────────────────────────────────────────────\033[0m\n'
printf '\n'
