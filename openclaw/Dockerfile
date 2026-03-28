# =============================================================================
# OpenClaw Container — Ubuntu 24.04 + Node.js + OpenClaw
# Configured to use vLLM as its LLM provider via OpenAI-compatible endpoint
# =============================================================================
FROM ubuntu:24.04

LABEL maintainer="democlaw"
LABEL description="OpenClaw AI assistant configured with vLLM backend"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Install system dependencies + Node.js
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install OpenClaw globally via npm
# ---------------------------------------------------------------------------
RUN npm install -g openclaw

# ---------------------------------------------------------------------------
# Create non-root user for running the application
# ---------------------------------------------------------------------------
RUN groupadd -r -g 1000 openclaw && useradd -r -u 1000 -g openclaw -m -s /bin/bash openclaw

# ---------------------------------------------------------------------------
# Application configuration
# ---------------------------------------------------------------------------
WORKDIR /app

# Copy configuration template, entrypoint, and healthcheck
COPY config.json /app/config/config.json
COPY entrypoint.sh /app/entrypoint.sh
COPY healthcheck.sh /app/healthcheck.sh
RUN chmod +x /app/entrypoint.sh /app/healthcheck.sh \
    && chown -R openclaw:openclaw /app

# ---------------------------------------------------------------------------
# Environment variables — defaults connect to vLLM container on shared network
#
# The entrypoint.sh script uses these to:
#   1. Generate /app/config/config.json with resolved values
#   2. Export OpenAI-compatible env vars (OPENAI_API_BASE, etc.)
#   3. Export OpenClaw-specific env vars (OPENCLAW_LLM_*)
#   4. Wait for vLLM readiness before starting OpenClaw
# ---------------------------------------------------------------------------
ENV VLLM_BASE_URL="http://vllm:8000/v1" \
    VLLM_API_KEY="EMPTY" \
    VLLM_MODEL_NAME="Qwen/Qwen3.5-9B-AWQ" \
    VLLM_MAX_TOKENS=4096 \
    VLLM_TEMPERATURE=0.7 \
    VLLM_HEALTH_RETRIES=60 \
    VLLM_HEALTH_INTERVAL=5 \
    OPENCLAW_PORT=18789 \
    OPENCLAW_CONFIG_DIR="/app/config" \
    OPENCLAW_CONFIG="/app/config/config.json" \
    OPENCLAW_HOST="0.0.0.0" \
    OPENAI_API_BASE="http://vllm:8000/v1" \
    OPENAI_BASE_URL="http://vllm:8000/v1" \
    OPENAI_API_KEY="EMPTY" \
    OPENAI_MODEL="Qwen/Qwen3.5-9B-AWQ" \
    OPENCLAW_LLM_PROVIDER="openai-compatible" \
    OPENCLAW_LLM_BASE_URL="http://vllm:8000/v1" \
    OPENCLAW_LLM_API_KEY="EMPTY" \
    OPENCLAW_LLM_MODEL="Qwen/Qwen3.5-9B-AWQ" \
    OPENCLAW_LLM_MAX_TOKENS=4096 \
    OPENCLAW_LLM_TEMPERATURE=0.7

# ---------------------------------------------------------------------------
# Switch to non-root user
# ---------------------------------------------------------------------------
USER openclaw

# Expose the OpenClaw dashboard port
EXPOSE 18789

# Healthcheck — verify the dashboard is responding and serving content
# Uses the dedicated healthcheck script that validates HTTP status AND HTML content
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/app/healthcheck.sh"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["openclaw", "serve", "--port", "18789", "--host", "0.0.0.0"]
