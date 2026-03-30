#!/usr/bin/env bash
# =============================================================================
# start-llamacpp.sh — Pull the Qwen3-4B AWQ 4-bit model and launch the llama.cpp
#                  container serving it via an OpenAI-compatible API.
#
# Supports both docker and podman on Linux hosts.
# Requires: NVIDIA GPU with >= 8GB VRAM, nvidia-container-toolkit installed.
#
# Steps performed:
#   1. Validate host OS, container runtime, and NVIDIA GPU/CUDA
#   2. Build the llama.cpp image if not already present
#   3. Pre-pull Qwen3-4B AWQ 4-bit weights from HuggingFace (skip if cached)
#   4. Launch the llama.cpp server container with GPU passthrough and model config
#   5. Wait for /health and /v1/models endpoints to confirm readiness
#
# Usage:
#   ./scripts/start-llamacpp.sh                          # auto-detect runtime
#   CONTAINER_RUNTIME=podman ./scripts/start-llamacpp.sh # force podman
#   SKIP_MODEL_PULL=true ./scripts/start-llamacpp.sh     # skip step 3 (model cached)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants & Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { echo "[start-llamacpp] $*"; }
warn()  { echo "[start-llamacpp] WARNING: $*" >&2; }
error() { printf "[start-llamacpp] ERROR: %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load .env file if present (key=value, no export needed)
# Must happen BEFORE variable defaults so .env values take precedence.
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    log "Loading environment from ${ENV_FILE}"
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

# ---------------------------------------------------------------------------
# Configurable defaults (all overridable via environment or .env file)
# ---------------------------------------------------------------------------
CONTAINER_NAME="${LLAMACPP_CONTAINER_NAME:-democlaw-llamacpp}"
NETWORK_NAME="${DEMOCLAW_NETWORK:-democlaw-net}"
IMAGE_TAG="${LLAMACPP_IMAGE_TAG:-docker.io/jinwangmok/democlaw-llamacpp:v1.0.0}"

MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-4B-AWQ}"
LLAMACPP_HOST="${LLAMACPP_HOST:-0.0.0.0}"
LLAMACPP_PORT="${LLAMACPP_PORT:-8000}"
LLAMACPP_HOST_PORT="${LLAMACPP_HOST_PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
QUANTIZATION="${QUANTIZATION:-awq}"
DTYPE="${DTYPE:-float16}"

# API key for the OpenAI-compatible endpoint.
# Leave empty (or "EMPTY") for no-auth mode — the default, safe on a trusted
# private container network.  Set to a real secret to require
# "Authorization: Bearer <key>" on every request from OpenClaw and clients.
LLAMACPP_API_KEY="${LLAMACPP_API_KEY:-}"

# HuggingFace cache — share host cache to avoid re-downloading models
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"

# Set to "true" to skip the model pre-pull step (e.g. weights already cached)
SKIP_MODEL_PULL="${SKIP_MODEL_PULL:-false}"

# ---------------------------------------------------------------------------
# Detect container runtime: prefer $CONTAINER_RUNTIME, then docker, then podman
# Uses the shared runtime detection library for consistent behavior.
# ---------------------------------------------------------------------------
_rt_log()   { log "$@"; }
_rt_warn()  { warn "$@"; }
_rt_error() { error "$@"; }

# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

log "Using container runtime: ${RUNTIME}"

# ---------------------------------------------------------------------------
# Verify Linux host OS
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
    error "This script requires a Linux host (detected: $(uname -s)). Exiting."
fi

# ---------------------------------------------------------------------------
# Validate NVIDIA GPU & CUDA availability using the shared gpu library
# ---------------------------------------------------------------------------
# Override gpu.sh logging to use our prefix
_gpu_log()   { log "$@"; }
_gpu_warn()  { warn "$@"; }
_gpu_error() { error "$@"; }

# shellcheck source=lib/gpu.sh
source "${SCRIPT_DIR}/lib/gpu.sh"

validate_nvidia_gpu "${RUNTIME}"

# ---------------------------------------------------------------------------
# Ensure the shared container network exists
#
# Uses runtime_ensure_network() from lib/runtime.sh — idempotent and works
# identically on both docker and podman.  Creates the network if absent;
# no-ops (with a log message) if it already exists.
#
# Both the llama.cpp container (--hostname llamacpp --network-alias llamacpp) and the
# OpenClaw container connect to this network, allowing OpenClaw to reach
# llama.cpp via the predictable URL:  http://llamacpp:${LLAMACPP_PORT}/v1
# ---------------------------------------------------------------------------
runtime_ensure_network "${NETWORK_NAME}"

