# vLLM Server Dockerfile
# Serves Qwen3.5-9B AWQ 4-bit quantized model on NVIDIA GPU
# Requires: NVIDIA GPU with >= 8GB VRAM, nvidia-container-toolkit installed

FROM vllm/vllm-openai:v0.8.3

LABEL maintainer="democlaw"
LABEL description="vLLM OpenAI-compatible server for Qwen3.5-9B AWQ 4-bit"

# Default environment variables (overridable at runtime via --env / .env)
ENV MODEL_NAME="Qwen/Qwen3.5-9B-AWQ" \
    VLLM_PORT="8000" \
    MAX_MODEL_LEN="8192" \
    GPU_MEMORY_UTILIZATION="0.90" \
    QUANTIZATION="awq" \
    DTYPE="float16"

# Expose the vLLM OpenAI-compatible API port
EXPOSE 8000

# Copy the in-container healthcheck and startup scripts
COPY healthcheck.sh /opt/healthcheck.sh
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/healthcheck.sh /opt/entrypoint.sh

# Healthcheck: verifies both /health and /v1/models endpoints
# start-period accounts for model download + load time on first run
HEALTHCHECK --interval=15s --timeout=10s --start-period=180s --retries=10 \
    CMD ["/opt/healthcheck.sh"]

# Use exec-form ENTRYPOINT so that env vars are expanded by the shell script
# at runtime (not build time), keeping the Dockerfile hadolint-compliant.
ENTRYPOINT ["/opt/entrypoint.sh"]
