#!/bin/sh
# =============================================================================
# entrypoint.sh — vLLM server startup script
#
# Launches the vLLM OpenAI-compatible API server using environment variables
# configured in the Dockerfile (overridable at container runtime via --env).
#
# Using a shell script entrypoint instead of a shell-form CMD allows:
#   - Environment variable expansion at runtime (not build time)
#   - Exec-form ENTRYPOINT in the Dockerfile (hadolint-compliant)
#   - Optional HF_TOKEN propagation for gated HuggingFace models
#   - Easy extension with pre-start logic without rebuilding the image
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Propagate HuggingFace token if provided (needed for gated/private models).
# The HUGGING_FACE_HUB_TOKEN variable is the canonical name recognised by the
# huggingface_hub library used internally by vLLM for model downloads.
# ---------------------------------------------------------------------------
if [ -n "${HF_TOKEN:-}" ]; then
    export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
fi

# ---------------------------------------------------------------------------
# Resolve API key / no-auth mode.
#
# VLLM_API_KEY controls authentication for the OpenAI-compatible endpoint:
#
#   Unset / empty / "EMPTY" / "none" / "no-auth":
#       The server runs in NO-AUTH mode — every request is accepted regardless
#       of the Authorization header. This is the default for internal use on
#       a trusted container network.
#
#   Any other value (e.g. "mysecretkey123"):
#       The server requires "Authorization: Bearer <VLLM_API_KEY>" on every
#       request. Clients (e.g. OpenClaw) must send this header.
#
# The API is always bound to 0.0.0.0 (VLLM_HOST) so it is reachable from
# other containers on the shared network via the "vllm" hostname, e.g.:
#   http://vllm:8000/v1
# ---------------------------------------------------------------------------
_api_key="${VLLM_API_KEY:-}"

case "${_api_key}" in
    "" | EMPTY | none | no-auth )
        # No-auth mode — accept all requests without credentials
        API_KEY_ARGS=""
        echo "[entrypoint] API authentication: DISABLED (no-auth mode)"
        ;;
    *)
        # API key mode — require Authorization: Bearer <key>
        API_KEY_ARGS="--api-key ${_api_key}"
        echo "[entrypoint] API authentication: ENABLED (api-key set)"
        ;;
esac

# ---------------------------------------------------------------------------
# Report bind configuration so it is visible in container logs.
# This confirms the endpoint is 0.0.0.0-bound and reachable from the network.
# ---------------------------------------------------------------------------
_host="${VLLM_HOST:-0.0.0.0}"
_port="${VLLM_PORT:-8000}"
echo "[entrypoint] Binding vLLM OpenAI-compatible API server:"
echo "[entrypoint]   Host : ${_host}  (0.0.0.0 = reachable from all containers)"
echo "[entrypoint]   Port : ${_port}"
echo "[entrypoint]   Model: ${MODEL_NAME}"
echo "[entrypoint]   Quant: ${QUANTIZATION} (AWQ 4-bit)"

# ---------------------------------------------------------------------------
# Launch the vLLM OpenAI-compatible API server.
#
#   --host                   Bind address (0.0.0.0 → reachable from containers)
#   --port                   TCP port to listen on
#   --model                  HuggingFace model ID or local path
#   --quantization           Quantization method (awq for AWQ 4-bit)
#   --dtype                  Compute dtype for non-quantized weights
#   --max-model-len          Maximum sequence length (tokens)
#   --gpu-memory-utilization Fraction of VRAM to dedicate to the KV cache
#   --trust-remote-code      Required by some community / Qwen model configs
#   --enforce-eager          Disable CUDA graph capture (saves VRAM on 8 GB GPUs)
#   --api-key                (Optional) Require Bearer token auth on all requests.
#                            Omitted in no-auth mode (VLLM_API_KEY unset/EMPTY).
# ---------------------------------------------------------------------------
# SC2086: intentional — API_KEY_ARGS expands to zero or two words.
# shellcheck disable=SC2086
exec python3 -m vllm.entrypoints.openai.api_server \
    --host "${_host}" \
    --port "${_port}" \
    --model "${MODEL_NAME}" \
    --quantization "${QUANTIZATION}" \
    --dtype "${DTYPE}" \
    --max-model-len "${MAX_MODEL_LEN}" \
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
    --trust-remote-code \
    --enforce-eager \
    --enable-auto-tool-choice \
    --tool-call-parser hermes \
    ${API_KEY_ARGS}
