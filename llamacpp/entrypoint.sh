#!/bin/sh
# =============================================================================
# entrypoint.sh — llama.cpp server startup script
#
# Launches the llama.cpp OpenAI-compatible API server using environment
# variables configured in the Dockerfile (overridable at container runtime).
#
# The script:
#   1. Detects hardware and selects the appropriate Gemma 4 model variant
#      (if MODEL_FILE is not already set via environment / .env)
#   2. Downloads the GGUF model from HuggingFace if not already cached
#   3. Resolves API key / no-auth mode
#   4. Starts llama-server with tool/function calling support (--jinja)
#
# Hardware-aware model selection (when env vars are not explicitly set):
#   - DGX Spark (>=64GB VRAM):  Gemma 4 26B A4B MoE (Q4_K_M, 128k context)
#   - Consumer GPU (<64GB VRAM): Gemma 4 E4B (Q4_K_M, 8k context)
#
# The detection runs ONLY when MODEL_FILE is at its Dockerfile default.
# Explicit environment variables (via docker run -e or --env-file) always win.
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Hardware detection and model selection (in-container)
#
# When launching the container without explicit model config (bare docker run),
# detect the GPU and select the appropriate Gemma 4 variant automatically.
# This mirrors the host-side detect-hardware.sh / apply-profile.sh logic
# but runs inside the container where nvidia-smi is available via the
# NVIDIA Container Toolkit device mount.
# ---------------------------------------------------------------------------
_detect_and_apply_profile() {
    echo "[entrypoint] Running in-container hardware detection ..."

    _gpu_name=""
    _gpu_vram_mib=0
    _detected_profile="consumer_gpu"
    _detect_method="fallback"

    # Query GPU info via nvidia-smi (available inside container via nvidia-container-toolkit)
    if command -v nvidia-smi >/dev/null 2>&1; then
        _gpu_query=$(nvidia-smi --query-gpu=gpu_name,memory.total \
            --format=csv,noheader,nounits 2>/dev/null | head -1)

        if [ -n "${_gpu_query}" ]; then
            # Parse CSV: name before last comma, memory after
            _gpu_name=$(echo "${_gpu_query}" | sed 's/,[^,]*$//' | xargs)
            _gpu_vram_mib=$(echo "${_gpu_query}" | awk -F',' '{print $NF}' | xargs)

            # Validate memory is numeric
            if ! echo "${_gpu_vram_mib}" | grep -qE '^[0-9]+$'; then
                _gpu_vram_mib=0
            fi
        fi
    fi

    echo "[entrypoint] GPU detected: ${_gpu_name:-unknown} (${_gpu_vram_mib} MiB)"

    # Check for HARDWARE_PROFILE env override first
    if [ -n "${HARDWARE_PROFILE:-}" ]; then
        case "${HARDWARE_PROFILE}" in
            dgx_spark | dgx-spark | dgx)
                _detected_profile="dgx_spark"
                _detect_method="env_override"
                ;;
            consumer_gpu | consumer-gpu | 8gb)
                _detected_profile="consumer_gpu"
                _detect_method="env_override"
                ;;
        esac
    # GPU name matching (GH200, Grace Hopper, DGX)
    elif echo "${_gpu_name}" | grep -qiE "GH200|Grace.Hopper|DGX|GB20[0-9]"; then
        _detected_profile="dgx_spark"
        _detect_method="gpu_name"
    # DGX system identifiers
    elif [ -f /etc/dgx-release ]; then
        _detected_profile="dgx_spark"
        _detect_method="system_id"
    # Memory threshold: >= 64 GiB (65536 MiB)
    elif [ "${_gpu_vram_mib}" -ge 65536 ] 2>/dev/null; then
        _detected_profile="dgx_spark"
        _detect_method="gpu_memory"
    fi

    echo "[entrypoint] Hardware profile: ${_detected_profile} (via ${_detect_method})"

    # Apply profile-specific defaults for any unset variables
    if [ "${_detected_profile}" = "dgx_spark" ]; then
        echo "[entrypoint] Applying DGX Spark profile: Gemma 4 26B A4B MoE"
        MODEL_REPO="${MODEL_REPO:-unsloth/gemma-4-26B-A4B-it-GGUF}"
        MODEL_FILE="${MODEL_FILE:-gemma-4-26B-A4B-it-Q4_K_M.gguf}"
        MODEL_ALIAS="${MODEL_ALIAS:-gemma-4-26B-A4B-it}"
        CTX_SIZE="${CTX_SIZE:-262144}"
        N_GPU_LAYERS="${N_GPU_LAYERS:-99}"
        FLASH_ATTN="${FLASH_ATTN:-1}"
        CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
        CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"
    else
        echo "[entrypoint] Applying consumer GPU profile: Gemma 4 E4B"
        MODEL_REPO="${MODEL_REPO:-unsloth/gemma-4-E4B-it-GGUF}"
        MODEL_FILE="${MODEL_FILE:-gemma-4-E4B-it-Q4_K_M.gguf}"
        MODEL_ALIAS="${MODEL_ALIAS:-gemma-4-E4B-it}"
        CTX_SIZE="${CTX_SIZE:-131072}"
        N_GPU_LAYERS="${N_GPU_LAYERS:-99}"
        FLASH_ATTN="${FLASH_ATTN:-1}"
        CACHE_TYPE_K="${CACHE_TYPE_K:-q4_0}"
        CACHE_TYPE_V="${CACHE_TYPE_V:-q4_0}"
    fi

    # Derive MODEL_PATH from MODEL_FILE (always under /models/)
    MODEL_PATH="${MODEL_PATH:-/models/${MODEL_FILE}}"
}

