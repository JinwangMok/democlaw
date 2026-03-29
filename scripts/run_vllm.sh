#!/usr/bin/env bash
# =============================================================================
# run_vllm.sh — Launch the vLLM container with NVIDIA GPU passthrough serving
#               Qwen3-4B AWQ 4-bit via an OpenAI-compatible API.
#
# Supports both docker and podman on Linux hosts.
# Requires: NVIDIA GPU with >= 8 GB VRAM, nvidia-container-toolkit installed.
#
# What this script does:
#   1. Validate host OS (Linux only)
#   2. Detect container runtime (docker or podman)
#   3. Validate NVIDIA GPU / CUDA prerequisites — exits with clear error if absent
#   4. Create shared container network if it does not already exist
#   5. Build the vLLM image if not already present
#   6. Pre-pull Qwen3-4B AWQ 4-bit model weights from HuggingFace
#        • Uses huggingface-cli on the host if available (preferred)
#        • Falls back to a temporary vLLM container if CLI not found
#        • Idempotent: skips download if weights already cached locally
#        • Set SKIP_MODEL_PULL=true to bypass entirely
#   7. Launch the vLLM container with:
#        • NVIDIA GPU passthrough (--gpus all / --device nvidia.com/gpu=all)
#        • Qwen/Qwen3-4B-AWQ model (AWQ 4-bit quantization)
#        • OpenAI-compatible API server bound to a configurable host port
#
# Usage:
#   ./scripts/run_vllm.sh                            # auto-detect runtime, port 8000
#   VLLM_HOST_PORT=9000 ./scripts/run_vllm.sh        # expose API on host port 9000
#   CONTAINER_RUNTIME=podman ./scripts/run_vllm.sh   # force podman
#   SKIP_MODEL_PULL=true ./scripts/run_vllm.sh       # skip model download (cached)
#   MODEL_NAME=Qwen/Qwen3-4B-AWQ ./scripts/run_vllm.sh
#
# Key environment variables (all have sensible defaults):
#   CONTAINER_RUNTIME       docker | podman  (auto-detected if unset)
#   MODEL_NAME              HuggingFace model ID          (default: Qwen/Qwen3-4B-AWQ)
#   QUANTIZATION            vLLM quantization method      (default: awq)
#   DTYPE                   Weight data type              (default: float16)
#   MAX_MODEL_LEN           Context window size (tokens)  (default: 8192)
#   GPU_MEMORY_UTILIZATION  0.0–1.0 GPU fraction          (default: 0.90)
#   VLLM_HOST               API bind address in container (default: 0.0.0.0)
#   VLLM_PORT               API port inside container     (default: 8000)
#   VLLM_HOST_PORT          API port published on host    (default: 8000)
#   VLLM_CONTAINER_NAME     Container name                (default: democlaw-vllm)
#   VLLM_IMAGE_TAG          Image tag to build/use        (default: democlaw/vllm:latest)
#   DEMOCLAW_NETWORK        Shared network name           (default: democlaw-net)
#   HF_CACHE_DIR            Host-side HuggingFace cache   (default: ~/.cache/huggingface)
#   HF_TOKEN                HuggingFace token (gated models only)
#   SKIP_MODEL_PULL         Set to "true" to skip model download (default: false)
#
# The OpenAI-compatible API will be available at:
#   http://localhost:<VLLM_HOST_PORT>/v1
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate project root and scripts directory
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { echo "[run_vllm] $*"; }
warn()  { echo "[run_vllm] WARNING: $*" >&2; }
error() { printf "[run_vllm] ERROR: %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load .env file if present (key=value, one per line; no export needed here)
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
# Configurable defaults
# All values can be overridden by environment variables or .env file.
# ---------------------------------------------------------------------------

# --- Model ---
# Qwen3-4B AWQ 4-bit — the only model variant that fits in 8 GB VRAM.
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-4B-AWQ}"
QUANTIZATION="${QUANTIZATION:-awq}"
DTYPE="${DTYPE:-float16}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"