# ---------------------------------------------------------------------------
# Handle existing container (idempotent destroy-and-recreate)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Idempotent container teardown: ALWAYS destroy and recreate.
# This ensures every run produces an identical end-state regardless of prior
# state — running, stopped, paused, or dead containers are all removed.
# ---------------------------------------------------------------------------
handle_existing_container() {
    if "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
        local state
        state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null \
               || "${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}")

        log "Removing existing container '${CONTAINER_NAME}' (state: ${state}) for fresh recreation ..."
        "${RUNTIME}" rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
    fi
}

handle_existing_container

# ---------------------------------------------------------------------------
# Acquire llama.cpp image (pull from Docker Hub first; local build fallback)
#
# Strategy: Always attempt to pull the pre-built image from Docker Hub.
# If pull fails (non-zero exit), fall back to building from the local
# Dockerfile at <project_root>/llamacpp/Dockerfile.
# ---------------------------------------------------------------------------
_img_log()   { log "$@"; }
_img_warn()  { warn "$@"; }
_img_error() { error "$@"; }
source "${SCRIPT_DIR}/lib/image.sh"

ensure_image "${IMAGE_TAG}" "${PROJECT_ROOT}/llamacpp"

# ---------------------------------------------------------------------------
# Prepare HuggingFace cache directory on the host
# ---------------------------------------------------------------------------
mkdir -p "${HF_CACHE_DIR}"

# ---------------------------------------------------------------------------
# Source checksum library for model integrity verification
# ---------------------------------------------------------------------------
_cksum_log()   { log "$@"; }
_cksum_warn()  { warn "$@"; }
_cksum_error() { echo "[start-llamacpp] ERROR: $*" >&2; }

# shellcheck source=lib/checksum.sh
source "${SCRIPT_DIR}/lib/checksum.sh"

# ---------------------------------------------------------------------------
# pull_model_weights — Pre-download the Qwen3-4B AWQ 4-bit weights
#
# Runs a short-lived container using the built llama.cpp image (which already has
# Python and huggingface_hub installed) to invoke `huggingface-cli download`.
# The HF cache directory is bind-mounted so weights persist across runs.
#
# Checksum-verified idempotency:
#   1. Before download: check existing files against stored .sha256 checksums
#   2. If ALL checksums match → skip download entirely (verified cache hit)
#   3. If any mismatch or missing → proceed with (re-)download
#   4. After download: compute and store new .sha256 sidecar files
#
# Set SKIP_MODEL_PULL=true to bypass this step entirely.
# Set HF_TOKEN (or HUGGING_FACE_HUB_TOKEN) for gated/private models.
# ---------------------------------------------------------------------------
pull_model_weights() {
    if [ "${SKIP_MODEL_PULL}" = "true" ]; then
        log "SKIP_MODEL_PULL=true — skipping model pre-pull (assuming weights are cached)."
        return 0
    fi

    log "======================================================="
    log "  Step: Pull model weights from HuggingFace"
    log "  Model      : ${MODEL_NAME}"
    log "  Cache dir  : ${HF_CACHE_DIR}"
    log "======================================================="

    # ------------------------------------------------------------------
    # Checksum verification: skip download if all files pass
    # ------------------------------------------------------------------
    if ! checksum_model_needs_download "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        log "Checksum verification passed — model files are intact."
        log "Skipping download."
        log "======================================================="
        return 0
    fi

    log "This may take several minutes on first run (~5 GB download)."
    log "Subsequent runs with verified checksums will skip instantly."

    # Build GPU flags (needed even for download container to share the image cleanly,
    # though GPU is not strictly required just for downloading weights)
    local gpu_flags
    gpu_flags=$(runtime_gpu_flags)

    # Compose HF_TOKEN env flags (pass only if non-empty)
    local hf_token_flags=""
    if [ -n "${HF_TOKEN:-}" ]; then
        hf_token_flags="-e HF_TOKEN=${HF_TOKEN} -e HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}"
    fi

    log "Running model download container (democlaw-llamacpp-pull) ..."

    # shellcheck disable=SC2086
    "${RUNTIME}" run --rm \
        --name "democlaw-llamacpp-pull" \
        ${gpu_flags} \
        --shm-size 1g \
        -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
        -e "HF_HUB_DISABLE_PROGRESS_BARS=0" \
        ${hf_token_flags} \
        "${IMAGE_TAG}" \
        python3 -c "
import sys, os
# Show which cache directory is in use
cache = os.environ.get('HF_HOME', os.path.expanduser('~/.cache/huggingface'))
print(f'[pull] HuggingFace cache: {cache}')

model_name = '${MODEL_NAME}'
print(f'[pull] Downloading model: {model_name}')

try:
    from huggingface_hub import snapshot_download

    print(f'[pull] Downloading {model_name} weights ...')
    local_path = snapshot_download(
        repo_id=model_name,
        ignore_patterns=['*.pt', '*.bin'],  # prefer safetensors
    )
    print(f'[pull] Download complete. Weights stored at: {local_path}')
except ImportError as e:
    print(f'[pull] huggingface_hub not available: {e}', file=sys.stderr)
    print('[pull] Falling back to llama.cpp startup download.', file=sys.stderr)
    sys.exit(0)
except Exception as e:
    print(f'[pull] Download failed: {e}', file=sys.stderr)
    print('[pull] The llama.cpp server will attempt to download on first start.', file=sys.stderr)
    sys.exit(1)
"

    # ------------------------------------------------------------------
    # Post-download: store checksums for all model files
    # These .sha256 sidecars enable checksum-verified skipping on next run.
    # ------------------------------------------------------------------
    log "Storing checksums for downloaded model files ..."
    checksum_store_model_cache "${HF_CACHE_DIR}" "${MODEL_NAME}" || {
        warn "Failed to store model checksums. Download will not be skipped on next run."
    }

    log "Model pre-pull step complete."
    log "======================================================="
}

