#!/usr/bin/env bash
# =============================================================================
# start.sh -- Full E2E startup for the DemoClaw stack (vLLM + OpenClaw)
#
# This single script handles the entire lifecycle:
#   1. Clean up old containers/network
#   2. Build images (always rebuild to pick up Dockerfile changes)
#   3. Create network
#   4. Start vLLM, wait for /health + /v1/models
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
# Configuration
# ---------------------------------------------------------------------------
VLLM_IMAGE="democlaw/vllm:latest"
OPENCLAW_IMAGE="democlaw/openclaw:latest"
NETWORK="democlaw-net"
VLLM_CONTAINER="democlaw-vllm"
OPENCLAW_CONTAINER="democlaw-openclaw"
MODEL_NAME="Qwen/Qwen3-4B-AWQ"

# vLLM tuning for 8GB VRAM
MAX_MODEL_LEN="16384"
QUANTIZATION="awq_marlin"
DTYPE="float16"
GPU_MEMORY_UTILIZATION="0.95"

# Ports
VLLM_PORT="8000"
OPENCLAW_PORT="18789"

# Timeouts (seconds)
VLLM_HEALTH_TIMEOUT=300
OPENCLAW_HEALTH_TIMEOUT=120

# HuggingFace cache
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"

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

GPU_FLAGS="--gpus all"
if [ "${RUNTIME}" = "podman" ]; then
    GPU_FLAGS="--device nvidia.com/gpu=all"
fi

log "========================================================"
log "  DemoClaw Stack -- Full E2E Startup"
log "========================================================"
log "Runtime: ${RUNTIME}"

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

for cname in "${OPENCLAW_CONTAINER}" "${VLLM_CONTAINER}"; do
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
# Phase 1: Build images (always rebuild to pick up changes)
# ===========================================================================
log ""
log "--- Phase 1: Build images ---"

log "Building vLLM image ..."
"${RUNTIME}" build -t "${VLLM_IMAGE}" "${PROJECT_ROOT}/vllm" || error "Failed to build vLLM image."

log "Building OpenClaw image ..."
"${RUNTIME}" build -t "${OPENCLAW_IMAGE}" "${PROJECT_ROOT}/openclaw" || error "Failed to build OpenClaw image."

log "Images built."

# ===========================================================================
# Phase 2: Create network + start vLLM
# ===========================================================================
log ""
log "--- Phase 2: Start vLLM ---"

log "Creating network '${NETWORK}' ..."
"${RUNTIME}" network create "${NETWORK}" || error "Failed to create network."

mkdir -p "${HF_CACHE_DIR}"

log "Starting vLLM container ..."
log "  Model        : ${MODEL_NAME}"
log "  Quantization : ${QUANTIZATION}"
log "  Context      : ${MAX_MODEL_LEN}"
log "  GPU mem util : ${GPU_MEMORY_UTILIZATION}"

# shellcheck disable=SC2086
"${RUNTIME}" run -d \
    --name "${VLLM_CONTAINER}" \
    --network "${NETWORK}" \
    --hostname vllm \
    --network-alias vllm \
    ${GPU_FLAGS} \
    --restart unless-stopped \
    --shm-size 1g \
    -p "${VLLM_PORT}:${VLLM_PORT}" \
    -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
    -e "MODEL_NAME=${MODEL_NAME}" \
    -e "MAX_MODEL_LEN=${MAX_MODEL_LEN}" \
    -e "GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}" \
    -e "QUANTIZATION=${QUANTIZATION}" \
    -e "DTYPE=${DTYPE}" \
    -e "VLLM_ATTENTION_BACKEND=FLASHINFER" \
    "${VLLM_IMAGE}" || error "Failed to start vLLM container."

log "vLLM container started. Waiting for health ..."

# ---------------------------------------------------------------------------
# Wait for vLLM /health
# ---------------------------------------------------------------------------
elapsed=0
while [ "${elapsed}" -lt "${VLLM_HEALTH_TIMEOUT}" ]; do
    state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${VLLM_CONTAINER}" 2>/dev/null || echo "unknown")
    if [ "${state}" = "exited" ] || [ "${state}" = "dead" ]; then
        log "ERROR: vLLM container exited unexpectedly."
        "${RUNTIME}" logs --tail 20 "${VLLM_CONTAINER}" 2>&1 || true
        exit 1
    fi

    if curl -sf "http://localhost:${VLLM_PORT}/health" >/dev/null 2>&1; then
        log "vLLM /health OK."
        break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
    if [ $((elapsed % 30)) -eq 0 ]; then
        log "  ... vLLM loading (${elapsed}/${VLLM_HEALTH_TIMEOUT}s)"
    fi
