#!/usr/bin/env bash
# =============================================================================
# vllm-manual.sh -- DGX Spark GB10 (sm_121) vLLM launcher
#
# Background (this is not a guess — we have receipts):
#
#   vLLM issue #28589 documents that on Blackwell GB10 (compute_cap 12.1),
#   Triton's ptxas does not recognize `sm_121a` and fails codegen, while the
#   other attention backends (XFORMERS / FLASH_ATTN / FLASHINFER) reject the
#   model with "sink setting not supported" because Gemma 4 uses attention
#   sinks. The v1 engine auto-selects Triton, which then hangs in a silent
#   PTXAS error loop — exactly the symptom we see: stdout stops right after
#   `cuda.py:274 Using AttentionBackendEnum.TRITON_ATTN backend.`
#
#   The `vllm/vllm-openai:gemma4-cu130` tag is a mutable community tag. It
#   was rewritten at some point in the last few days: the digest that served
#   gemma-4-26B successfully on bare-metal DGX Spark was
#   `sha256:0d152595cd940ea1e0890fa190a37b7a86e3f7f0f5048ac3e2e4c14529fea833`
#   but the current tag points elsewhere, so a fresh `docker pull` no longer
#   gets the version that worked. This explains the regression within a
#   few-day window with no user changes.
#
#   Known workaround from eelbaz/dgx-spark-vllm-setup: force the build /
#   runtime compile target to sm_120 via `TORCH_CUDA_ARCH_LIST=12.0` so the
#   driver JIT-compiles PTX for sm_120 and runs it on sm_121 (the same path
#   that lets cuBLAS matmul succeed in user's smoke test).
#
# What this script does
#
#   1. Detects podman / docker automatically (prefers podman on this node,
#      since the DGX Spark environment user is on is a nested custom
#      container that uses podman with a docker-compat shim).
#   2. Defaults to pinning the known-good image digest. `--no-pin` opts out.
#   3. Runs a container GPU smoke test using the pinned image before
#      committing to the big model launch, surfacing toolkit problems early.
#   4. Launches vLLM foreground (`tee` into /tmp/vllm-debug.log) with the
#      exact reference flag set from dgx-spark-ai-cluster's compose file,
#      PLUS the sm_121 workaround envs, PLUS DEBUG logging and NCCL safety
#      env so if it still hangs the next line in the log is actionable.
#   5. Traps INT/TERM/EXIT so Ctrl+C actually removes the container and
#      cannot leak a running vLLM into the pod's unified memory (which has
#      frozen the node before in this session).
#
# Usage
#   ./scripts/vllm-manual.sh                # default: pinned digest, full launch
#   ./scripts/vllm-manual.sh --no-pin       # use current :gemma4-cu130 tag (unpinned)
#   ./scripts/vllm-manual.sh --digest sha256:abc  # custom digest
#   ./scripts/vllm-manual.sh --model <id>   # override HF model id
#   ./scripts/vllm-manual.sh --probe        # only smoke test GPU + digest, no serve
#   ./scripts/vllm-manual.sh --backend TORCH_SDPA  # override attention backend env
#   ./scripts/vllm-manual.sh --v0           # force VLLM_USE_V1=0
#
# Environment
#   VLLM_IMAGE_REPO     default: vllm/vllm-openai
#   VLLM_IMAGE_TAG      default: gemma4-cu130
#   VLLM_MODEL_ID       default: google/gemma-4-26B-A4B-it
#   MODEL_DIR           default: /home/user/models
#   HF_TOKEN            forwarded as HUGGING_FACE_HUB_TOKEN if set
#   CONTAINER_RUNTIME   default: auto (podman preferred)
#   LOG_FILE            default: /tmp/vllm-debug.log
# =============================================================================
set -uo pipefail

KNOWN_GOOD_DIGEST="sha256:0d152595cd940ea1e0890fa190a37b7a86e3f7f0f5048ac3e2e4c14529fea833"

VLLM_IMAGE_REPO="${VLLM_IMAGE_REPO:-vllm/vllm-openai}"
VLLM_IMAGE_TAG="${VLLM_IMAGE_TAG:-gemma4-cu130}"
VLLM_MODEL_ID="${VLLM_MODEL_ID:-google/gemma-4-26B-A4B-it}"
MODEL_DIR="${MODEL_DIR:-/home/user/models}"
CONTAINER_NAME="${CONTAINER_NAME:-vllm}"
LOG_FILE="${LOG_FILE:-/tmp/vllm-debug.log}"

