# =============================================================================
# MarkItDown MCP Server — Python 3.12 slim + markitdown + MCP SSE transport
#
# Lightweight sidecar container that exposes markitdown as an MCP server
# over HTTP (SSE transport) so OpenClaw can call it via mcporter.
#
# Build arguments (all overridable via --build-arg):
#   MARKITDOWN_VERSION — pip package version (default: latest)
#   MARKITDOWN_PORT    — SSE server listen port (default: 3001)
#   VERSION            — image version label (default: dev)
#   BUILD_DATE         — ISO-8601 build timestamp (default: unknown)
#   GIT_COMMIT         — short git SHA (default: unknown)
# =============================================================================

ARG MARKITDOWN_VERSION=latest
ARG MARKITDOWN_PORT=3001
ARG VERSION=dev
ARG BUILD_DATE=unknown
ARG GIT_COMMIT=unknown

FROM docker.io/python:3.12-slim

ARG MARKITDOWN_VERSION
ARG MARKITDOWN_PORT
ARG VERSION
ARG BUILD_DATE
ARG GIT_COMMIT

LABEL maintainer="democlaw"
LABEL description="MarkItDown MCP server for document conversion"
LABEL org.opencontainers.image.title="democlaw-markitdown"
LABEL org.opencontainers.image.description="MarkItDown MCP server (SSE transport) for OpenClaw integration"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
LABEL org.opencontainers.image.source="https://github.com/democlaw/democlaw"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.vendor="democlaw"

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Install system dependencies for document conversion
# (poppler-utils for PDF, pandoc for DOCX/PPTX, etc.)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        poppler-utils \
        pandoc \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install markitdown with MCP extras
# ---------------------------------------------------------------------------
RUN if [ "${MARKITDOWN_VERSION}" = "latest" ]; then \
        pip install --no-cache-dir "markitdown[all]" "mcp[cli]" starlette uvicorn; \
    else \
        pip install --no-cache-dir "markitdown[all]==${MARKITDOWN_VERSION}" "mcp[cli]" starlette uvicorn; \
    fi

# ---------------------------------------------------------------------------
# Create non-root user
# ---------------------------------------------------------------------------
RUN groupadd -g 1000 markitdown \
    && useradd -u 1000 -g markitdown -m -s /bin/bash markitdown

WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
COPY healthcheck.sh /app/healthcheck.sh
COPY server.py /app/server.py
RUN chmod +x /app/entrypoint.sh /app/healthcheck.sh \
    && chown -R markitdown:markitdown /app

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
ENV MARKITDOWN_PORT=${MARKITDOWN_PORT} \
    MARKITDOWN_HOST="0.0.0.0"

USER markitdown

EXPOSE ${MARKITDOWN_PORT}

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/app/healthcheck.sh"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD []
