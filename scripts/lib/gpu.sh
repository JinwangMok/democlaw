#!/usr/bin/env bash
# =============================================================================
# gpu.sh — Shared NVIDIA GPU and CUDA driver validation library
#
# Validates that the host has a working NVIDIA GPU with CUDA drivers and
# sufficient VRAM before any containers are launched. Fails fast with clear
# error messages if any prerequisite is missing.
#
# Source this file from any script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/gpu.sh"
#
# After sourcing, the following are available:
#   validate_nvidia_gpu()          — Full GPU/CUDA preflight check (exits on failure)
#   check_nvidia_smi()             — Verify nvidia-smi is installed and functional
#   check_cuda_driver()            — Verify CUDA driver is loaded
#   check_gpu_vram <min_mib>       — Verify GPU has at least <min_mib> MiB VRAM
#   check_nvidia_container_runtime — Verify nvidia-container-toolkit for the runtime
#   get_gpu_info()                 — Print detected GPU information
#
# All check functions exit with a clear error if the check fails.
# =============================================================================

# Guard against double-sourcing
if [ "${_GPU_LIB_LOADED:-}" = "true" ]; then
    return 0 2>/dev/null || true
fi
_GPU_LIB_LOADED="true"

# ---------------------------------------------------------------------------
# Logging helpers (only defined if not already set by the sourcing script)
# ---------------------------------------------------------------------------
if ! declare -f _gpu_log > /dev/null 2>&1; then
    _gpu_log()   { echo "[gpu] $*"; }
fi
if ! declare -f _gpu_warn > /dev/null 2>&1; then
    _gpu_warn()  { echo "[gpu] WARNING: $*" >&2; }
fi
if ! declare -f _gpu_error > /dev/null 2>&1; then
    _gpu_error() { echo "[gpu] ERROR: $*" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Minimum VRAM required for Qwen3.5-9B AWQ 4-bit (in MiB)
# ---------------------------------------------------------------------------
DEFAULT_MIN_VRAM_MIB=7500

# ---------------------------------------------------------------------------
# check_nvidia_smi — Verify nvidia-smi is installed and can communicate with GPU
#
# Checks:
#   1. nvidia-smi binary exists in PATH
#   2. nvidia-smi can successfully query the GPU driver
# ---------------------------------------------------------------------------
check_nvidia_smi() {
    _gpu_log "Checking for nvidia-smi ..."

    if ! command -v nvidia-smi > /dev/null 2>&1; then
        _gpu_error "nvidia-smi not found in PATH.

  The NVIDIA GPU driver is either not installed or not in your PATH.

  To fix this:
    1. Install the NVIDIA driver for your GPU:
         sudo apt install nvidia-driver-560   # Ubuntu/Debian
         sudo dnf install nvidia-driver       # Fedora/RHEL
    2. Install nvidia-container-toolkit:
         See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html
    3. Reboot and try again.
"
    fi

    if ! nvidia-smi > /dev/null 2>&1; then
        _gpu_error "nvidia-smi is installed but failed to communicate with the NVIDIA driver.

  Possible causes:
    - The NVIDIA kernel module is not loaded (try: sudo modprobe nvidia)
    - No NVIDIA GPU is physically present in this machine
    - The driver version is incompatible with the installed GPU
    - A recent kernel update requires a driver reinstall

  Diagnostic commands:
    lspci | grep -i nvidia     # Check if GPU hardware is detected
    dmesg | grep -i nvidia     # Check kernel messages for driver errors
    sudo modprobe nvidia       # Try loading the kernel module
"
    fi

    _gpu_log "nvidia-smi is available and functional."
}

# ---------------------------------------------------------------------------
# check_cuda_driver — Verify CUDA driver version is present and sufficient
#
# Parses the CUDA version from nvidia-smi output.
# vLLM requires CUDA >= 11.8 in practice.
# ---------------------------------------------------------------------------
check_cuda_driver() {
    _gpu_log "Checking CUDA driver version ..."

    local cuda_version
    cuda_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '[:space:]')

    if [ -z "${cuda_version}" ]; then
        _gpu_error "Could not determine NVIDIA driver version from nvidia-smi.

  Ensure the NVIDIA driver is properly installed and a GPU is accessible.
"
    fi

    _gpu_log "NVIDIA driver version: ${cuda_version}"

    # Also check the CUDA version reported by nvidia-smi
    local cuda_ver
    cuda_ver=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version:\s*\K[\d.]+' || echo "")

    if [ -z "${cuda_ver}" ]; then
        _gpu_warn "Could not parse CUDA version from nvidia-smi output."
        _gpu_warn "vLLM requires CUDA >= 11.8. Proceeding, but launch may fail."
    else
        _gpu_log "CUDA version: ${cuda_ver}"

        # Extract major version for a basic sanity check
        local cuda_major
        cuda_major=$(echo "${cuda_ver}" | cut -d. -f1)
        if [ "${cuda_major}" -lt 11 ]; then
            _gpu_error "CUDA version ${cuda_ver} is too old. vLLM requires CUDA >= 11.8.

  Update your NVIDIA driver to a version that supports CUDA >= 11.8.
  See: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/
"
        fi
    fi
}