pull_model_weights

# ---------------------------------------------------------------------------
# Build GPU flags based on runtime (uses shared library helper)
# ---------------------------------------------------------------------------
GPU_FLAGS=$(runtime_gpu_flags)

# ---------------------------------------------------------------------------
# Launch the llama.cpp container
# ---------------------------------------------------------------------------
log "======================================================="
log "  Step: Launch llama.cpp server container"
log "======================================================="
_auth_mode="no-auth (any client may call the API)"
if [ -n "${LLAMACPP_API_KEY}" ] && [ "${LLAMACPP_API_KEY}" != "EMPTY" ] && [ "${LLAMACPP_API_KEY}" != "none" ]; then
    _auth_mode="api-key (clients must send Authorization: Bearer <key>)"
fi

log "Starting llama.cpp container '${CONTAINER_NAME}' ..."
log "  Model           : ${MODEL_NAME}"
log "  Quantization    : ${QUANTIZATION}"
log "  Max model len   : ${MAX_MODEL_LEN}"
log "  GPU mem util    : ${GPU_MEMORY_UTILIZATION}"
log "  Bind address    : ${LLAMACPP_HOST}:${LLAMACPP_PORT}  (0.0.0.0 = reachable from all containers)"
log "  Network alias   : llamacpp  (OpenClaw uses http://llamacpp:${LLAMACPP_PORT}/v1)"
log "  Host port       : ${LLAMACPP_HOST_PORT} -> container ${LLAMACPP_PORT}"
log "  Auth mode       : ${_auth_mode}"
log "  HF cache        : ${HF_CACHE_DIR}"

# shellcheck disable=SC2086
"${RUNTIME}" run -d \
    --name "${CONTAINER_NAME}" \
    --network "${NETWORK_NAME}" \
    --hostname llamacpp \
    --network-alias llamacpp \
    ${GPU_FLAGS} \
    --restart unless-stopped \
    --shm-size 1g \
    -p "${LLAMACPP_HOST_PORT}:${LLAMACPP_PORT}" \
    -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
    -e "MODEL_NAME=${MODEL_NAME}" \
    -e "LLAMACPP_HOST=${LLAMACPP_HOST}" \
    -e "LLAMACPP_PORT=${LLAMACPP_PORT}" \
    -e "MAX_MODEL_LEN=${MAX_MODEL_LEN}" \
    -e "GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}" \
    -e "QUANTIZATION=${QUANTIZATION}" \
    -e "DTYPE=${DTYPE}" \
    -e "LLAMACPP_API_KEY=${LLAMACPP_API_KEY:-}" \
    -e "HF_TOKEN=${HF_TOKEN:-}" \
    -e "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}" \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    "${IMAGE_TAG}"