# ---------------------------------------------------------------------------
# Determine if we should run hardware detection.
#
# The Dockerfile sets ENV defaults for MODEL_FILE etc., so they are always
# "set" inside the container. We use a sentinel variable AUTO_DETECT_MODEL
# to control behavior:
#   AUTO_DETECT_MODEL=1 (or unset) -> run detection, override Dockerfile defaults
#   AUTO_DETECT_MODEL=0            -> skip detection, trust existing env vars
#
# When start.sh passes explicit -e MODEL_FILE=... the user can also set
# AUTO_DETECT_MODEL=0 to suppress detection.
# ---------------------------------------------------------------------------
_auto_detect="${AUTO_DETECT_MODEL:-1}"

if [ "${_auto_detect}" = "1" ] || [ "${_auto_detect}" = "true" ] || [ "${_auto_detect}" = "on" ]; then
    # Temporarily unset Dockerfile defaults so detection can apply profile defaults.
    # If start.sh already passed explicit values via -e, those are re-read from
    # the process environment AFTER we unset the shell variables, because the
    # shell expands ${VAR:-default} from the process env, not shell-only vars.
    #
    # We save any explicitly-passed overrides (non-Dockerfile-default values)
    # by checking if the current value differs from the known Dockerfile default.
    _dockerfile_default_file="gemma-4-E4B-it-Q4_K_M.gguf"

    if [ "${MODEL_FILE}" = "${_dockerfile_default_file}" ]; then
        # MODEL_FILE is the Dockerfile default — it may or may not have been
        # explicitly passed. Unset and let detection decide.
        unset MODEL_FILE MODEL_REPO MODEL_ALIAS MODEL_PATH
    fi
    # If MODEL_FILE differs from the Dockerfile default, it was explicitly set
    # by the user — keep it and skip detection.

    if [ -z "${MODEL_FILE:-}" ]; then
        _detect_and_apply_profile
    fi
fi

# ---------------------------------------------------------------------------
# Resolve final model configuration (with safe fallbacks)
# ---------------------------------------------------------------------------
_model_repo="${MODEL_REPO:-unsloth/gemma-4-E4B-it-GGUF}"
_model_file="${MODEL_FILE:-gemma-4-E4B-it-Q4_K_M.gguf}"
_model_alias="${MODEL_ALIAS:-gemma-4-E4B-it}"
_model_path="${MODEL_PATH:-/models/${_model_file}}"

if [ ! -f "${_model_path}" ]; then
    echo "[entrypoint] Model not found at ${_model_path}"
    echo "[entrypoint] Downloading ${_model_file} from ${_model_repo} ..."

    _hf_url="https://huggingface.co/${_model_repo}/resolve/main/${_model_file}"
    echo "[entrypoint] URL: ${_hf_url}"

    # Download with resume support
    curl -L --retry 3 --retry-delay 5 \
        -o "${_model_path}.tmp" \
        -C - \
        "${_hf_url}"

    mv "${_model_path}.tmp" "${_model_path}"
    echo "[entrypoint] Model download complete: ${_model_path}"
