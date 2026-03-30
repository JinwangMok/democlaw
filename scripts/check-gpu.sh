#!/usr/bin/env bash
# =============================================================================
# check-gpu.sh — Standalone NVIDIA GPU and CUDA driver preflight validation
#
# Validates that the host meets all hardware and driver prerequisites for
# running the DemoClaw stack (llama.cpp + Qwen3-4B AWQ 4-bit on NVIDIA GPU).
#
# Run this script BEFORE launching containers to confirm your GPU setup is
# ready. The main start scripts (start.sh, start-llamacpp.sh) also call this
# validation automatically before launching any containers.
#
# Checks performed:
#   1. Linux host OS verification
#   2. nvidia-smi is available and can communicate with the driver
#   3. At least one physical NVIDIA GPU device is detected
#   4. NVIDIA driver version meets minimum (>= 520.0 for CUDA 11.8)
#   5. CUDA version meets minimum (>= 11.8, required by llama.cpp)
#   6. GPU VRAM meets minimum (>= 7500 MiB for Qwen3-4B AWQ 4-bit)
#   7. nvidia-container-toolkit is configured for the detected runtime
#
# Exit codes:
#   0  All checks passed — the host is ready to run the DemoClaw stack
#   1  One or more checks failed — see error output for remediation steps
#
# Usage:
#   ./scripts/check-gpu.sh
#   CONTAINER_RUNTIME=podman ./scripts/check-gpu.sh
#   MIN_VRAM_MIB=8192 ./scripts/check-gpu.sh
#
# Environment overrides:
#   CONTAINER_RUNTIME  — force "docker" or "podman" (default: auto-detect)
#   MIN_VRAM_MIB       — override minimum VRAM in MiB (default: 7500)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script and project directories
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { echo "[check-gpu] $*"; }
warn()  { echo "[check-gpu] WARNING: $*" >&2; }
error() {
    printf "[check-gpu] ERROR: %s\n" "$*" >&2
    exit 1
}

# Override library logging to use our prefix
_rt_log()    { log "$@"; }
_rt_warn()   { warn "$@"; }
_rt_error()  { error "$@"; }
_gpu_log()   { log "$@"; }
_gpu_warn()  { warn "$@"; }
_gpu_error() { error "$@"; }

# ---------------------------------------------------------------------------
# Load .env file if present so that any overrides (e.g. MIN_VRAM_MIB) apply
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
# Verify Linux host OS
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
    error "This script requires a Linux host (detected: $(uname -s)).
  DemoClaw requires a Linux host with an NVIDIA GPU.
  macOS and Windows hosts are not supported."
fi

log "Host OS: $(uname -s) $(uname -r)"

# ---------------------------------------------------------------------------
# Source the shared runtime detection library
# Detects docker or podman automatically.
# ---------------------------------------------------------------------------
# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

log "Container runtime : ${RUNTIME}"
log "Podman mode       : ${RUNTIME_IS_PODMAN}"

# ---------------------------------------------------------------------------
# Source the GPU validation library and run the full preflight check
#
# validate_nvidia_gpu() runs the following checks in sequence:
#   1. check_nvidia_smi        — nvidia-smi present and functional
#   2. check_gpu_hardware      — at least one physical GPU enumerated
#   3. check_cuda_driver       — driver >= MIN_DRIVER_VERSION, CUDA >= MIN_CUDA_VERSION
#   4. check_gpu_vram          — VRAM >= MIN_VRAM_MIB
#   5. check_nvidia_container_runtime — container toolkit configured for runtime
#
# Any failed check calls _gpu_error() which prints a detailed, actionable
# error message and exits immediately with code 1.
# ---------------------------------------------------------------------------
# shellcheck source=lib/gpu.sh
source "${SCRIPT_DIR}/lib/gpu.sh"

# Allow override of minimum VRAM via environment (default defined in gpu.sh)
MIN_VRAM_MIB="${MIN_VRAM_MIB:-${DEFAULT_MIN_VRAM_MIB}}"

log ""
validate_nvidia_gpu "${RUNTIME}" "${MIN_VRAM_MIB}"

# ---------------------------------------------------------------------------
# All checks passed — print a summary and exit successfully
# ---------------------------------------------------------------------------
log ""
log "============================================================"
log "  GPU preflight PASSED — host is ready for DemoClaw"
log "============================================================"
log ""
log "  Next step: start the DemoClaw stack with:"
log "    ./scripts/start.sh"
log ""
log "  Or start services individually:"
log "    ./scripts/start-llamacpp.sh  # llama.cpp model server"
log "    ./scripts/start-openclaw.sh # OpenClaw assistant UI"
log ""
exit 0
