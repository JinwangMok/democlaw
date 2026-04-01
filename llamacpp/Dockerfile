# =============================================================================
# llama.cpp Server Dockerfile (CUDA backend)
# Serves Qwen3.5-9B Q4_K_M GGUF via OpenAI-compatible API
#
# Two-stage build:
#   1. Compile llama.cpp from source with CUDA support
#   2. Minimal runtime image with the server binary
#
# Requirements (host):
#   - NVIDIA GPU with >= 8 GB VRAM (e.g. RTX 3070/4070)
#   - NVIDIA driver >= 525 (CUDA 12.x compatible)
#   - nvidia-container-toolkit (for Docker)
#
# Build arguments (all overridable via --build-arg):
#   CUDA_VERSION        — CUDA toolkit version tag       (default: 12.6.3)
#   LLAMA_CPP_TAG       — llama.cpp git tag/branch       (default: master)
#   CUDA_ARCHITECTURES  — SM arch for the target GPU     (default: 86)
#   VERSION             — image version label            (default: dev)
#   BUILD_DATE          — ISO-8601 build timestamp       (default: unknown)
#   GIT_COMMIT          — short git SHA                  (default: unknown)
# =============================================================================

# ---------------------------------------------------------------------------
# Build-time arguments
# ---------------------------------------------------------------------------
ARG CUDA_VERSION=12.6.3
ARG LLAMA_CPP_TAG=master
ARG CUDA_ARCHITECTURES=86
ARG VERSION=dev
ARG BUILD_DATE=unknown
ARG GIT_COMMIT=unknown

# ===========================================================================
# Stage 1: Build llama.cpp with CUDA
# ===========================================================================
FROM docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS builder

ARG LLAMA_CPP_TAG
ARG CUDA_ARCHITECTURES

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake git build-essential libcurl4-openssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# CUDA driver stubs provide libcuda.so for compile-time linking, but the stub
# doesn't define all VMM symbols (cuMemCreate, etc.). Allow the linker to leave
# those unresolved — they will be satisfied at runtime by the real driver
# injected via nvidia-container-toolkit.
ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH}

RUN git clone --depth 1 --branch "${LLAMA_CPP_TAG}" \
        https://github.com/ggerganov/llama.cpp.git . \
    && cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \
    && cmake --build build --config Release -j"$(nproc)" --target llama-server

# ===========================================================================
# Stage 2: Runtime image
# ===========================================================================
FROM docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

ARG VERSION
ARG BUILD_DATE
ARG GIT_COMMIT

LABEL maintainer="democlaw"
LABEL description="llama.cpp OpenAI-compatible server for Qwen3.5-9B Q4_K_M GGUF (CUDA)"
LABEL org.opencontainers.image.title="democlaw-llamacpp"
LABEL org.opencontainers.image.description="Serves Qwen3.5-9B Q4_K_M via llama.cpp OpenAI-compatible API"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
LABEL org.opencontainers.image.source="https://github.com/JinwangMok/democlaw"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.vendor="democlaw"
LABEL democlaw.engine="llama.cpp"
LABEL democlaw.model="Qwen3.5-9B-Q4_K_M"

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates libcurl4 libgomp1 python3 \
    && rm -rf /var/lib/apt/lists/*

# Copy llama-server binary and shared libraries from builder.
# llama.cpp places all outputs under build/bin/ (including versioned sonames).
COPY --from=builder /build/build/bin/llama-server /usr/local/bin/llama-server
COPY --from=builder /build/build/bin/libllama.so   /usr/local/lib/
COPY --from=builder /build/build/bin/libggml.so    /usr/local/lib/
COPY --from=builder /build/build/bin/libggml-base.so  /usr/local/lib/
COPY --from=builder /build/build/bin/libggml-cuda.so  /usr/local/lib/
COPY --from=builder /build/build/bin/libggml-cpu.so   /usr/local/lib/
COPY --from=builder /build/build/bin/libmtmd.so       /usr/local/lib/
RUN ldconfig

# ---------------------------------------------------------------------------
# Default runtime environment variables
# All values are overridable at container start via --env / --env-file.
# ---------------------------------------------------------------------------
ENV MODEL_PATH="/models/Qwen3.5-9B-Q4_K_M.gguf" \
    MODEL_REPO="unsloth/Qwen3.5-9B-GGUF" \
    MODEL_FILE="Qwen3.5-9B-Q4_K_M.gguf" \
    MODEL_ALIAS="Qwen3.5-9B-Q4_K_M" \
    LLAMA_HOST="0.0.0.0" \
    LLAMA_PORT="8000" \
    CTX_SIZE="32768" \
    N_GPU_LAYERS="99" \
    FLASH_ATTN="1" \
    CACHE_TYPE_K="q8_0" \
    CACHE_TYPE_V="q8_0"
# LLAMA_API_KEY is intentionally NOT set here to avoid the
# SecretsUsedInArgOrEnv lint warning. The entrypoint falls back
# to no-auth mode when the variable is unset (${LLAMA_API_KEY:-}).

# Model weights cache directory
RUN mkdir -p /models
VOLUME ["/models"]

# Expose the OpenAI-compatible API port
EXPOSE 8000

# ---------------------------------------------------------------------------
# Copy in-container helper scripts
# ---------------------------------------------------------------------------
COPY healthcheck.sh /opt/healthcheck.sh
COPY entrypoint.sh  /opt/entrypoint.sh
RUN chmod +x /opt/healthcheck.sh /opt/entrypoint.sh

# ---------------------------------------------------------------------------
# Healthcheck: verifies /health AND /v1/models respond correctly.
# start-period=600s accounts for model download + GPU load time on first run.
# ---------------------------------------------------------------------------
HEALTHCHECK --interval=15s --timeout=10s --start-period=600s --retries=24 \
    CMD ["/opt/healthcheck.sh"]

ENTRYPOINT ["/opt/entrypoint.sh"]
