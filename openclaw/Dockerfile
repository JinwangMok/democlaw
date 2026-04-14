# =============================================================================
# OpenClaw Container — Ubuntu 24.04 + Node.js + OpenClaw (Headless)
# Configured to use llama.cpp as its LLM provider via OpenAI-compatible endpoint
#
# HEADLESS CONFIGURATION — no GUI, no VNC, no browser automation
# Process supervision: s6-overlay
# Developer tools: Python 3.13 (uv), npm, sudo, Homebrew
#
# Build arguments (all overridable via --build-arg):
#   NODE_MAJOR           — Node.js major version to install (default: 22)
#   OPENCLAW_NPM_VERSION — npm package version/tag to install (default: latest)
#   LLAMACPP_BASE_URL    — default llama.cpp backend URL   (default: http://llamacpp:8000/v1)
#   LLAMACPP_MODEL_NAME  — default model name          (default: gemma-4-E4B-it)
#   OPENCLAW_PORT        — port the dashboard listens on (default: 18789)
#   VERSION              — image version label          (default: dev)
#   BUILD_DATE           — ISO-8601 build timestamp     (default: unknown)
#   GIT_COMMIT           — short git SHA                (default: unknown)
# =============================================================================

# ---------------------------------------------------------------------------
# Build-time arguments — all have safe defaults for direct docker/podman build
# ---------------------------------------------------------------------------
ARG NODE_MAJOR=22
ARG OPENCLAW_NPM_VERSION=2026.4.12
ARG LLAMACPP_BASE_URL=http://llamacpp:8000/v1
ARG LLAMACPP_MODEL_NAME=gemma-4-E4B-it
ARG OPENCLAW_PORT=18789
ARG VERSION=dev
ARG BUILD_DATE=unknown
ARG GIT_COMMIT=unknown
ARG S6_OVERLAY_VERSION=3.2.0.2

FROM docker.io/ubuntu:24.04

# Re-declare ARGs after FROM so they are visible in this build stage
ARG NODE_MAJOR
ARG OPENCLAW_NPM_VERSION
ARG LLAMACPP_BASE_URL
ARG LLAMACPP_MODEL_NAME
ARG OPENCLAW_PORT
ARG VERSION
ARG BUILD_DATE
ARG GIT_COMMIT
ARG S6_OVERLAY_VERSION
ARG TARGETARCH

LABEL maintainer="democlaw"
LABEL description="OpenClaw AI headless assistant with llama.cpp backend"
LABEL org.opencontainers.image.title="democlaw-openclaw"
LABEL org.opencontainers.image.description="OpenClaw AI headless assistant with llama.cpp backend"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
LABEL org.opencontainers.image.source="https://github.com/JinwangMok/democlaw"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.vendor="democlaw"
LABEL democlaw.node-major="${NODE_MAJOR}"
LABEL democlaw.llamacpp-url="${LLAMACPP_BASE_URL}"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Install system dependencies + Node.js (headless — no GUI packages)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        xz-utils \
        sudo \
        build-essential \
        procps \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install s6-overlay for process supervision (~3 MB, arm64-compatible)
# ---------------------------------------------------------------------------
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && rm /tmp/s6-overlay-noarch.tar.xz

RUN case "${TARGETARCH}" in \
        amd64) S6_ARCH=x86_64 ;; \
        arm64) S6_ARCH=aarch64 ;; \
        *)     S6_ARCH="${TARGETARCH}" ;; \
    esac \
    && curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
        -o /tmp/s6-overlay-arch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz \
    && rm /tmp/s6-overlay-arch.tar.xz

# ---------------------------------------------------------------------------
# Install OpenClaw globally via npm (version controlled by OPENCLAW_NPM_VERSION ARG)
# ---------------------------------------------------------------------------
RUN npm install -g --no-fund --no-audit "openclaw@${OPENCLAW_NPM_VERSION}" supergateway \
    && cd "$(npm root -g)/openclaw" \
    && npm install --no-fund --no-audit --omit=dev \
    && (test -f scripts/postinstall-bundled-plugins.mjs \
        && node scripts/postinstall-bundled-plugins.mjs \
        || echo "WARN: postinstall-bundled-plugins.mjs not found, skipping") \
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
# Passwordless sudo for openclaw user
# ---------------------------------------------------------------------------
RUN echo "openclaw ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw \
    && chmod 0440 /etc/sudoers.d/openclaw

