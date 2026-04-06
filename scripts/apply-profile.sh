#!/usr/bin/env bash
# =============================================================================
# apply-profile.sh — Model/config selection logic for DemoClaw
#
# Maps a hardware profile (detected or explicit) to the appropriate Gemma 4
# model variant and runtime parameters. This is the bridge between hardware
# detection and container configuration.
#
# Profile mapping:
#   consumer_gpu / 8gb       -> Gemma 4 E4B Q4_K_M   (~3 GB, 8 GB VRAM)
#   dgx_spark    / dgx-spark -> Gemma 4 26B A4B MoE   (~16 GB, 128 GB unified)
#
# Precedence (highest to lowest):
#   1. Explicitly set environment variables (from .env or shell)
#   2. Profile-derived defaults (set by this script)
#   3. Hardcoded fallbacks (E4B / 8GB VRAM scenario)
#
# Usage:
#   Source this script AFTER loading .env but BEFORE using config values:
#     source scripts/apply-profile.sh
#
# Outputs (only sets variables that are not already defined):
#   MODEL_REPO, MODEL_FILE, MODEL_NAME, CTX_SIZE, N_GPU_LAYERS,
#   FLASH_ATTN, CACHE_TYPE_K, CACHE_TYPE_V, MIN_VRAM_MIB, MIN_DRIVER_VERSION,
#   LLAMACPP_MODEL_NAME, LLAMACPP_MAX_TOKENS, LLAMACPP_HEALTH_TIMEOUT
# =============================================================================

_profile_log() { echo "[apply-profile] $*"; }

# ---------------------------------------------------------------------------
# Step 1: Determine HARDWARE_PROFILE
#
# If HARDWARE_PROFILE is already set (from .env or environment), normalize it.
# Otherwise, run hardware detection to auto-detect.
# ---------------------------------------------------------------------------
_resolve_hardware_profile() {
    if [ -n "${HARDWARE_PROFILE:-}" ]; then
        # Normalize user-friendly aliases to canonical values
        case "${HARDWARE_PROFILE}" in
            8gb | consumer_gpu | consumer-gpu)
                HARDWARE_PROFILE="consumer_gpu"
                _profile_log "Hardware profile: consumer_gpu (from .env / environment)"
                ;;
            dgx-spark | dgx_spark | dgx)
                HARDWARE_PROFILE="dgx_spark"
                _profile_log "Hardware profile: dgx_spark (from .env / environment)"
                ;;
            *)
                _profile_log "WARNING: Unrecognized HARDWARE_PROFILE='${HARDWARE_PROFILE}'"
                _profile_log "  Valid values: 8gb, consumer_gpu, dgx-spark, dgx_spark"
                _profile_log "  Falling back to auto-detection ..."
                unset HARDWARE_PROFILE
                ;;
        esac
    fi

    # Auto-detect if not set (or was invalid and unset above)
    if [ -z "${HARDWARE_PROFILE:-}" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "${script_dir}/detect-hardware.sh" ]; then
            _profile_log "Running hardware auto-detection ..."
            # shellcheck source=detect-hardware.sh
            source "${script_dir}/detect-hardware.sh"
        else
            _profile_log "WARNING: detect-hardware.sh not found. Defaulting to consumer_gpu."
            HARDWARE_PROFILE="consumer_gpu"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Apply profile-specific defaults
#
# Each _apply_*_profile function sets defaults ONLY for variables that are
# not already set. This ensures .env overrides are respected.
# ---------------------------------------------------------------------------

# Helper: set a variable only if it is currently unset or empty
_default() {
    local var_name="$1"
    local default_value="$2"
    eval "local current_value=\"\${${var_name}:-}\""
    if [ -z "${current_value}" ]; then
        eval "${var_name}=\"${default_value}\""
    fi
}

# --- Gemma 4 E4B (consumer GPU, 8GB VRAM) ---------------------------------
_apply_consumer_gpu_profile() {
    _profile_log "Applying profile: Gemma 4 E4B (consumer GPU / 8GB VRAM)"

    _default MODEL_REPO                "unsloth/gemma-4-E4B-it-GGUF"
    _default MODEL_FILE                "gemma-4-E4B-it-Q4_K_M.gguf"
    _default MODEL_NAME                "gemma-4-E4B-it"
    _default CTX_SIZE                  "131072"
    _default N_GPU_LAYERS              "99"
    _default FLASH_ATTN                "1"
    _default CACHE_TYPE_K              "q4_0"
    _default CACHE_TYPE_V              "q4_0"
    _default MIN_VRAM_MIB              "7000"
    _default MIN_DRIVER_VERSION        "525.0"
    _default LLAMACPP_MODEL_NAME       "gemma-4-E4B-it"
    _default LLAMACPP_MAX_TOKENS       "4096"
    _default LLAMACPP_HEALTH_TIMEOUT   "600"
    _default LLAMACPP_TEMPERATURE      "0.7"

    _profile_log "  Model     : ${MODEL_REPO}/${MODEL_FILE}"
    _profile_log "  Context   : ${CTX_SIZE} tokens"
    _profile_log "  KV cache  : K=${CACHE_TYPE_K}, V=${CACHE_TYPE_V}"
    _profile_log "  Min VRAM  : ${MIN_VRAM_MIB} MiB"
}

# --- Gemma 4 26B A4B MoE (DGX Spark, 128GB unified memory) ----------------
_apply_dgx_spark_profile() {
    _profile_log "Applying profile: Gemma 4 26B A4B MoE (DGX Spark / 128GB)"

    _default MODEL_REPO                "unsloth/gemma-4-26B-A4B-it-GGUF"
    _default MODEL_FILE                "gemma-4-26B-A4B-it-Q4_K_M.gguf"
    _default MODEL_NAME                "gemma-4-26B-A4B-it"
    _default CTX_SIZE                  "262144"
    _default N_GPU_LAYERS              "99"
    _default FLASH_ATTN                "1"
    _default CACHE_TYPE_K              "q8_0"
    _default CACHE_TYPE_V              "q8_0"
    _default MIN_VRAM_MIB              "16000"
    _default MIN_DRIVER_VERSION        "550.0"
    _default LLAMACPP_MODEL_NAME       "gemma-4-26B-A4B-it"
    _default LLAMACPP_MAX_TOKENS       "8192"
    _default LLAMACPP_HEALTH_TIMEOUT   "900"
    _default LLAMACPP_TEMPERATURE      "0.7"

    _profile_log "  Model     : ${MODEL_REPO}/${MODEL_FILE}"
    _profile_log "  Context   : ${CTX_SIZE} tokens"
    _profile_log "  KV cache  : K=${CACHE_TYPE_K}, V=${CACHE_TYPE_V}"
    _profile_log "  Min VRAM  : ${MIN_VRAM_MIB} MiB"
}

# ---------------------------------------------------------------------------
# Step 3: Main — resolve profile and apply config
# ---------------------------------------------------------------------------
apply_hardware_profile() {
    _profile_log "========================================"
    _profile_log "  Model/Config Selection"
    _profile_log "========================================"

    _resolve_hardware_profile

    case "${HARDWARE_PROFILE}" in
        dgx_spark)
            _apply_dgx_spark_profile
            ;;
        consumer_gpu | *)
            _apply_consumer_gpu_profile
            ;;
    esac

    _profile_log "========================================"
}

# Run automatically when sourced
apply_hardware_profile
