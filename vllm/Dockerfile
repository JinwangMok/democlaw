# =============================================================================
# vLLM Server Dockerfile
# Serves Qwen/Qwen3.5-9B-AWQ (AWQ 4-bit quantized) on NVIDIA GPU
#
# Base image: vllm/vllm-openai — official vLLM CUDA image (CUDA 12.x / Python 3.11)
# Includes: vLLM inference engine, autoawq, triton, torch, flash-attn, etc.
#
# Requirements (host):
#   - NVIDIA GPU with >= 8 GB VRAM (e.g. RTX 3070/4070, A10G, T4 16 GB)
#   - NVIDIA driver >= 525 (CUDA 12.x compatible)
#   - nvidia-container-toolkit (for Docker) or nvidia-ctk (for Podman/CDI)
# =============================================================================

FROM vllm/vllm-openai:v0.8.3

LABEL maintainer="democlaw"
LABEL description="vLLM OpenAI-compatible server for Qwen3.5-9B AWQ 4-bit"
LABEL org.opencontainers.image.title="democlaw-vllm"
LABEL org.opencontainers.image.description="Serves Qwen/Qwen3.5-9B-AWQ via the vLLM OpenAI-compatible API"

# ---------------------------------------------------------------------------
# Explicitly ensure AWQ dependencies are present.
# vllm/vllm-openai already ships autoawq; this step makes the dependency
# transparent and pins a minimum version for AWQ 4-bit quantised model support.
# ---------------------------------------------------------------------------
RUN pip install --no-cache-dir "autoawq>=0.2.7"

# ---------------------------------------------------------------------------
# Default runtime environment variables.
# All values are overridable at container start via --env / --env-file.
#
#   MODEL_NAME              — HuggingFace model ID (must be an AWQ variant)
#   VLLM_PORT               — Port the OpenAI-compatible API listens on
#   MAX_MODEL_LEN           — Maximum context length (tokens); keep <=8192 on 8 GB
#   GPU_MEMORY_UTILIZATION  — Fraction of GPU VRAM to reserve for the model
#   QUANTIZATION            — vLLM quantization backend (awq | gptq | none …)
#   DTYPE                   — Computation dtype (float16 recommended for AWQ)
#   HF_TOKEN                — HuggingFace access token (leave empty for public models)
#   HUGGINGFACE_HUB_VERBOSITY — Log level for hub download progress
#   VLLM_API_KEY            — Optional API key for the OpenAI-compatible endpoint.
#                             When set to a non-empty, non-"EMPTY", non-"none" value
#                             the server requires "Authorization: Bearer <key>".
#                             Leave empty (or set to "EMPTY") for no-auth mode.
# ---------------------------------------------------------------------------
ENV MODEL_NAME="Qwen/Qwen3.5-9B-AWQ" \
    VLLM_HOST="0.0.0.0" \
    VLLM_PORT="8000" \
    MAX_MODEL_LEN="8192" \
    GPU_MEMORY_UTILIZATION="0.90" \
    QUANTIZATION="awq" \
    DTYPE="float16" \
    HF_TOKEN="" \
    HUGGINGFACE_HUB_VERBOSITY="warning" \
    VLLM_API_KEY=""

# ---------------------------------------------------------------------------
# Model weights cache directory.
# Mount a host directory here to persist downloaded weights between runs
# and avoid re-downloading on every container start:
#
#   docker run … -v /data/hf-cache:/root/.cache/huggingface …
# ---------------------------------------------------------------------------
VOLUME ["/root/.cache/huggingface"]

# Expose the vLLM OpenAI-compatible API port
EXPOSE 8000

# ---------------------------------------------------------------------------
# Copy in-container helper scripts
# ---------------------------------------------------------------------------
COPY healthcheck.sh /opt/healthcheck.sh
COPY entrypoint.sh  /opt/entrypoint.sh
RUN chmod +x /opt/healthcheck.sh /opt/entrypoint.sh

# ---------------------------------------------------------------------------
# Healthcheck: verifies /health AND /v1/models respond correctly.
# start-period=300s accounts for model download + GPU load time on first run.
# ---------------------------------------------------------------------------
HEALTHCHECK --interval=15s --timeout=10s --start-period=300s --retries=12 \
    CMD ["/opt/healthcheck.sh"]

# Use exec-form ENTRYPOINT so environment variables are expanded at runtime
# (not build time) by the shell entrypoint script.
ENTRYPOINT ["/opt/entrypoint.sh"]