# --- API server (configurable) ---
# VLLM_HOST      : bind address inside the container (0.0.0.0 = all interfaces)
# VLLM_PORT      : port the API server listens on inside the container
# VLLM_HOST_PORT : port published on the Linux host for external access
# VLLM_API_KEY   : optional API key for the OpenAI-compatible endpoint.
#                  Leave empty (or "EMPTY") for no-auth mode.
#                  Set to a real secret to require Authorization: Bearer <key>.
VLLM_HOST="${VLLM_HOST:-0.0.0.0}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_HOST_PORT="${VLLM_HOST_PORT:-8000}"
VLLM_API_KEY="${VLLM_API_KEY:-}"

# --- Model pull ---
# Set SKIP_MODEL_PULL=true to bypass the weight download step (e.g. weights
# are already present in HF_CACHE_DIR from a previous run).
SKIP_MODEL_PULL="${SKIP_MODEL_PULL:-false}"

# --- Container / image ---
CONTAINER_NAME="${VLLM_CONTAINER_NAME:-democlaw-vllm}"
IMAGE_TAG="${VLLM_IMAGE_TAG:-docker.io/jinwangmok/democlaw-vllm:v1.0.0}"
NETWORK_NAME="${DEMOCLAW_NETWORK:-democlaw-net}"

# --- HuggingFace model cache ---
# Mount the host cache into the container so weights are not re-downloaded
# on every run. The directory is created automatically if it does not exist.
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"

# ---------------------------------------------------------------------------
# Step 0: Linux-only guard
# This stack requires the NVIDIA container toolkit which is Linux-exclusive.
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
    error "Linux host required (detected: $(uname -s)).
  The NVIDIA container toolkit and GPU passthrough support used by this stack
  are only available on Linux. macOS and Windows are not supported."
fi

log "Host OS: Linux $(uname -r)"

# ---------------------------------------------------------------------------
# Step 1: Detect container runtime (docker or podman)
# Delegates to the shared runtime detection library which:
#   • Respects the CONTAINER_RUNTIME override
#   • Auto-detects docker (preferred) then podman
#   • Sets RUNTIME and RUNTIME_IS_PODMAN
#   • Exposes runtime_gpu_flags() helper
# ---------------------------------------------------------------------------
# Redirect lib logging through our prefix
_rt_log()   { log "$@"; }
_rt_warn()  { warn "$@"; }
_rt_error() { error "$@"; }

# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

log "Container runtime: ${RUNTIME} (podman=${RUNTIME_IS_PODMAN})"

# ---------------------------------------------------------------------------
# Step 2: Validate NVIDIA GPU and CUDA prerequisites
#
# validate_nvidia_gpu() checks:
#   1. nvidia-smi is installed and can communicate with the kernel driver
#   2. At least one physical NVIDIA GPU is enumerated
#   3. NVIDIA driver version >= 520.0 (needed for CUDA >= 11.8)
#   4. CUDA version >= 11.8 (required by vLLM >= 0.3)
#   5. GPU has sufficient VRAM for the AWQ 4-bit model (~8 GB)
#   6. nvidia-container-toolkit is installed and configured for this runtime
#
# If any check fails the script exits immediately with a clear error message
# describing the problem and the steps needed to fix it.
# ---------------------------------------------------------------------------
# Redirect gpu lib logging through our prefix
_gpu_log()   { log "$@"; }
_gpu_warn()  { warn "$@"; }
_gpu_error() { error "$@"; }

# shellcheck source=lib/gpu.sh
source "${SCRIPT_DIR}/lib/gpu.sh"

validate_nvidia_gpu "${RUNTIME}"

# ---------------------------------------------------------------------------
# Step 3: Ensure the shared container network exists
#
# Both the vLLM container and the OpenClaw container attach to this network
# so that OpenClaw can reach vLLM by hostname (http://vllm:8000/v1).
#
# runtime_ensure_network() from lib/runtime.sh handles this idempotently:
#   - Creates the network if it does not yet exist
#   - Silently succeeds if the network already exists
# Works identically on docker and podman.
# ---------------------------------------------------------------------------
log "Ensuring shared network '${NETWORK_NAME}' exists ..."
runtime_ensure_network "${NETWORK_NAME}"

