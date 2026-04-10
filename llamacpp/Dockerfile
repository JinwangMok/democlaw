# =============================================================================
# llama.cpp Server Dockerfile (CUDA backend)
# Serves Google Gemma 4 GGUF models via OpenAI-compatible API (with multimodal vision)
#
# Supported models (selected via .env / environment variables):
#   - Gemma 4 E4B Q4_K_M   (~4.7 GB, 8 GB VRAM GPUs)
#   - Gemma 4 26B A4B MoE   (128 GB unified memory, DGX Spark)
#
# Two-stage build:
#   1. Compile llama.cpp from source with CUDA support
#   2. Minimal runtime image with the server binary
#
# Requirements (host):
#   - NVIDIA GPU with >= 8 GB VRAM (e.g. RTX 3070/4070) or DGX Spark
#   - NVIDIA driver >= 525 (CUDA 12.x compatible)
#   - nvidia-container-toolkit (for Docker)
#
# Build arguments (all overridable via --build-arg):
#   CUDA_VERSION        — CUDA toolkit version tag       (default: 12.8.1)
#   LLAMA_CPP_TAG       — llama.cpp git tag/branch       (default: master)
#   CUDA_ARCHITECTURES  — SM archs for target GPUs       (auto-detected per platform)
#   VERSION             — image version label            (default: dev)
#   BUILD_DATE          — ISO-8601 build timestamp       (default: unknown)
#   GIT_COMMIT          — short git SHA                  (default: unknown)
# =============================================================================

# ---------------------------------------------------------------------------
# Build-time arguments
# ---------------------------------------------------------------------------
ARG CUDA_VERSION=12.8.1
ARG LLAMA_CPP_TAG=master
ARG VERSION=dev
ARG BUILD_DATE=unknown
ARG GIT_COMMIT=unknown

# ===========================================================================
# Stage 1: Build llama.cpp with CUDA
# ===========================================================================
FROM docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS builder

ARG LLAMA_CPP_TAG
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake git build-essential libcurl4-openssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# CUDA driver stubs provide libcuda.so for compile-time linking, but the stub
# doesn't define all VMM symbols (cuMemCreate, etc.). Allow the linker to leave
# those unresolved — they will be satisfied at runtime by the real driver
# injected via nvidia-container-toolkit.
ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH}

# Select CUDA SM architectures per CPU platform:
#   amd64 → sm_86 (Ampere) + sm_89 (Ada Lovelace) — consumer GPUs
#   arm64 → sm_120 (Blackwell) — DGX Spark GB10
RUN CUDA_ARCHS="86;89"; \
    if [ "${TARGETARCH}" = "arm64" ]; then CUDA_ARCHS="120"; fi \
    && git clone --depth 1 --branch "${LLAMA_CPP_TAG}" \
        https://github.com/ggerganov/llama.cpp.git . \
    && cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}" \
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
LABEL description="llama.cpp OpenAI-compatible server for Google Gemma 4 GGUF (CUDA)"
LABEL org.opencontainers.image.title="democlaw-llamacpp"
LABEL org.opencontainers.image.description="Serves Gemma 4 (E4B / 26B-A4B) via llama.cpp OpenAI-compatible API"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
LABEL org.opencontainers.image.source="https://github.com/JinwangMok/democlaw"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.vendor="democlaw"
LABEL democlaw.engine="llama.cpp"
LABEL democlaw.model="gemma-4"

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
ENV MODEL_PATH="/models/gemma-4-E4B-it-Q4_K_M.gguf" \
    MODEL_REPO="unsloth/gemma-4-E4B-it-GGUF" \
    MODEL_FILE="gemma-4-E4B-it-Q4_K_M.gguf" \
    MODEL_ALIAS="gemma-4-E4B-it" \
    LLAMA_HOST="0.0.0.0" \
    LLAMA_PORT="8000" \
    CTX_SIZE="131072" \
    N_GPU_LAYERS="99" \
    FLASH_ATTN="1" \
    CACHE_TYPE_K="q4_0" \
    CACHE_TYPE_V="q4_0" \
    AUTO_DETECT_MODEL="1" \
    ENABLE_VISION="1" \
    MMPROJ_FILE="mmproj-BF16.gguf" \
    MMPROJ_REPO="" \
    IMAGE_TOKENS="1120" \
    UBATCH_SIZE="2048" \
    BATCH_SIZE="2048"
# AUTO_DETECT_MODEL=1 enables in-container hardware detection at startup.
# The entrypoint will query nvidia-smi and auto-select the appropriate
# Gemma 4 variant (E4B for <=8GB VRAM, 26B A4B MoE for DGX Spark).
# Set AUTO_DETECT_MODEL=0 to skip detection and use the ENV defaults above.
#
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
