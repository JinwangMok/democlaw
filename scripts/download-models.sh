#!/usr/bin/env bash
# =============================================================================
# download-models.sh — Pre-download model weights for DemoClaw (Linux)
#
# Downloads Qwen/Qwen3-4B-AWQ (or any HuggingFace model) to the local cache
# so vLLM startup is fast — no download delay on first container run.
#
# After download, verifies file integrity using SHA256 checksums via
# lib/checksum.sh and stores sidecar .sha256 files for future verification.
#
# Usage:
#   ./scripts/download-models.sh [model_name]
#
# Environment variables:
#   MODEL_NAME      — HuggingFace model ID (default: Qwen/Qwen3-4B-AWQ)
#   HF_CACHE_DIR    — HuggingFace cache root (default: ~/.cache/huggingface)
#   HF_TOKEN        — HuggingFace token for gated/private models (optional)
#
# Examples:
#   ./scripts/download-models.sh
#   ./scripts/download-models.sh Qwen/Qwen3-4B-AWQ
#   HF_TOKEN=hf_xxx ./scripts/download-models.sh
#   HF_CACHE_DIR=/mnt/models ./scripts/download-models.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { echo "[download-models] $*"; }
warn()  { echo "[download-models] WARNING: $*" >&2; }
error() { echo "[download-models] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment)
# ---------------------------------------------------------------------------
MODEL_NAME="${1:-${MODEL_NAME:-Qwen/Qwen3-4B-AWQ}}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"
HF_TOKEN="${HF_TOKEN:-}"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
log "======================================================="
log "  DemoClaw — Model Pre-Download"
log "  Model     : ${MODEL_NAME}"
log "  Cache dir : ${HF_CACHE_DIR}"
log "======================================================="
log "This may take several minutes on first run (~5 GB download)."
log "Subsequent runs detect the cached model and finish instantly."

# ---------------------------------------------------------------------------
# Ensure cache directory exists
# ---------------------------------------------------------------------------
mkdir -p "${HF_CACHE_DIR}"

# ---------------------------------------------------------------------------
# Export HF_TOKEN if set, so both huggingface-cli and huggingface_hub pick it up
# ---------------------------------------------------------------------------
if [ -n "${HF_TOKEN}" ]; then
    export HF_TOKEN
    export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
    log "HF_TOKEN is set — will authenticate for gated models."
fi

# ---------------------------------------------------------------------------
# Source checksum library for pre-download verification
# ---------------------------------------------------------------------------
CHECKSUM_LIB="${SCRIPT_DIR}/lib/checksum.sh"

if [ -f "${CHECKSUM_LIB}" ]; then
    # Override logging to match our prefix
    _cksum_log()   { echo "[download-models] [checksum] $*"; }
    _cksum_warn()  { echo "[download-models] [checksum] WARNING: $*" >&2; }
    _cksum_error() { echo "[download-models] [checksum] ERROR: $*" >&2; }

    # shellcheck source=lib/checksum.sh
    source "${CHECKSUM_LIB}"
fi

# ---------------------------------------------------------------------------
# Pre-download checksum verification: skip download if all files pass
#
# checksum_model_needs_download compares existing model files against their
# stored .sha256 sidecar checksums. Download is skipped ONLY when every
# model file is present AND its computed SHA256 matches the stored value.
# ---------------------------------------------------------------------------
if [ -f "${CHECKSUM_LIB}" ]; then
    log "======================================================="
    log "  Step: Pre-download checksum verification"
    log "======================================================="

    if ! checksum_model_needs_download "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        log "All model files present and checksums verified — skipping download."
        log ""
        log "======================================================="
        log "  Model download complete! (cached)"
        log ""
        log "  Model     : ${MODEL_NAME}"
        log "  Cache dir : ${HF_CACHE_DIR}"
        log ""
        log "  vLLM will use this cache on next startup."
        log "  Start the stack with: ./scripts/start.sh"
        log "======================================================="
        exit 0
    fi

    log "Download needed — proceeding with model acquisition."
fi

# ---------------------------------------------------------------------------
# download_with_cli — attempt download via huggingface-cli
#
# Returns 0 on success, 1 if huggingface-cli is not available.
# ---------------------------------------------------------------------------
download_with_cli() {
    if ! command -v huggingface-cli >/dev/null 2>&1; then
        return 1
    fi

    log "Using huggingface-cli to download '${MODEL_NAME}' ..."

    # huggingface-cli download is idempotent: skips files already present
    local hf_args=(
        download
        "${MODEL_NAME}"
        --cache-dir "${HF_CACHE_DIR}"
        --ignore-patterns "*.pt" "*.bin"   # prefer safetensors; skip legacy weights
    )

    if [ -n "${HF_TOKEN}" ]; then
        hf_args+=(--token "${HF_TOKEN}")
    fi

    huggingface-cli "${hf_args[@]}"
    return 0
}

# ---------------------------------------------------------------------------
# download_with_python — fallback download via huggingface_hub Python library
#
# Used when huggingface-cli is not on PATH (e.g. installed only inside venv).
# ---------------------------------------------------------------------------
download_with_python() {
    log "huggingface-cli not found — falling back to Python huggingface_hub ..."

    python3 -c "
import sys, os

model_name = '${MODEL_NAME}'
cache_dir  = '${HF_CACHE_DIR}'
hf_token   = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN') or None

print(f'[download-models] Checking local cache for: {model_name}')

try:
    from huggingface_hub import snapshot_download
except ImportError:
    print('[download-models] ERROR: huggingface_hub is not installed.', file=sys.stderr)
    print('[download-models] Install it with: pip install huggingface_hub', file=sys.stderr)
    sys.exit(1)

# Check if model is already fully cached
try:
    local_path = snapshot_download(
        repo_id=model_name,
        cache_dir=cache_dir,
        local_files_only=True,
    )
    print(f'[download-models] Model already cached at: {local_path}')
    print('[download-models] Skipping download.')
    sys.exit(0)
except Exception:
    pass  # not cached — proceed to download

print(f'[download-models] Downloading {model_name} ...')

try:
    local_path = snapshot_download(
        repo_id=model_name,
        cache_dir=cache_dir,
        ignore_patterns=['*.pt', '*.bin'],  # prefer safetensors
        token=hf_token,
    )
    print(f'[download-models] Download complete. Weights stored at: {local_path}')
except Exception as e:
    print(f'[download-models] ERROR: Download failed: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# ---------------------------------------------------------------------------
# Perform download: try CLI first, fall back to Python
# ---------------------------------------------------------------------------
if ! download_with_cli; then
    download_with_python
fi

log "Download step complete."

# ---------------------------------------------------------------------------
# Checksum verification and storage
#
# Source lib/checksum.sh to access:
#   checksum_verify_model_cache <cache_dir> <model_name>
#   checksum_store_dir          <snapshot_dir>
#
# checksum_verify_model_cache locates the HF snapshot directory under
#   <cache_dir>/hub/models--<org>--<name>/snapshots/<revision>/
# and verifies or generates SHA256 sidecars for all .safetensors + .json files.
# ---------------------------------------------------------------------------
log "======================================================="
log "  Step: Checksum verification"
log "======================================================="

if [ -f "${CHECKSUM_LIB}" ]; then
    # Verify downloaded model files and store .sha256 sidecar checksums.
    # checksum_verify_model_cache verifies existing sidecars or generates new ones.
    if checksum_verify_model_cache "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        log "Post-download checksum verification passed."
    else
        warn "Post-download checksum verification returned non-zero — see above for details."
    fi

    # Store checksums for all model files (idempotent: overwrites existing sidecars).
    # These .sha256 files enable checksum-verified skip on the next run.
    if checksum_store_model_cache "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        log "Checksums stored for future verification."
    else
        warn "Failed to store some checksums — next run may re-download."
    fi
else
    warn "Checksum library not found at: ${CHECKSUM_LIB}"
    warn "Skipping post-download checksum storage."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "======================================================="
log "  Model download complete!"
log ""
log "  Model     : ${MODEL_NAME}"
log "  Cache dir : ${HF_CACHE_DIR}"
log ""
log "  vLLM will use this cache on next startup."
log "  Start the stack with: ./scripts/start.sh"
log "======================================================="