else
    echo "[entrypoint] Model found at ${_model_path}"
fi

# Verify model file exists and has non-zero size
if [ ! -s "${_model_path}" ]; then
    echo "[entrypoint] ERROR: Model file is empty or missing: ${_model_path}" >&2
    exit 1
fi

_model_size=$(stat -c%s "${_model_path}" 2>/dev/null || stat -f%z "${_model_path}" 2>/dev/null || echo "unknown")
echo "[entrypoint] Model file size: ${_model_size} bytes"

# ---------------------------------------------------------------------------
# Resolve API key / no-auth mode
# ---------------------------------------------------------------------------
_api_key="${LLAMA_API_KEY:-}"
API_KEY_ARGS=""

case "${_api_key}" in
    "" | EMPTY | none | no-auth )
        echo "[entrypoint] API authentication: DISABLED (no-auth mode)"
        ;;
    *)
        API_KEY_ARGS="--api-key ${_api_key}"
        echo "[entrypoint] API authentication: ENABLED (api-key set)"
        ;;
esac

# ---------------------------------------------------------------------------
# Resolve configuration
# ---------------------------------------------------------------------------
_host="${LLAMA_HOST:-0.0.0.0}"
_port="${LLAMA_PORT:-8000}"
_ctx_size="${CTX_SIZE:-131072}"
_n_gpu_layers="${N_GPU_LAYERS:-99}"
_flash_attn="${FLASH_ATTN:-1}"
_cache_type_k="${CACHE_TYPE_K:-q4_0}"
_cache_type_v="${CACHE_TYPE_V:-q4_0}"

echo "[entrypoint] Binding llama.cpp OpenAI-compatible API server:"
echo "[entrypoint]   Host       : ${_host} (0.0.0.0 = reachable from all containers)"
echo "[entrypoint]   Port       : ${_port}"
echo "[entrypoint]   Model      : ${_model_path}"
echo "[entrypoint]   Context    : ${_ctx_size}"
echo "[entrypoint]   GPU layers : ${_n_gpu_layers}"
echo "[entrypoint]   Flash attn : ${_flash_attn}"
echo "[entrypoint]   KV cache K : ${_cache_type_k}"
echo "[entrypoint]   KV cache V : ${_cache_type_v}"
echo "[entrypoint]   Alias      : ${_model_alias}"
echo "[entrypoint]   Tool calls : ENABLED (--jinja)"

# ---------------------------------------------------------------------------
# Build flash-attn flag
# ---------------------------------------------------------------------------
FLASH_ATTN_FLAG=""
if [ "${_flash_attn}" = "1" ] || [ "${_flash_attn}" = "true" ] || [ "${_flash_attn}" = "on" ]; then
    FLASH_ATTN_FLAG="--flash-attn on"
elif [ "${_flash_attn}" = "auto" ]; then
    FLASH_ATTN_FLAG="--flash-attn auto"
fi

# ---------------------------------------------------------------------------
# Launch the llama.cpp OpenAI-compatible API server
#
#   --host              Bind address (0.0.0.0 → reachable from containers)
#   --port              TCP port to listen on
#   --model             Path to GGUF model file
#   --ctx-size          Maximum context length (tokens)
#   --n-gpu-layers      Number of layers to offload to GPU (99 = all)
#   --flash-attn        Enable flash attention (saves VRAM)
#   --cache-type-k/v    KV cache quantization type
#   --jinja             Enable Jinja2 template processing for tool/function calls
#   --chat-template-file (optional) Custom chat template
#   --api-key           (Optional) Require Bearer token auth
# ---------------------------------------------------------------------------
# SC2086: intentional — API_KEY_ARGS and FLASH_ATTN_FLAG expand to zero or more words.
# shellcheck disable=SC2086
exec llama-server \
    --host "${_host}" \
    --port "${_port}" \
    --model "${_model_path}" \
    --alias "${_model_alias}" \
    --ctx-size "${_ctx_size}" \
    --n-gpu-layers "${_n_gpu_layers}" \
    ${FLASH_ATTN_FLAG} \
    --cache-type-k "${_cache_type_k}" \
    --cache-type-v "${_cache_type_v}" \
    --jinja \
    ${API_KEY_ARGS}
