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
# Logging helpers with color support
# ---------------------------------------------------------------------------
_use_color() { [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; }

log()   { echo "[download-models] $*"; }
warn()  { if _use_color; then echo -e "\033[33m[download-models] WARNING: $*\033[0m" >&2; else echo "[download-models] WARNING: $*" >&2; fi; }
error() { if _use_color; then echo -e "\033[31m[download-models] ERROR: $*\033[0m" >&2; else echo "[download-models] ERROR: $*" >&2; fi; exit 1; }
ok()    { if _use_color; then echo -e "\033[32m[download-models] ✓ $*\033[0m"; else echo "[download-models] OK: $*"; fi; }
info()  { if _use_color; then echo -e "\033[36m[download-models] $*\033[0m"; else echo "[download-models] $*"; fi; }

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
    # Override logging to match our prefix with color support
    _cksum_log()   { echo "[download-models] [checksum] $*"; }
    _cksum_warn()  { if _use_color; then echo -e "\033[33m[download-models] [checksum] WARNING: $*\033[0m" >&2; else echo "[download-models] [checksum] WARNING: $*" >&2; fi; }
    _cksum_error() { if _use_color; then echo -e "\033[31m[download-models] [checksum] ERROR: $*\033[0m" >&2; else echo "[download-models] [checksum] ERROR: $*" >&2; fi; }

    # shellcheck source=lib/checksum.sh
    source "${CHECKSUM_LIB}"
else
    warn "Checksum library not found at: ${SCRIPT_DIR}/lib/checksum.sh"
    warn "Model integrity verification will be DISABLED."
    warn "To enable checksums, ensure lib/checksum.sh is present."
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
    info "  Step 1/3: Pre-download integrity check (SHA256)"
    log "======================================================="
    log ""
    log "Comparing cached model files against stored checksums ..."
    log "This ensures no corrupt or tampered files are reused."
    log ""

    _verify_start=$(date +%s 2>/dev/null || echo 0)

    if ! checksum_model_needs_download "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        _verify_end=$(date +%s 2>/dev/null || echo 0)
        _verify_elapsed=$(( _verify_end - _verify_start ))

        log ""
        ok "All model files present and SHA256 checksums verified!"
        [ "${_verify_elapsed}" -gt 0 ] 2>/dev/null && log "  Verification completed in ${_verify_elapsed}s"
        log ""
        log "======================================================="
        ok "  Model ready! (verified from cache)"
        log ""
        log "  Model     : ${MODEL_NAME}"
        log "  Cache dir : ${HF_CACHE_DIR}"
        log ""
        log "  vLLM will use this cache on next startup."
        log "  Start the stack with: ./scripts/start.sh"
        log "======================================================="
        exit 0
    fi

    _verify_end=$(date +%s 2>/dev/null || echo 0)
    _verify_elapsed=$(( _verify_end - _verify_start ))
    [ "${_verify_elapsed}" -gt 0 ] 2>/dev/null && log "  Check completed in ${_verify_elapsed}s"
    log ""
    warn "Checksum verification indicates model is missing or corrupted."
    log "Proceeding with fresh download ..."
    log ""
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
# Step 2/3: Post-download checksum verification
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
info "  Step 2/3: Post-download integrity verification (SHA256)"
log "======================================================="
log ""

if [ -f "${CHECKSUM_LIB}" ]; then
    _verify_start=$(date +%s 2>/dev/null || echo 0)

    # Verify downloaded model files against any existing .sha256 sidecar checksums.
    # On first download, sidecars won't exist yet — they are generated in Step 3.
    log "Verifying downloaded model files ..."
    if checksum_verify_model_cache "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        ok "Post-download checksum verification passed."
    else
        warn "Post-download checksum verification returned non-zero."
        warn "This is normal on first download (no prior checksums exist)."
        warn "Checksums will be generated in the next step."
    fi

    log ""
    log "======================================================="
    info "  Step 3/3: Storing SHA256 checksums for future runs"
    log "======================================================="
    log ""

    # Store checksums for all model files (idempotent: overwrites existing sidecars).
    # These .sha256 files enable checksum-verified skip on the next run.
    log "Computing and storing SHA256 hashes for all model files ..."
    log "Each file gets a .sha256 sidecar for future verification."
    log ""
    if checksum_store_model_cache "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        _verify_end=$(date +%s 2>/dev/null || echo 0)
        _verify_elapsed=$(( _verify_end - _verify_start ))
        ok "Checksums stored successfully."
        [ "${_verify_elapsed}" -gt 0 ] 2>/dev/null && log "  Checksum operations completed in ${_verify_elapsed}s"
        log ""
        log "  On subsequent runs, these checksums will be verified before"
        log "  downloading. If all files match, the download is skipped."
    else
        warn "Failed to store some checksums."
        warn "Next run may need to re-download the model."
        warn "This is non-fatal — the model files are still usable."
    fi
else
    warn "Checksum library not found at: ${CHECKSUM_LIB}"
    warn "Skipping post-download checksum storage."
    warn "Without checksums, the model will be re-downloaded on every run."
    warn "To fix: ensure scripts/lib/checksum.sh is present."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log ""
log "======================================================="
ok "  Model download and verification complete!"
log ""
log "  Model     : ${MODEL_NAME}"
log "  Cache dir : ${HF_CACHE_DIR}"
log "  Checksum  : SHA256 sidecar files stored"
log ""
log "  vLLM will use this cache on next startup."
log "  Start the stack with: ./scripts/start.sh"
log "======================================================="