# ---------------------------------------------------------------------------
# Step 4: Handle existing container (idempotent destroy-and-recreate)
#
# Every run must produce an identical end-state. Any pre-existing container
# — running, stopped, paused, or dead — is unconditionally removed so a
# fresh container is always created with the latest configuration.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Idempotent container teardown: ALWAYS destroy and recreate.
# This ensures every run produces an identical end-state regardless of prior
# state — running, stopped, paused, or dead containers are all removed.
# ---------------------------------------------------------------------------
if "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
    container_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

    log "Removing existing container '${CONTAINER_NAME}' (state: ${container_state}) for fresh recreation ..."
    "${RUNTIME}" rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Step 5: Acquire vLLM image (pull from Docker Hub first; local build fallback)
#
# Strategy: Always attempt to pull the pre-built image from Docker Hub.
# If pull fails (non-zero exit), fall back to building from the local
# Dockerfile at <project_root>/vllm/Dockerfile.
# ---------------------------------------------------------------------------
_img_log()   { log "$@"; }
_img_warn()  { warn "$@"; }
_img_error() { error "$@"; }
source "${SCRIPT_DIR}/lib/image.sh"

ensure_image "${IMAGE_TAG}" "${PROJECT_ROOT}/vllm"

# Ensure the HuggingFace cache directory exists on the host
mkdir -p "${HF_CACHE_DIR}"

# ---------------------------------------------------------------------------
# Source checksum library for model integrity verification
# ---------------------------------------------------------------------------
_cksum_log()   { log "$@"; }
_cksum_warn()  { warn "$@"; }
_cksum_error() { echo "[run_vllm] ERROR: $*" >&2; }

# shellcheck source=lib/checksum.sh
source "${SCRIPT_DIR}/lib/checksum.sh"