# ---------------------------------------------------------------------------
# check_gpu_vram — Verify the GPU has sufficient VRAM
#
# Usage: check_gpu_vram [min_mib]
#   min_mib — minimum VRAM in MiB (default: 7500, i.e. ~8 GB for AWQ 4-bit)
# ---------------------------------------------------------------------------
check_gpu_vram() {
    local min_mib="${1:-${DEFAULT_MIN_VRAM_MIB}}"

    _gpu_log "Checking GPU VRAM (minimum required: ${min_mib} MiB) ..."

    local vram_mib
    vram_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '[:space:]')

    if [ -z "${vram_mib}" ]; then
        _gpu_error "Could not determine GPU VRAM. Ensure nvidia-smi is working correctly."
    fi

    _gpu_log "Detected GPU VRAM: ${vram_mib} MiB"

    if [ "${vram_mib}" -lt "${min_mib}" ]; then
        _gpu_error "Insufficient GPU VRAM: ${vram_mib} MiB detected, but ${min_mib} MiB required.

  Qwen3.5-9B AWQ 4-bit requires approximately 8 GB (8192 MiB) of VRAM.

  Options:
    - Use a GPU with at least 8 GB VRAM
    - Reduce MAX_MODEL_LEN in .env to lower memory usage
    - Use a smaller quantized model
"
    fi
}

# ---------------------------------------------------------------------------
# check_nvidia_container_runtime — Verify nvidia-container-toolkit is set up
#
# Usage: check_nvidia_container_runtime <runtime>
#   runtime — "docker" or "podman"
#
# For docker: checks that the NVIDIA runtime is registered.
# For podman: checks that nvidia-ctk (CDI generator) is available.
# ---------------------------------------------------------------------------
check_nvidia_container_runtime() {
    local runtime="${1:?container runtime name required}"

    _gpu_log "Checking NVIDIA container runtime support for '${runtime}' ..."

    if [ "${runtime}" = "docker" ]; then
        # Check if nvidia runtime is registered with docker
        if "${runtime}" info 2>/dev/null | grep -qi "nvidia"; then
            _gpu_log "NVIDIA runtime detected in docker configuration."
        else
            _gpu_warn "NVIDIA runtime not detected in 'docker info'."
            _gpu_warn "Ensure nvidia-container-toolkit is installed and configured:"
            _gpu_warn "  sudo nvidia-ctk runtime configure --runtime=docker"
            _gpu_warn "  sudo systemctl restart docker"
            _gpu_warn ""
            _gpu_warn "Attempting to proceed — --gpus flag may still work."
        fi
    elif [ "${runtime}" = "podman" ]; then
        if command -v nvidia-ctk > /dev/null 2>&1; then
            _gpu_log "nvidia-ctk found — CDI support available for podman."
        else
            _gpu_warn "nvidia-ctk not found in PATH."
            _gpu_warn "Ensure nvidia-container-toolkit is installed for podman GPU support:"
            _gpu_warn "  See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
            _gpu_warn ""
            _gpu_warn "Attempting to proceed — GPU passthrough may fail."
        fi

        # Check if CDI spec exists for NVIDIA
        local cdi_found=false
        if [ -f /etc/cdi/nvidia.yaml ]; then
            cdi_found=true
        elif [ -d /var/run/cdi ] && ls /var/run/cdi/nvidia*.yaml > /dev/null 2>&1; then
            cdi_found=true
        fi
        if [ "${cdi_found}" = "true" ]; then
            _gpu_log "NVIDIA CDI spec found."
        else
            _gpu_warn "No NVIDIA CDI spec found at /etc/cdi/nvidia.yaml."
            _gpu_warn "Generate it with: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
        fi
    fi
}

# ---------------------------------------------------------------------------
# get_gpu_info — Print a summary of detected GPU(s) for diagnostic purposes
# ---------------------------------------------------------------------------
get_gpu_info() {
    _gpu_log "=== GPU Information ==="
    nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.free,temperature.gpu \
        --format=csv,noheader 2>/dev/null | while IFS=',' read -r idx name driver mem_total mem_free temp; do
        _gpu_log "  GPU ${idx}: ${name} | Driver: ${driver} | VRAM: ${mem_total} MiB (${mem_free} MiB free) | Temp: ${temp}C"
    done
    _gpu_log "======================="
}

# ---------------------------------------------------------------------------
# validate_nvidia_gpu — Complete GPU/CUDA preflight validation
#
# Runs all checks in sequence:
#   1. nvidia-smi availability
#   2. CUDA driver version
#   3. GPU VRAM sufficiency
#   4. nvidia-container-toolkit for the active runtime
#
# Usage: validate_nvidia_gpu [runtime] [min_vram_mib]
#   runtime       — "docker" or "podman" (default: value of $RUNTIME if set)
#   min_vram_mib  — minimum VRAM in MiB (default: 7500)
#
# Exits immediately with a clear error if any check fails.
# ---------------------------------------------------------------------------
validate_nvidia_gpu() {
    local runtime="${1:-${RUNTIME:-}}"
    local min_vram="${2:-${DEFAULT_MIN_VRAM_MIB}}"

    _gpu_log "========================================="
    _gpu_log "  NVIDIA GPU / CUDA Preflight Check"
    _gpu_log "========================================="

    # Step 1: nvidia-smi must be present and working
    check_nvidia_smi

    # Step 2: CUDA driver version check
    check_cuda_driver

    # Step 3: VRAM check
    check_gpu_vram "${min_vram}"

    # Step 4: Container runtime GPU integration
    if [ -n "${runtime}" ]; then
        check_nvidia_container_runtime "${runtime}"
    else
        _gpu_warn "No container runtime specified — skipping container GPU integration check."
    fi

    # Print GPU summary
    get_gpu_info

    _gpu_log "========================================="
    _gpu_log "  GPU preflight checks PASSED"
    _gpu_log "========================================="
}
