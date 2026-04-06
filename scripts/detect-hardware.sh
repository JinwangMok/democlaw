#!/usr/bin/env bash
# =============================================================================
# detect-hardware.sh — DGX Spark / consumer GPU hardware detection utility
#
# Identifies the deployment hardware by querying nvidia-smi for GPU device
# name and total memory, then returns a hardware profile used to select
# the appropriate Gemma 4 model variant:
#
#   HARDWARE_PROFILE=dgx_spark    -> Gemma 4 26B A4B MoE (128GB unified memory)
#   HARDWARE_PROFILE=consumer_gpu -> Gemma 4 E4B          (8GB VRAM)
#
# Detection strategy (in priority order):
#   1. Explicit override via HARDWARE_PROFILE environment variable
#   2. GPU device name matching (GH200, DGX)
#   3. System identifier files (/etc/dgx-release, NVIDIA DGX markers)
#   4. GPU memory threshold (>= 64 GB -> dgx_spark)
#   5. Fallback to consumer_gpu
#
# Usage:
#   Source this script to set HARDWARE_PROFILE and related variables:
#     source scripts/detect-hardware.sh
#
#   Or run standalone to print the detected profile:
#     bash scripts/detect-hardware.sh
#
# Outputs (when sourced):
#   HARDWARE_PROFILE       — "dgx_spark" or "consumer_gpu"
#   GPU_NAME               — GPU device name from nvidia-smi
#   GPU_TOTAL_VRAM_MIB     — Total GPU memory in MiB
#   HARDWARE_DETECT_METHOD — How the profile was determined
# =============================================================================

# ---------------------------------------------------------------------------
# Hardware profile constants (guard against re-source)
# ---------------------------------------------------------------------------
if [ -z "${PROFILE_DGX_SPARK+x}" ]; then
    readonly PROFILE_DGX_SPARK="dgx_spark"
    readonly PROFILE_CONSUMER_GPU="consumer_gpu"

    # Memory threshold: GPUs with >= 64 GiB (65536 MiB) are classified as DGX Spark.
    # The GH200 Grace Hopper in DGX Spark has 96-128 GB unified memory visible to CUDA.
    # Consumer GPUs top out at ~24 GB (RTX 4090), well below this threshold.
    readonly DGX_MEMORY_THRESHOLD_MIB=65536
fi

# ---------------------------------------------------------------------------
# Logging (matches project convention: [tag] message)
# ---------------------------------------------------------------------------
_hw_log()  { echo "[detect-hardware] $*"; }
_hw_warn() { echo "[detect-hardware] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# detect_gpu_info — populate GPU_NAME and GPU_TOTAL_VRAM_MIB
# ---------------------------------------------------------------------------
detect_gpu_info() {
    GPU_NAME=""
    GPU_TOTAL_VRAM_MIB=0

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        _hw_warn "nvidia-smi not found. Cannot detect GPU hardware."
        return 1
    fi

    # Query the first GPU's name and total memory (MiB)
    # Format: "NVIDIA GH200 120GB, 122880" or "NVIDIA GeForce RTX 4070, 8192"
    local gpu_query
    gpu_query=$(nvidia-smi --query-gpu=gpu_name,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1)

    if [ -z "${gpu_query}" ]; then
        _hw_warn "nvidia-smi returned empty GPU info."
        return 1
    fi

    # Parse CSV: name is everything before the last comma, memory is after
    GPU_NAME=$(echo "${gpu_query}" | sed 's/,[^,]*$//' | xargs)
    GPU_TOTAL_VRAM_MIB=$(echo "${gpu_query}" | awk -F',' '{print $NF}' | xargs)

    # Validate memory is numeric
    if ! echo "${GPU_TOTAL_VRAM_MIB}" | grep -qE '^[0-9]+$'; then
        _hw_warn "Could not parse GPU memory: '${GPU_TOTAL_VRAM_MIB}'"
        GPU_TOTAL_VRAM_MIB=0
    fi

    return 0
}

# ---------------------------------------------------------------------------
# check_dgx_system_identifiers — look for DGX-specific system files
# ---------------------------------------------------------------------------
check_dgx_system_identifiers() {
    # DGX systems have /etc/dgx-release or /etc/nv-* marker files
    if [ -f /etc/dgx-release ]; then
        return 0
    fi

    # Check for NVIDIA DGX in DMI product name (requires root or readable sysfs)
    if [ -f /sys/devices/virtual/dmi/id/product_name ]; then
        local product_name
        product_name=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)
        if echo "${product_name}" | grep -qi "DGX\|Spark"; then
            return 0
        fi
    fi

    # Check for DGX Spark specific identifier in board name
    if [ -f /sys/devices/virtual/dmi/id/board_name ]; then
        local board_name
        board_name=$(cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || true)
        if echo "${board_name}" | grep -qi "DGX\|Grace\|GH200\|GB10\|Blackwell\|Spark"; then
            return 0
        fi
    fi

    return 1
}