PIN_KNOWN_GOOD=1        # default ON — regression confirmed
CUSTOM_DIGEST=""
PROBE_ONLY=0
FORCE_BACKEND=""
FORCE_V0=0

log() { printf '[vllm-manual] %s\n' "$*"; }
die() { printf '[vllm-manual] ERROR: %s\n' "$*" >&2; exit 1; }

# --- argv ------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pin)      PIN_KNOWN_GOOD=1; shift ;;
        --no-pin)   PIN_KNOWN_GOOD=0; shift ;;
        --digest)   CUSTOM_DIGEST="$2"; shift 2 ;;
        --model)    VLLM_MODEL_ID="$2"; shift 2 ;;
        --probe)    PROBE_ONLY=1; shift ;;
        --backend)  FORCE_BACKEND="$2"; shift 2 ;;
        --v0)       FORCE_V0=1; shift ;;
        --help|-h)  sed -n '2,60p' "$0"; exit 0 ;;
        *)          die "unknown arg: $1" ;;
    esac
done

# --- runtime detection (prefer podman) ------------------------------------
if [ -n "${CONTAINER_RUNTIME:-}" ]; then
    RUNTIME="${CONTAINER_RUNTIME}"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
else
    die "neither podman nor docker found in PATH"
fi

cleanup() {
    local rc=$?
    if "${RUNTIME}" container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        log "cleanup: removing container '${CONTAINER_NAME}'"
        "${RUNTIME}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    exit "${rc}"
}
trap cleanup INT TERM EXIT

# --- image resolution -----------------------------------------------------
if [ -n "${CUSTOM_DIGEST}" ]; then
    IMAGE_REF="${VLLM_IMAGE_REPO}@${CUSTOM_DIGEST}"
    log "image: custom digest ${IMAGE_REF}"
elif [ "${PIN_KNOWN_GOOD}" -eq 1 ]; then
    IMAGE_REF="${VLLM_IMAGE_REPO}@${KNOWN_GOOD_DIGEST}"
    log "image: known-good digest (regression defense) ${IMAGE_REF}"
else
    IMAGE_REF="${VLLM_IMAGE_REPO}:${VLLM_IMAGE_TAG}"
    log "image: current tag ${IMAGE_REF}"
fi
log "runtime: ${RUNTIME}"
log "model  : ${VLLM_MODEL_ID}"
log "cache  : ${MODEL_DIR}"
log "log    : ${LOG_FILE}"

# --- pull if missing ------------------------------------------------------
if ! "${RUNTIME}" image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
    log "pulling ${IMAGE_REF} ..."
    "${RUNTIME}" pull "${IMAGE_REF}" || die "pull failed for ${IMAGE_REF}"
fi

# --- digest comparison vs known-good --------------------------------------
CURRENT_DIGEST=$("${RUNTIME}" image inspect "${IMAGE_REF}" \
    --format '{{index .RepoDigests 0}}' 2>/dev/null || true)
log "pulled digest: ${CURRENT_DIGEST:-unknown}"
if [ -z "${CUSTOM_DIGEST}" ] && [ "${PIN_KNOWN_GOOD}" -eq 0 ] \
   && [ -n "${CURRENT_DIGEST}" ] \
   && [ "${CURRENT_DIGEST##*@}" != "${KNOWN_GOOD_DIGEST}" ]; then
    log "WARNING: current tag digest differs from known-good."
    log "         Re-run with (default) --pin or pass --digest explicitly."
fi

# --- container GPU smoke test ---------------------------------------------
log "--- container GPU smoke test ---"
if ! "${RUNTIME}" run --rm --device nvidia.com/gpu=all \
        --entrypoint nvidia-smi "${IMAGE_REF}" -L 2>&1 | head -3; then
    log "smoke test with --device nvidia.com/gpu=all failed; trying --gpus all"
    if ! "${RUNTIME}" run --rm --gpus all \
            --entrypoint nvidia-smi "${IMAGE_REF}" -L 2>&1 | head -3; then
        die "container cannot see GPU with either CDI or legacy flag"
    fi
    GPU_FLAG_MODE="legacy"
else
    GPU_FLAG_MODE="cdi"
fi
log "GPU flag mode: ${GPU_FLAG_MODE}"

if [ "${PROBE_ONLY}" -eq 1 ]; then
    log "--probe: done"
    exit 0
fi

# --- model cache dir ------------------------------------------------------
if [ ! -d "${MODEL_DIR}" ]; then
    log "creating model cache: ${MODEL_DIR}"
    mkdir -p "${MODEL_DIR}" || die "cannot create ${MODEL_DIR}"