# ---------------------------------------------------------------------------
# Step 6: Pre-pull Qwen3-4B AWQ 4-bit model weights from HuggingFace
#
# Two-strategy approach (first succeeds wins):
#   1. huggingface-cli on the host    — preferred; no extra container needed
#   2. Temporary container (vLLM image) — fallback; guarantees correct tooling
#
# Checksum-verified idempotency:
#   1. Before download: check existing files against stored .sha256 checksums
#   2. If ALL checksums match → skip download entirely (verified cache hit)
#   3. If any mismatch or missing → proceed with (re-)download
#   4. After download: compute and store new .sha256 sidecar files
#
# To skip this step entirely (e.g. weights pre-cached on a shared NFS path):
#   SKIP_MODEL_PULL=true ./scripts/run_vllm.sh
# ---------------------------------------------------------------------------
pull_model_weights() {
    if [ "${SKIP_MODEL_PULL}" = "true" ]; then
        log "SKIP_MODEL_PULL=true — skipping model download (assuming weights cached)."
        return 0
    fi

    log "======================================================="
    log "  Step: Pull Qwen3-4B AWQ 4-bit model weights"
    log "  Model     : ${MODEL_NAME}"
    log "  Cache dir : ${HF_CACHE_DIR}"
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

    log "First-run download is ~5 GB. Subsequent runs with verified checksums will skip instantly."

    # ------------------------------------------------------------------
    # Strategy 1: huggingface-cli present on the host.
    # Preferred path — no extra container launch required.
    # ------------------------------------------------------------------
    local download_succeeded=false

    if command -v huggingface-cli > /dev/null 2>&1; then
        log "huggingface-cli found on host — using CLI download ..."

        if HF_HOME="${HF_CACHE_DIR}" \
            huggingface-cli download \
                "${MODEL_NAME}" \
                --ignore-patterns "*.pt" "*.bin" \
                --local-dir-use-symlinks False; then
            log "Model weights downloaded successfully."
            download_succeeded=true
        else
            log "huggingface-cli download failed — falling back to container method ..."
        fi
    fi

    # ------------------------------------------------------------------
    # Strategy 2: Short-lived vLLM container.
    # Uses the same image that will serve inference, so the Python /
    # huggingface_hub versions are guaranteed to be compatible.
    # ------------------------------------------------------------------
    if [ "${download_succeeded}" = "false" ]; then
        log "Downloading model weights via temporary vLLM container ..."

        local hf_token_flags=""
        if [ -n "${HF_TOKEN:-}" ]; then
            hf_token_flags="-e HF_TOKEN=${HF_TOKEN} -e HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}"
        fi

        # SC2086: GPU_FLAGS and hf_token_flags must word-split into separate args.
        # shellcheck disable=SC2086,SC2046
        "${RUNTIME}" run --rm \
            --name "democlaw-vllm-pull" \
            $(runtime_gpu_flags) \
            --shm-size 1g \
            -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
            -e "HF_HUB_DISABLE_PROGRESS_BARS=0" \
            ${hf_token_flags} \
            "${IMAGE_TAG}" \
            python3 -c "
import sys, os

model_name = '${MODEL_NAME}'
cache = os.environ.get('HF_HOME', os.path.expanduser('~/.cache/huggingface'))
print(f'[pull] Model : {model_name}')
print(f'[pull] Cache : {cache}')

try:
    from huggingface_hub import snapshot_download

    print('[pull] Downloading AWQ 4-bit weights (this may take several minutes) ...')
    local_path = snapshot_download(
        repo_id=model_name,
        ignore_patterns=['*.pt', '*.bin'],   # prefer safetensors
    )
    print(f'[pull] Download complete. Weights stored at: {local_path}')

except ImportError as exc:
    print(f'[pull] huggingface_hub not available: {exc}', file=sys.stderr)
    print('[pull] vLLM will attempt to download the model on first start.', file=sys.stderr)
    sys.exit(0)
except Exception as exc:
    print(f'[pull] Download failed: {exc}', file=sys.stderr)
    sys.exit(1)
"
    fi

    # ------------------------------------------------------------------
    # Post-download: store checksums for all model files
    # These .sha256 sidecars enable checksum-verified skipping on next run.
    # ------------------------------------------------------------------
    log "Storing checksums for downloaded model files ..."
    checksum_store_model_cache "${HF_CACHE_DIR}" "${MODEL_NAME}" || {
        warn "Failed to store model checksums. Download will not be skipped on next run."
    }

    log "Model pre-pull complete."
    log "======================================================="
}

pull_model_weights

# ---------------------------------------------------------------------------
# Step 7: Resolve GPU passthrough flags for the active runtime
#
# runtime_gpu_flags() is provided by lib/runtime.sh:
#   docker  → --gpus all               (nvidia-container-toolkit OCI hook)
#   podman >= 4 → --device nvidia.com/gpu=all  (CDI)
#   podman < 4  → --device /dev/nvidia0 ...    (raw device nodes)
# ---------------------------------------------------------------------------
GPU_FLAGS=$(runtime_gpu_flags)

# ---------------------------------------------------------------------------
# Step 8: Launch the vLLM container
#
# Key flags explained:
#   -d                          Run detached (background)
#   --name                      Container name for log/stop/inspect access
#   --network / --network-alias Attach to shared network; reachable as "vllm"
#   ${GPU_FLAGS}                NVIDIA GPU passthrough (runtime-specific)
#   --restart unless-stopped    Auto-restart on failure (not on explicit stop)
#   --shm-size 1g               Shared memory for PyTorch tensor operations
#   -p ${VLLM_HOST_PORT}:...    Publish API port on the Linux host
#   -v ${HF_CACHE_DIR}:...      Bind-mount HuggingFace model cache
#   -e MODEL_NAME               Qwen/Qwen3-4B-AWQ — AWQ 4-bit model ID
#   -e QUANTIZATION             awq — activates vLLM AWQ 4-bit kernel path
#   -e VLLM_HOST                Bind address inside the container (0.0.0.0)
#   -e VLLM_PORT                Container-internal API server port
#   --cap-drop ALL              Drop all Linux capabilities (minimal surface)
#   --security-opt no-new-privileges  Prevent privilege escalation
# ---------------------------------------------------------------------------
log "======================================================="
log "  Launching vLLM container"
log "======================================================="
_auth_mode_log="no-auth (any client may call the API)"
if [ -n "${VLLM_API_KEY:-}" ] && [ "${VLLM_API_KEY}" != "EMPTY" ] && [ "${VLLM_API_KEY}" != "none" ]; then
    _auth_mode_log="api-key (clients must send Authorization: Bearer <key>)"
