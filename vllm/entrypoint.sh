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
#   - Easy addition of pre-start logic if needed in the future
# =============================================================================
set -e

exec python3 -m vllm.entrypoints.openai.api_server \
    --model "${MODEL_NAME}" \
    --quantization "${QUANTIZATION}" \
    --dtype "${DTYPE}" \
    --max-model-len "${MAX_MODEL_LEN}" \
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
    --port "${VLLM_PORT}" \
    --trust-remote-code \
    --enforce-eager
