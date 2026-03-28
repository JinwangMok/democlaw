# =============================================================================
# OpenClaw Container — Ubuntu 24.04 + Node.js + OpenClaw
# Configured to use vLLM as its LLM provider via OpenAI-compatible endpoint
#
# Build arguments (all overridable via --build-arg):
#   NODE_MAJOR           — Node.js major version to install (default: 20)
#   OPENCLAW_NPM_VERSION — npm package version/tag to install (default: latest)
#   VLLM_BASE_URL        — default vLLM backend URL   (default: http://vllm:8000/v1)
#   VLLM_MODEL_NAME      — default model name          (default: Qwen/Qwen3-4B-AWQ)
#   OPENCLAW_PORT        — port the dashboard listens on (default: 18789)
#   VERSION              — image version label          (default: dev)
#   BUILD_DATE           — ISO-8601 build timestamp     (default: unknown)
#   GIT_COMMIT           — short git SHA                (default: unknown)
# =============================================================================

# ---------------------------------------------------------------------------
# Build-time arguments — all have safe defaults for direct docker/podman build
# ---------------------------------------------------------------------------
ARG NODE_MAJOR=20
ARG OPENCLAW_NPM_VERSION=latest
ARG VLLM_BASE_URL=http://vllm:8000/v1
ARG VLLM_MODEL_NAME=Qwen/Qwen3-4B-AWQ
ARG OPENCLAW_PORT=18789
ARG VERSION=dev
ARG BUILD_DATE=unknown
ARG GIT_COMMIT=unknown

FROM ubuntu:24.04

# Re-declare ARGs after FROM so they are visible in this build stage
ARG NODE_MAJOR
ARG OPENCLAW_NPM_VERSION
ARG VLLM_BASE_URL
ARG VLLM_MODEL_NAME
ARG OPENCLAW_PORT
ARG VERSION
ARG BUILD_DATE
ARG GIT_COMMIT

LABEL maintainer="democlaw"
LABEL description="OpenClaw AI assistant configured with vLLM backend"
LABEL org.opencontainers.image.title="democlaw-openclaw"
LABEL org.opencontainers.image.description="OpenClaw AI assistant configured with vLLM backend"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
LABEL org.opencontainers.image.source="https://github.com/democlaw/democlaw"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.vendor="democlaw"
LABEL democlaw.node-major="${NODE_MAJOR}"
LABEL democlaw.vllm-url="${VLLM_BASE_URL}"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Install system dependencies + Node.js (version controlled by NODE_MAJOR ARG)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install OpenClaw globally via npm (version controlled by OPENCLAW_NPM_VERSION ARG)
# ---------------------------------------------------------------------------
RUN npm install -g --no-fund --no-audit "openclaw@${OPENCLAW_NPM_VERSION}" \
    && npm cache clean --force

# ---------------------------------------------------------------------------
# Create non-root user for running the application
# ---------------------------------------------------------------------------
RUN if id -u openclaw >/dev/null 2>&1; then \
        echo "User openclaw already exists"; \
    elif id -u 1000 >/dev/null 2>&1; then \
        echo "UID 1000 taken by $(id -un 1000), renaming to openclaw"; \
        usermod -l openclaw -d /home/openclaw -m "$(id -un 1000)"; \
        groupmod -n openclaw "$(id -gn 1000)"; \
    else \
        groupadd -g 1000 openclaw && \
        useradd -u 1000 -g openclaw -m -s /bin/bash openclaw; \
    fi

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
ENV NODE_ENV="production" \
    VLLM_BASE_URL="http://vllm:8000/v1" \
    VLLM_API_KEY="EMPTY" \
    VLLM_MODEL_NAME="Qwen/Qwen3-4B-AWQ" \
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
    OPENAI_MODEL="Qwen/Qwen3-4B-AWQ" \
    OPENCLAW_LLM_PROVIDER="openai-compatible" \
    OPENCLAW_LLM_BASE_URL="http://vllm:8000/v1" \
    OPENCLAW_LLM_API_KEY="EMPTY" \
    OPENCLAW_LLM_MODEL="Qwen/Qwen3-4B-AWQ" \
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
# No default CMD args — the entrypoint resolves OPENCLAW_PORT / OPENCLAW_HOST
# from env vars and starts OpenClaw automatically.
# To override (e.g. for debugging):  docker run --rm -it <image> bash
CMD []
