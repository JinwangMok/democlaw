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

    _default LLM_ENGINE                "llamacpp"
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

# ---------------------------------------------------------------------------
# DGX Spark MODEL_DIR auto-resolution
#
# start.sh falls back to ${HOME}/.cache/democlaw/models when MODEL_DIR is
# unset, which lands on the root disk (often eMMC on DGX Spark) and cannot
# share a warm cache with sibling toolchains. Pick a sensible path without
# requiring the user to hand-edit .env:
#
#   1. Respect an existing MODEL_DIR (from .env / shell)
#   2. Reuse any existing Gemma 4 HF snapshot found on mounted filesystems
#      — this transparently shares the cache with e.g. dgx-spark-ai-cluster
#   3. First writable NVMe mount from /proc/mounts
#   4. /data/models if /data exists and is writable (DGX OS convention)
#   5. ${HOME}/.cache/democlaw/models (last resort, same as start.sh fallback)
#
# Only the _default() helper touches MODEL_DIR, so precedence is preserved:
# whatever the user sets explicitly wins over auto-detection.
# ---------------------------------------------------------------------------
_resolve_dgx_spark_model_dir() {
    if [ -n "${MODEL_DIR:-}" ]; then
        _profile_log "MODEL_DIR respected from environment: ${MODEL_DIR}"
        return 0
    fi

    # 1. Search for an existing Gemma 4 snapshot on common mount points.
    #    HF layout: <MODEL_DIR>/hub/models--google--gemma-4-26B-A4B-it/
    #
    # WARNING: On a k8s pod with a multi-TB /home/user or /var/lib/containers
    # backed by overlayfs, an unbounded find can stall for minutes. We:
    #   - prune known noisy trees (overlay, container storage, vcs, node_modules)
    #   - cap with `timeout` so a pathological filesystem can't hang startup
    #   - skip entirely when DEMOCLAW_SKIP_CACHE_SCAN=1 (escape hatch)
    #   - skip /var/lib (k8s / podman store) — never a useful cache location
    local found=""
    if [ "${DEMOCLAW_SKIP_CACHE_SCAN:-0}" != "1" ]; then
        local search_roots=(/data /mnt /srv /opt /workspace /scratch /fast /root /home)
        local -a existing_roots=()
        local r
        for r in "${search_roots[@]}"; do
            [ -d "${r}" ] && existing_roots+=("${r}")
        done

        if [ "${#existing_roots[@]}" -gt 0 ]; then
            if command -v timeout >/dev/null 2>&1; then
                found=$(timeout 3 find "${existing_roots[@]}" \
                    -xdev -maxdepth 5 \
                    \( -name proc -o -name sys -o -name .git -o -name node_modules \
                       -o -name overlay -o -name overlay2 -o -name containers \
                       -o -name docker -o -name .snapshots \) -prune -o \
                    -type d -name 'models--google--gemma-4-26B*' -print 2>/dev/null \
                    | head -1)
            else
                # Without `timeout`, skip the scan rather than risk hanging.
                _profile_log "'timeout' not available; skipping Gemma 4 cache scan."
            fi
        fi
    else
        _profile_log "Gemma 4 cache scan disabled via DEMOCLAW_SKIP_CACHE_SCAN=1."
    fi

    if [ -n "${found}" ]; then
        # hub/ is one level up from models--google--...; MODEL_DIR is its parent.
        local hub_dir parent
        hub_dir="$(dirname "${found}")"
        parent="$(dirname "${hub_dir}")"
        if [ -w "${parent}" ]; then
            MODEL_DIR="${parent}"
            _profile_log "MODEL_DIR auto-detected from existing Gemma 4 cache: ${MODEL_DIR}"
            return 0
        fi
        _profile_log "Found existing cache at ${parent} but it is not writable; skipping."
    fi

    # 2. First *usable* writable NVMe-backed mount from /proc/mounts.
    #
    # On bare-metal DGX OS this surfaces /data or /mnt/nvmeX. Inside a
    # Kubernetes pod it often surfaces a mix of /tmp, /home/user, /etc/*,
    # /var/lib/containers, etc. — we must filter the obviously-wrong ones
    # before grabbing the first survivor, otherwise a 50+ GB model would
    # land on tmpfs-like paths and thrash the node.
    #
    # Rejection rules:
    #   - single-file bind mounts (not directories) — e.g. /etc/hosts
    #   - ephemeral or system paths — /tmp, /etc, /dev, /var, /run, /proc,
    #     /sys, /boot, /efi
    #   - read-only filesystems
    #
    # After filtering, prefer a handful of well-known prefixes if available.
    _resolve_dgx_spark_model_dir_pick_nvme() {
        local src tgt rest
        local -a candidates=()
        local bad_re='^/(tmp|etc|dev|var|run|proc|sys|boot|efi)(/|$)'

        [ -r /proc/mounts ] || return 1

        while read -r src tgt rest; do
            case "${src}" in
                /dev/nvme*) ;;
                *) continue ;;
            esac
            [[ "${tgt}" =~ ${bad_re} ]] && continue
            [ -d "${tgt}" ] || continue
            [ -w "${tgt}" ] || continue
            candidates+=("${tgt}")
        done < /proc/mounts

        [ "${#candidates[@]}" -eq 0 ] && return 1

        # Preference order: explicit data/nvme/scratch first, then anything.
        local prefer
        for prefer in /data /mnt/nvme /mnt/data /scratch /fast /workspace /home/user /home; do
            local c
            for c in "${candidates[@]}"; do
                if [ "${c}" = "${prefer}" ] || [[ "${c}" == "${prefer}/"* ]]; then
                    printf '%s\n' "${c}"
                    return 0
                fi
            done
        done

        # No preferred match — return the first survivor.
        printf '%s\n' "${candidates[0]}"
        return 0
    }

    local nvme_mount
    nvme_mount=$(_resolve_dgx_spark_model_dir_pick_nvme || true)
    if [ -n "${nvme_mount}" ]; then
        MODEL_DIR="${nvme_mount%/}/democlaw/models"
        _profile_log "MODEL_DIR auto-selected on NVMe mount: ${MODEL_DIR}"
        unset -f _resolve_dgx_spark_model_dir_pick_nvme
        return 0
    fi
    unset -f _resolve_dgx_spark_model_dir_pick_nvme

    # 3. Well-known prefixes even without NVMe evidence (k8s pods may not
    #    expose /dev/nvme* in /proc/mounts when using CSI-backed PVCs).
    local prefer_dir
    for prefer_dir in /data /mnt/nvme /mnt/data /scratch /fast /workspace /home/user; do
        if [ -d "${prefer_dir}" ] && [ -w "${prefer_dir}" ]; then
            MODEL_DIR="${prefer_dir%/}/democlaw/models"
            _profile_log "MODEL_DIR auto-selected by preferred prefix: ${MODEL_DIR}"
            return 0
        fi
    done

    # 4. Last resort: let start.sh fall back to ${HOME}/.cache/democlaw/models.
    _profile_log "MODEL_DIR auto-detection found no fast-storage candidate."
    _profile_log "Will fall back to \${HOME}/.cache/democlaw/models in start.sh."
    return 0
}