fi

# --- stale container cleanup ----------------------------------------------
if "${RUNTIME}" container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    log "removing stale container '${CONTAINER_NAME}'"
    "${RUNTIME}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

# --- serve flags (reference verbatim, dgx-spark-ai-cluster 26B path) ------
declare -a SERVE_FLAGS=(
    --model "${VLLM_MODEL_ID}"
    --host 0.0.0.0
    --port 8000
    --gpu-memory-utilization 0.70
    --dtype auto
    --quantization fp8
    --kv-cache-dtype fp8
    --load-format safetensors
    --enable-auto-tool-choice
    --tool-call-parser gemma4
    --reasoning-parser gemma4
    --enable-prefix-caching
    --enable-chunked-prefill
    --max-num-seqs 4
    --max-num-batched-tokens 8192
    --max-model-len 262144
)

# --- sm_121 workarounds + debug envs --------------------------------------
#
# TORCH_CUDA_ARCH_LIST=12.0 coerces PyTorch's CUDA arch targeting to sm_120;
# GB10 sm_121 then runs via driver PTX JIT, same path that makes plain cuBLAS
# matmul succeed. This is the eelbaz/dgx-spark-vllm-setup workaround.
#
# CUDA_DEVICE_MAX_CONNECTIONS=1 reduces the CUDA stream count vLLM touches
# during worker init, which helps when the inner runtime has constrained
# cgroups/nofile limits (kept conservative for nested podman).
#
# NCCL_*=disable-ish defaults keep single-GPU init from probing Infiniband /
# IPv6 / multi-socket interfaces that don't exist in a k8s pod.
declare -a RUN_ENVS=(
    -e "HF_HOME=/data/models"
    -e "PYTHONUNBUFFERED=1"
    -e "TOKENIZERS_PARALLELISM=false"
    -e "VLLM_LOGGING_LEVEL=DEBUG"
    -e "NCCL_DEBUG=INFO"
    -e "NCCL_P2P_DISABLE=1"
    -e "NCCL_IB_DISABLE=1"
    -e "NCCL_SOCKET_IFNAME=lo"
    -e "NCCL_CUMEM_ENABLE=0"
    -e "TRITON_CACHE_DIR=/tmp/triton-cache"
    -e "TORCH_CUDA_ARCH_LIST=12.0"
    -e "CUDA_DEVICE_MAX_CONNECTIONS=1"
)
if [ -n "${HF_TOKEN:-}" ]; then
    RUN_ENVS+=(-e "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}")
fi
if [ -n "${FORCE_BACKEND}" ]; then
    RUN_ENVS+=(-e "VLLM_ATTENTION_BACKEND=${FORCE_BACKEND}")
    log "forcing VLLM_ATTENTION_BACKEND=${FORCE_BACKEND}"
fi
if [ "${FORCE_V0}" -eq 1 ]; then
    RUN_ENVS+=(-e "VLLM_USE_V1=0")
    log "forcing VLLM_USE_V1=0"
fi

# --- run flags ------------------------------------------------------------
declare -a GPU_RUN_FLAGS
if [ "${GPU_FLAG_MODE}" = "cdi" ]; then
    GPU_RUN_FLAGS=(--device nvidia.com/gpu=all)
else
    GPU_RUN_FLAGS=(--gpus all)
fi

declare -a RUN_FLAGS=(
    --rm
    --name "${CONTAINER_NAME}"
    --ipc host
    -p 8000:8000
    -v "${MODEL_DIR}:/data/models:rw"
)

# Podman-nested safety: these are no-ops on docker and help on podman.
if [ "${RUNTIME}" = "podman" ] || "${RUNTIME}" --version 2>/dev/null | grep -qi podman; then
    RUN_FLAGS+=(--security-opt seccomp=unconfined)
fi

# --- launch (foreground, teed) --------------------------------------------
: >"${LOG_FILE}" || true

log "========================================================================"
log "launching vLLM (foreground). Ctrl+C to stop. log: ${LOG_FILE}"
log "flags: ${SERVE_FLAGS[*]}"
log "========================================================================"

"${RUNTIME}" run \
    "${RUN_FLAGS[@]}" \
    "${GPU_RUN_FLAGS[@]}" \
    "${RUN_ENVS[@]}" \
    "${IMAGE_REF}" \
    "${SERVE_FLAGS[@]}" 2>&1 | tee "${LOG_FILE}"