# ---------------------------------------------------------------------------
# check_gpu_name_match — match GPU name against known DGX Spark devices
# ---------------------------------------------------------------------------
check_gpu_name_match() {
    local name="${1}"

    # GH200 Grace Hopper Superchip
    if echo "${name}" | grep -qi "GH200"; then
        return 0
    fi

    # Grace Hopper variant names
    if echo "${name}" | grep -qi "Grace Hopper"; then
        return 0
    fi

    # Generic DGX GPU identifier
    if echo "${name}" | grep -qi "DGX"; then
        return 0
    fi

    # GB10 Grace Blackwell — DGX Spark desktop
    if echo "${name}" | grep -qi "GB10"; then
        return 0
    fi

    # Blackwell architecture (B100, B200, GB series)
    if echo "${name}" | grep -qi "Blackwell"; then
        return 0
    fi

    # DGX Spark specific identifiers
    if echo "${name}" | grep -qi "Spark"; then
        return 0
    fi

    # GB202 / Blackwell-based variants (future-proofing)
    if echo "${name}" | grep -qi "GB20[0-9]"; then
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# detect_hardware_profile — main detection logic
# ---------------------------------------------------------------------------
detect_hardware_profile() {
    # Always gather GPU info for diagnostics (best-effort)
    detect_gpu_info
    local gpu_ok=$?

    _hw_log "GPU name   : ${GPU_NAME:-unknown}"
    _hw_log "GPU memory : ${GPU_TOTAL_VRAM_MIB:-0} MiB"

    # Priority 1: Explicit override via environment variable
    if [ -n "${HARDWARE_PROFILE:-}" ]; then
        case "${HARDWARE_PROFILE}" in
            "${PROFILE_DGX_SPARK}" | "${PROFILE_CONSUMER_GPU}")
                HARDWARE_DETECT_METHOD="env_override"
                _hw_log "Using explicit HARDWARE_PROFILE=${HARDWARE_PROFILE} (env override)"
                return 0
                ;;
            *)
                _hw_warn "Invalid HARDWARE_PROFILE='${HARDWARE_PROFILE}'. Must be '${PROFILE_DGX_SPARK}' or '${PROFILE_CONSUMER_GPU}'."
                _hw_warn "Falling back to auto-detection."
                unset HARDWARE_PROFILE
                ;;
        esac
    fi

    # Priority 2: GPU device name matching
    if [ ${gpu_ok} -eq 0 ] && [ -n "${GPU_NAME}" ]; then
        if check_gpu_name_match "${GPU_NAME}"; then
            HARDWARE_PROFILE="${PROFILE_DGX_SPARK}"
            HARDWARE_DETECT_METHOD="gpu_name"
            _hw_log "Detected DGX Spark via GPU name: '${GPU_NAME}'"
            return 0
        fi
    fi

    # Priority 3: System identifier files (DGX release markers, DMI)
    if check_dgx_system_identifiers; then
        HARDWARE_PROFILE="${PROFILE_DGX_SPARK}"
        HARDWARE_DETECT_METHOD="system_id"
        _hw_log "Detected DGX Spark via system identifiers"
        return 0
    fi

    # Priority 4: GPU memory threshold
    if [ ${gpu_ok} -eq 0 ] && [ "${GPU_TOTAL_VRAM_MIB}" -ge "${DGX_MEMORY_THRESHOLD_MIB}" ] 2>/dev/null; then
        HARDWARE_PROFILE="${PROFILE_DGX_SPARK}"
        HARDWARE_DETECT_METHOD="gpu_memory"
        _hw_log "Detected DGX Spark via GPU memory: ${GPU_TOTAL_VRAM_MIB} MiB >= ${DGX_MEMORY_THRESHOLD_MIB} MiB threshold"
        return 0
    fi

    # Priority 5: Fallback to consumer GPU
    HARDWARE_PROFILE="${PROFILE_CONSUMER_GPU}"
    HARDWARE_DETECT_METHOD="fallback"
    _hw_log "No DGX Spark detected. Using consumer GPU profile."
    return 0
}

# ---------------------------------------------------------------------------
# print_hardware_summary — display detection results
# ---------------------------------------------------------------------------
print_hardware_summary() {
    _hw_log "========================================"
    _hw_log "  Hardware Detection Results"
    _hw_log "========================================"
    _hw_log "  Profile   : ${HARDWARE_PROFILE}"
    _hw_log "  GPU       : ${GPU_NAME:-unknown}"
    _hw_log "  VRAM      : ${GPU_TOTAL_VRAM_MIB:-0} MiB"
    _hw_log "  Method    : ${HARDWARE_DETECT_METHOD}"
    _hw_log "========================================"
}

# ---------------------------------------------------------------------------
# Main — run detection
# ---------------------------------------------------------------------------
# Save any incoming HARDWARE_PROFILE override before initialization
_incoming_profile="${HARDWARE_PROFILE:-}"

# Initialize output variables
HARDWARE_PROFILE="${_incoming_profile}"
GPU_NAME=""
GPU_TOTAL_VRAM_MIB=0
HARDWARE_DETECT_METHOD=""
unset _incoming_profile

detect_hardware_profile
print_hardware_summary

# If running standalone (not sourced), also export as env-file-compatible output
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo ""
    echo "# Hardware detection results (paste into .env or source this output):"
    echo "HARDWARE_PROFILE=${HARDWARE_PROFILE}"
    echo "GPU_NAME=\"${GPU_NAME}\""
    echo "GPU_TOTAL_VRAM_MIB=${GPU_TOTAL_VRAM_MIB}"
    echo "HARDWARE_DETECT_METHOD=${HARDWARE_DETECT_METHOD}"
fi