# --- Gemma 4 26B A4B MoE (DGX Spark, 128GB unified memory) ----------------
_apply_dgx_spark_profile() {
    _profile_log "Applying profile: Gemma 4 26B A4B MoE (DGX Spark / 128GB)"

    # --- MODEL_DIR auto-resolution (must run before other defaults so later
    #     code can inspect the chosen path, e.g. for preflight size checks) ---
    _resolve_dgx_spark_model_dir

    # --- LLM Engine selection: vLLM for DGX Spark ---
    _default LLM_ENGINE                "vllm"

    # --- vLLM configuration (used when LLM_ENGINE=vllm) ---
    _default VLLM_IMAGE                "vllm/vllm-openai:gemma4-cu130"
    _default VLLM_MODEL_ID             "google/gemma-4-26B-A4B-it"
    _default VLLM_PORT                 "8000"
    _default VLLM_GPU_MEM_UTIL         "0.70"
    _default VLLM_QUANTIZATION         "fp8"
    _default VLLM_EXTRA_ARGS           "--kv-cache-dtype fp8 --load-format safetensors --enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4 --enable-prefix-caching --enable-chunked-prefill --max-num-seqs 4 --max-num-batched-tokens 8192"
    _default VLLM_MAX_MODEL_LEN        "262144"
    _default VLLM_HEALTH_TIMEOUT       "3600"

    # --- Common settings (used by OpenClaw regardless of engine) ---
    _default MODEL_NAME                "gemma-4-26B-A4B-it"
    _default MIN_VRAM_MIB              "16000"
    _default MIN_DRIVER_VERSION        "550.0"
    _default LLAMACPP_MODEL_NAME       "gemma-4-26B-A4B-it"
    _default LLAMACPP_MAX_TOKENS       "8192"
    _default LLAMACPP_TEMPERATURE      "0.7"

    # --- llama.cpp fallback settings (used when LLM_ENGINE=llamacpp) ---
    _default MODEL_REPO                "unsloth/gemma-4-26B-A4B-it-GGUF"
    _default MODEL_FILE                "gemma-4-26B-A4B-it-Q8_0.gguf"
    _default CTX_SIZE                  "262144"
    _default N_GPU_LAYERS              "99"
    _default FLASH_ATTN                "1"
    _default CACHE_TYPE_K              "q8_0"
    _default CACHE_TYPE_V              "q8_0"
    _default LLAMACPP_HEALTH_TIMEOUT   "1800"

    if [ "${LLM_ENGINE}" = "vllm" ]; then
        _profile_log "  Engine    : vLLM (FP8 online quantization)"
        _profile_log "  Image     : ${VLLM_IMAGE}"
        _profile_log "  Model     : ${VLLM_MODEL_ID}"
        _profile_log "  GPU mem   : ${VLLM_GPU_MEM_UTIL} (of 128GB unified)"
        _profile_log "  Context   : ${VLLM_MAX_MODEL_LEN} tokens"
    else
        _profile_log "  Engine    : llama.cpp (GGUF)"
        _profile_log "  Model     : ${MODEL_REPO}/${MODEL_FILE}"
        _profile_log "  Context   : ${CTX_SIZE} tokens"
        _profile_log "  KV cache  : K=${CACHE_TYPE_K}, V=${CACHE_TYPE_V}"
    fi
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