log "Container '${CONTAINER_NAME}' started successfully."

# ---------------------------------------------------------------------------
# Wait for the llama.cpp health endpoint to become available
# ---------------------------------------------------------------------------
HEALTH_URL="http://localhost:${LLAMACPP_HOST_PORT}/health"
MODELS_URL="http://localhost:${LLAMACPP_HOST_PORT}/v1/models"
HEALTH_TIMEOUT="${LLAMACPP_HEALTH_TIMEOUT:-300}"
HEALTH_INTERVAL=5

log "Waiting for llama.cpp to become healthy (timeout: ${HEALTH_TIMEOUT}s) ..."

# ---------------------------------------------------------------------------
# Phase 1: Wait for /health to respond
# ---------------------------------------------------------------------------
log "Phase 1/2: Waiting for /health endpoint at ${HEALTH_URL} ..."

elapsed=0
while [ "${elapsed}" -lt "${HEALTH_TIMEOUT}" ]; do
    # Check container is still running
    container_state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "missing")
    if [ "${container_state}" = "exited" ] || [ "${container_state}" = "dead" ] || [ "${container_state}" = "missing" ]; then
        log "Container logs:"
        "${RUNTIME}" logs --tail 30 "${CONTAINER_NAME}" 2>&1 || true
        error "Container '${CONTAINER_NAME}' exited unexpectedly (state: ${container_state}). See logs above or run: ${RUNTIME} logs ${CONTAINER_NAME}"
    fi

    if curl -sf "${HEALTH_URL}" > /dev/null 2>&1; then
        log "/health endpoint is responding."
        break
    fi

    sleep "${HEALTH_INTERVAL}"
    elapsed=$((elapsed + HEALTH_INTERVAL))
    log "  ... waiting for /health (${elapsed}/${HEALTH_TIMEOUT}s)"
done

if [ "${elapsed}" -ge "${HEALTH_TIMEOUT}" ]; then
    warn "llama.cpp /health did not respond within ${HEALTH_TIMEOUT}s."
    warn "The container is still running — the model may still be loading."
    warn "Check progress with: ${RUNTIME} logs -f ${CONTAINER_NAME}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 2: Verify /v1/models returns the expected model
# ---------------------------------------------------------------------------
log "Phase 2/2: Verifying /v1/models endpoint lists '${MODEL_NAME}' ..."

MODELS_TIMEOUT=60  # Additional time after /health is up for model listing
models_elapsed=0

while [ "${models_elapsed}" -lt "${MODELS_TIMEOUT}" ]; do
    models_response=$(curl -sf --max-time 10 "${MODELS_URL}" 2>/dev/null || echo "")

    if [ -n "${models_response}" ]; then
        # Check if the response is valid JSON with model data
        model_check=$(echo "${models_response}" | python3 -c "
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
                log "/v1/models responded successfully."
                log "  Available models: ${models_listed}"

                if echo "${models_listed}" | grep -q "${MODEL_NAME}"; then
                    log "Expected model '${MODEL_NAME}' confirmed."
                else
                    warn "Expected model '${MODEL_NAME}' not found in model list."
                    warn "Available models: ${models_listed}"
                fi

                log ""
                log "llama.cpp server is healthy and ready to serve requests."
                log "  API endpoint: http://localhost:${LLAMACPP_HOST_PORT}/v1"
                log "  Models API  : ${MODELS_URL}"
                log "  Health check: ${HEALTH_URL}"
                exit 0
                ;;
            empty)
                # Models endpoint works but no models loaded yet
                ;;
            *)
                # Error parsing or no response
                ;;
        esac
    fi

    sleep "${HEALTH_INTERVAL}"
    models_elapsed=$((models_elapsed + HEALTH_INTERVAL))
    log "  ... waiting for /v1/models (${models_elapsed}/${MODELS_TIMEOUT}s)"
done

warn "llama.cpp /v1/models did not list any models within ${MODELS_TIMEOUT}s after /health became available."
warn "The server is running but the model may still be loading."
warn "Check with: curl ${MODELS_URL}"
warn "Check logs: ${RUNTIME} logs -f ${CONTAINER_NAME}"
exit 1