done

if [ "${elapsed}" -ge "${VLLM_HEALTH_TIMEOUT}" ]; then
    error "vLLM did not become healthy within ${VLLM_HEALTH_TIMEOUT}s. Check logs: ${RUNTIME} logs ${VLLM_CONTAINER}"
fi

# ---------------------------------------------------------------------------
# Verify /v1/models
# ---------------------------------------------------------------------------
log "Checking /v1/models ..."
models_elapsed=0
while [ "${models_elapsed}" -lt 60 ]; do
    if curl -sf "http://localhost:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
        log "vLLM /v1/models OK. Model ready."
        break
    fi
    sleep 5
    models_elapsed=$((models_elapsed + 5))
done

# ===========================================================================
# Phase 3: Start OpenClaw
# ===========================================================================
log ""
log "--- Phase 3: Start OpenClaw ---"

log "Starting OpenClaw container ..."

"${RUNTIME}" run -d \
    --name "${OPENCLAW_CONTAINER}" \
    --network "${NETWORK}" \
    --hostname openclaw \
    --network-alias openclaw \
    --restart unless-stopped \
    -p "${OPENCLAW_PORT}:${OPENCLAW_PORT}" \
    -p 18791:18791 \
    -e "VLLM_BASE_URL=http://vllm:8000/v1" \
    -e "VLLM_API_KEY=EMPTY" \
    -e "VLLM_MODEL_NAME=${MODEL_NAME}" \
    -e "OPENCLAW_PORT=${OPENCLAW_PORT}" \
    "${OPENCLAW_IMAGE}" || error "Failed to start OpenClaw container."

log "OpenClaw container started. Waiting for dashboard ..."

# ---------------------------------------------------------------------------
# Wait for OpenClaw dashboard
# ---------------------------------------------------------------------------
oc_elapsed=0
while [ "${oc_elapsed}" -lt "${OPENCLAW_HEALTH_TIMEOUT}" ]; do
    state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${OPENCLAW_CONTAINER}" 2>/dev/null || echo "unknown")
    if [ "${state}" = "exited" ] || [ "${state}" = "dead" ]; then
        log "ERROR: OpenClaw container exited unexpectedly."
        "${RUNTIME}" logs --tail 20 "${OPENCLAW_CONTAINER}" 2>&1 || true
        exit 1
    fi

    if curl -sf "http://localhost:${OPENCLAW_PORT}/" >/dev/null 2>&1; then
        log "OpenClaw dashboard responding."
        break
    fi

    sleep 3
    oc_elapsed=$((oc_elapsed + 3))
    if [ $((oc_elapsed % 15)) -eq 0 ]; then
        log "  ... waiting for OpenClaw (${oc_elapsed}/${OPENCLAW_HEALTH_TIMEOUT}s)"
    fi
done

if [ "${oc_elapsed}" -ge "${OPENCLAW_HEALTH_TIMEOUT}" ]; then
    error "OpenClaw dashboard did not respond within ${OPENCLAW_HEALTH_TIMEOUT}s. Check logs: ${RUNTIME} logs ${OPENCLAW_CONTAINER}"
fi

# ===========================================================================
# Phase 4: Show result
# ===========================================================================
log ""
log "========================================================"
log "  DemoClaw is running!"
log "========================================================"
log ""
log "  vLLM API : http://localhost:${VLLM_PORT}/v1"
log "  Model    : ${MODEL_NAME}"
log "  Runtime  : ${RUNTIME}"
log ""

DASHBOARD_URL=$("${RUNTIME}" exec "${OPENCLAW_CONTAINER}" openclaw dashboard --no-open 2>/dev/null \
    | grep -oP 'https?://[^\s]+' | head -1 | sed 's/127\.0\.0\.1/localhost/' || true)

if [ -n "${DASHBOARD_URL}" ]; then
    log "  Dashboard: ${DASHBOARD_URL}"
else
    log "  Dashboard: http://localhost:${OPENCLAW_PORT}"
fi

log ""
log "  NOTE: On first connect, click \"Connect\" in the browser."
log "        The device pairing is auto-approved within ~2 seconds."
log "        If needed, click \"Connect\" again after approval."
log ""
log "  Stop with: ./scripts/stop.sh"
log "========================================================"