# ---------------------------------------------------------------------------
# Install uv + Python 3.13 (accessible to all users via /opt/python)
# ---------------------------------------------------------------------------
ENV UV_PYTHON_INSTALL_DIR=/opt/python
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh \
    && /usr/local/bin/uv python install 3.13 \
    && PYTHON3="$(/usr/local/bin/uv python find 3.13)" \
    && ln -sf "${PYTHON3}" /usr/local/bin/python3 \
    && rm -f "$(dirname "${PYTHON3}")/../lib/python3.13/EXTERNALLY-MANAGED" \
    && curl -sSL https://bootstrap.pypa.io/get-pip.py | "${PYTHON3}" \
    && ln -sf "$(dirname "${PYTHON3}")/pip3" /usr/local/bin/pip3 \
    && ln -sf /usr/local/bin/pip3 /usr/local/bin/pip \
    && chmod -R a+rX /opt/python

# ---------------------------------------------------------------------------
# Install Homebrew (Linuxbrew) — must run as non-root user
# ---------------------------------------------------------------------------
USER openclaw
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
USER root
RUN echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /etc/profile.d/homebrew.sh \
    && chmod +r /etc/profile.d/homebrew.sh

# ---------------------------------------------------------------------------
# Configure Claude Code bypassPermissions (auto-approve all tool calls)
# ---------------------------------------------------------------------------
RUN mkdir -p /home/openclaw/.claude \
    && printf '{\n  "permissions": {\n    "defaultMode": "bypassPermissions"\n  }\n}\n' \
       > /home/openclaw/.claude/settings.json \
    && chown -R openclaw:openclaw /home/openclaw/.claude

# ---------------------------------------------------------------------------
# Application configuration
# ---------------------------------------------------------------------------
WORKDIR /app

# Copy configuration template and healthcheck
COPY config.json /app/config/config.json
COPY healthcheck.sh /app/healthcheck.sh
RUN chmod +x /app/healthcheck.sh \
    && chown -R openclaw:openclaw /app

# Copy s6-overlay service definitions
COPY rootfs/ /

# Ensure all s6 scripts are executable
RUN chmod +x /etc/s6-overlay/scripts/* \
    && find /etc/s6-overlay/s6-rc.d -name 'run' -exec chmod +x {} \; \
    && find /etc/s6-overlay/s6-rc.d -name 'up' -exec chmod +x {} \;

# ---------------------------------------------------------------------------
# Environment variables
# ---------------------------------------------------------------------------
ENV NODE_ENV="production" \
    LLAMACPP_BASE_URL="http://llamacpp:8000/v1" \
    LLAMACPP_MODEL_NAME="gemma-4-E4B-it" \
    LLAMACPP_MAX_TOKENS=4096 \
    LLAMACPP_TEMPERATURE=0.7 \
    LLAMACPP_HEALTH_RETRIES=60 \
    LLAMACPP_HEALTH_INTERVAL=5 \
    OPENCLAW_PORT=18789 \
    OPENCLAW_CONFIG_DIR="/app/config" \
    OPENCLAW_CONFIG="/app/config/config.json" \
    OPENCLAW_HOST="0.0.0.0" \
    OPENAI_API_BASE="http://llamacpp:8000/v1" \
    OPENAI_BASE_URL="http://llamacpp:8000/v1" \
    OPENAI_MODEL="gemma-4-E4B-it" \
    OPENCLAW_LLM_PROVIDER="openai-compatible" \
    OPENCLAW_LLM_BASE_URL="http://llamacpp:8000/v1" \
    OPENCLAW_LLM_MODEL="gemma-4-E4B-it" \
    OPENCLAW_LLM_MAX_TOKENS=4096 \
    OPENCLAW_LLM_TEMPERATURE=0.7 \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0

# ---------------------------------------------------------------------------
# Switch to non-root user
# ---------------------------------------------------------------------------
USER openclaw

# Expose port: OpenClaw dashboard
EXPOSE 18789

# Healthcheck — verify the dashboard is responding
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD ["/app/healthcheck.sh"]

# s6-overlay as init system
ENTRYPOINT ["/init"]
CMD []
