#!/bin/sh
# =============================================================================
# entrypoint.sh — llama.cpp server startup script
#
# Launches the llama.cpp OpenAI-compatible API server using environment
# variables configured in the Dockerfile (overridable at container runtime).
#
# The script:
#   1. Downloads the GGUF model from HuggingFace if not already cached
#   2. Resolves API key / no-auth mode
#   3. Starts llama-server with tool/function calling support (--jinja)
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Download model if not present
# ---------------------------------------------------------------------------
_model_path="${MODEL_PATH:-/models/Qwen3.5-9B-Q4_K_M.gguf}"
_model_repo="${MODEL_REPO:-unsloth/Qwen3.5-9B-GGUF}"
_model_file="${MODEL_FILE:-Qwen3.5-9B-Q4_K_M.gguf}"
_model_alias="${MODEL_ALIAS:-Qwen3.5-9B-Q4_K_M}"

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
_ctx_size="${CTX_SIZE:-32768}"
_n_gpu_layers="${N_GPU_LAYERS:-99}"
_flash_attn="${FLASH_ATTN:-1}"
_cache_type_k="${CACHE_TYPE_K:-q8_0}"
_cache_type_v="${CACHE_TYPE_V:-q8_0}"

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
if [ "${_flash_attn}" = "1" ] || [ "${_flash_attn}" = "true" ]; then
    FLASH_ATTN_FLAG="--flash-attn"
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
