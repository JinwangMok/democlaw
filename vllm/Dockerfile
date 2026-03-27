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

# Copy the in-container healthcheck script
COPY healthcheck.sh /opt/healthcheck.sh
RUN chmod +x /opt/healthcheck.sh

# Healthcheck: verifies both /health and /v1/models endpoints
# start-period accounts for model download + load time on first run
HEALTHCHECK --interval=15s --timeout=10s --start-period=180s --retries=10 \
    CMD ["/opt/healthcheck.sh"]

# Use shell form so environment variables are expanded at runtime
ENTRYPOINT []
CMD python3 -m vllm.entrypoints.openai.api_server \
    --model "$MODEL_NAME" \
    --quantization "$QUANTIZATION" \
    --dtype "$DTYPE" \
    --max-model-len "$MAX_MODEL_LEN" \
    --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
    --port "$VLLM_PORT" \
    --trust-remote-code \
    --enforce-eager