fi

log "  Container  : ${CONTAINER_NAME}"
log "  Image      : ${IMAGE_TAG}"
log "  Model      : ${MODEL_NAME}"
log "  Quant      : ${QUANTIZATION} (AWQ 4-bit)"
log "  dtype      : ${DTYPE}"
log "  Max len    : ${MAX_MODEL_LEN} tokens"
log "  GPU mem    : ${GPU_MEMORY_UTILIZATION} utilization"
log "  Bind addr  : ${VLLM_HOST}:${VLLM_PORT}  (0.0.0.0 = reachable from all containers)"
log "  API port   : host:${VLLM_HOST_PORT} -> container:${VLLM_PORT}"
log "  Network    : ${NETWORK_NAME} (alias: vllm)"
log "  Auth mode  : ${_auth_mode_log}"
log "  GPU flags  : ${GPU_FLAGS}"
log "  HF cache   : ${HF_CACHE_DIR}"
log "======================================================="

# Compose the optional HF_TOKEN env flag (omit the -e flag entirely when empty
# to avoid passing a blank token string to the container).
HF_TOKEN_FLAGS=""
if [ -n "${HF_TOKEN:-}" ]; then
    HF_TOKEN_FLAGS="-e HF_TOKEN=${HF_TOKEN} -e HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}"
fi

# SC2086: intentional word-splitting for GPU_FLAGS and HF_TOKEN_FLAGS — these
# expand to multiple whitespace-separated flags, not a single argument.
# shellcheck disable=SC2086
"${RUNTIME}" run -d \
    --name "${CONTAINER_NAME}" \
    --network "${NETWORK_NAME}" \
    --hostname vllm \
    --network-alias vllm \
    ${GPU_FLAGS} \
    --restart unless-stopped \
    --shm-size 1g \
    -p "${VLLM_HOST_PORT}:${VLLM_PORT}" \
    -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
    -e "MODEL_NAME=${MODEL_NAME}" \
    -e "VLLM_HOST=${VLLM_HOST}" \
    -e "VLLM_PORT=${VLLM_PORT}" \
    -e "VLLM_API_KEY=${VLLM_API_KEY:-}" \
    -e "MAX_MODEL_LEN=${MAX_MODEL_LEN}" \
    -e "GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}" \
    -e "QUANTIZATION=${QUANTIZATION}" \
    -e "DTYPE=${DTYPE}" \
    ${HF_TOKEN_FLAGS} \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    "${IMAGE_TAG}"

log "Container '${CONTAINER_NAME}' started."
log ""
log "The vLLM OpenAI-compatible API will be available at:"
log "  http://localhost:${VLLM_HOST_PORT}/v1"
log ""
log "The model (${MODEL_NAME}) takes several minutes to load on first start."
log "Monitor progress with:"
log "  ${RUNTIME} logs -f ${CONTAINER_NAME}"
log ""
log "Once loaded, verify the API with:"
log "  curl http://localhost:${VLLM_HOST_PORT}/health"
log "  curl http://localhost:${VLLM_HOST_PORT}/v1/models"
log ""
log "To stop the container:"
log "  ${RUNTIME} stop ${CONTAINER_NAME}"
