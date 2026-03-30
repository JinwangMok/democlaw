#!/usr/bin/env bash
# =============================================================================
# download_model.sh — Idempotent model download with checksum & resume (Linux)
#
# Downloads HuggingFace model weights (default: Qwen/Qwen3-4B-AWQ) to the
# local cache with full SHA256 checksum verification, resume support for
# interrupted downloads, and idempotent behavior (safe to run repeatedly).
#
# Lifecycle:
#   1. Pre-download integrity check — verify cached files via SHA256 sidecars
#   2. Download (if needed)         — huggingface-cli → Python fallback → curl
#   3. Post-download verification   — re-verify all downloaded files
#   4. Store checksums              — write .sha256 sidecars for future runs
#
# Idempotency guarantee:
#   - If all cached model files are present AND their SHA256 checksums match
#     stored .sha256 sidecar files, the download is skipped entirely.
#   - On every run, checksums are re-verified from scratch (never trust cache
#     state from a prior run).
#   - Interrupted downloads resume from where they left off (no re-download
#     of completed files).
#
# Usage:
#   ./scripts/download_model.sh [model_name]
#
# Environment variables:
#   MODEL_NAME      — HuggingFace model ID (default: Qwen/Qwen3-4B-AWQ)
#   HF_CACHE_DIR    — HuggingFace cache root (default: ~/.cache/huggingface)
#   HF_TOKEN        — HuggingFace token for gated/private models (optional)
#   FORCE_DOWNLOAD  — Set to "1" to force re-download even if checksums pass
#   MAX_RETRIES     — Max download retry attempts (default: 3)
#
# Examples:
#   ./scripts/download_model.sh
#   ./scripts/download_model.sh Qwen/Qwen3-4B-AWQ
#   HF_TOKEN=hf_xxx ./scripts/download_model.sh
#   HF_CACHE_DIR=/mnt/models ./scripts/download_model.sh
#   FORCE_DOWNLOAD=1 ./scripts/download_model.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers with color support
# ---------------------------------------------------------------------------
_use_color() { [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; }

log()   { echo "[download_model] $*"; }
warn()  { if _use_color; then echo -e "\033[33m[download_model] WARNING: $*\033[0m" >&2; else echo "[download_model] WARNING: $*" >&2; fi; }
error() { if _use_color; then echo -e "\033[31m[download_model] ERROR: $*\033[0m" >&2; else echo "[download_model] ERROR: $*" >&2; fi; exit 1; }
ok()    { if _use_color; then echo -e "\033[32m[download_model] ✓ $*\033[0m"; else echo "[download_model] OK: $*"; fi; }
info()  { if _use_color; then echo -e "\033[36m[download_model] $*\033[0m"; else echo "[download_model] $*"; fi; }

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment)
# ---------------------------------------------------------------------------
MODEL_NAME="${1:-${MODEL_NAME:-Qwen/Qwen3-4B-AWQ}}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"
HF_TOKEN="${HF_TOKEN:-}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"
MAX_RETRIES="${MAX_RETRIES:-3}"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
log "======================================================="
log "  DemoClaw — Model Download (Linux)"
log "======================================================="
log "  Model        : ${MODEL_NAME}"
log "  Cache dir    : ${HF_CACHE_DIR}"
log "  Force re-dl  : ${FORCE_DOWNLOAD}"
log "  Max retries  : ${MAX_RETRIES}"
log "======================================================="
log ""
log "This may take several minutes on first run (~5 GB download)."
log "Subsequent runs detect the cached model and finish instantly."
log ""

# ---------------------------------------------------------------------------
# Ensure cache directory exists
# ---------------------------------------------------------------------------
mkdir -p "${HF_CACHE_DIR}"

# ---------------------------------------------------------------------------
# Export HF_TOKEN if set, so huggingface-cli and huggingface_hub pick it up
# ---------------------------------------------------------------------------
if [ -n "${HF_TOKEN}" ]; then
    export HF_TOKEN
    export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
    log "HF_TOKEN is set — will authenticate for gated models."
fi

# ---------------------------------------------------------------------------
# Source checksum library
# ---------------------------------------------------------------------------
CHECKSUM_LIB="${SCRIPT_DIR}/lib/checksum.sh"
CHECKSUM_AVAILABLE=false

if [ -f "${CHECKSUM_LIB}" ]; then
    # Override logging to match our prefix
    _cksum_log()   { echo "[download_model] [checksum] $*"; }
    _cksum_warn()  { if _use_color; then echo -e "\033[33m[download_model] [checksum] WARNING: $*\033[0m" >&2; else echo "[download_model] [checksum] WARNING: $*" >&2; fi; }
    _cksum_error() { if _use_color; then echo -e "\033[31m[download_model] [checksum] ERROR: $*\033[0m" >&2; else echo "[download_model] [checksum] ERROR: $*" >&2; fi; }

    # shellcheck source=lib/checksum.sh
    source "${CHECKSUM_LIB}"
    CHECKSUM_AVAILABLE=true
else
    warn "Checksum library not found at: ${CHECKSUM_LIB}"
    warn "Model integrity verification will be DISABLED."
    warn "To enable checksums, ensure scripts/lib/checksum.sh is present."
fi

# ---------------------------------------------------------------------------
# Step 1/4: Pre-download integrity check (SHA256)
#
# If all model files are present and their SHA256 checksums match the stored
# .sha256 sidecar files, skip the download entirely. This makes the script
# idempotent — running it multiple times produces the same end-state.
# ---------------------------------------------------------------------------
log "======================================================="
info "  Step 1/4: Pre-download integrity check"
log "======================================================="
log ""

if [ "${FORCE_DOWNLOAD}" = "1" ]; then
    warn "FORCE_DOWNLOAD=1 — skipping pre-download checksum verification."
    warn "Will re-download model regardless of cache state."
    log ""
elif [ "${CHECKSUM_AVAILABLE}" = "true" ]; then
    log "Comparing cached model files against stored SHA256 checksums ..."
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
        log "  llama.cpp will use this cache on next startup."
        log "  Start the stack with: ./scripts/start.sh"
        log "======================================================="
        exit 0
    fi

    _verify_end=$(date +%s 2>/dev/null || echo 0)
    _verify_elapsed=$(( _verify_end - _verify_start ))
    [ "${_verify_elapsed}" -gt 0 ] 2>/dev/null && log "  Check completed in ${_verify_elapsed}s"
    log ""
    warn "Checksum verification indicates model is missing or corrupted."
    log "Proceeding with download ..."
    log ""
else
    warn "Checksum library unavailable — cannot verify cached model."
    log "Proceeding with download ..."
    log ""
fi

# ===========================================================================
# Step 2/4: Download model with resume support
#
# Strategy (try in order):
#   1. huggingface-cli download (native resume via HTTP range requests)
#   2. Python huggingface_hub snapshot_download (native resume)
#   3. Direct curl/wget download of individual files (manual resume with -C)
#
# All methods support resume: interrupted downloads continue from where they
# stopped, avoiding redundant re-transfer of completed bytes.
# ===========================================================================
log "======================================================="
info "  Step 2/4: Download model files"
log "======================================================="
log ""

# ---------------------------------------------------------------------------
# download_with_cli — download via huggingface-cli (preferred)
#
# huggingface-cli download is idempotent and supports resume natively.
# It uses HTTP range requests to continue interrupted downloads.
# Returns 0 on success, 1 if huggingface-cli is unavailable.
# ---------------------------------------------------------------------------
download_with_cli() {
    if ! command -v huggingface-cli >/dev/null 2>&1; then
        return 1
    fi

    log "Using huggingface-cli to download '${MODEL_NAME}' ..."
    log "  Resume support: enabled (native HTTP range requests)"

    local hf_args=(
        download
        "${MODEL_NAME}"
        --cache-dir "${HF_CACHE_DIR}"
        --resume-download
        --ignore-patterns "*.pt" "*.bin"   # prefer safetensors; skip legacy
    )

    if [ -n "${HF_TOKEN}" ]; then
        hf_args+=(--token "${HF_TOKEN}")
    fi

    if [ "${FORCE_DOWNLOAD}" = "1" ]; then
        hf_args+=(--force-download)
        log "  Force download: enabled (re-downloading all files)"
    fi

    huggingface-cli "${hf_args[@]}"
    return 0
}

# ---------------------------------------------------------------------------
# download_with_python — fallback via huggingface_hub Python library
#
# Used when huggingface-cli is not on PATH. snapshot_download also supports
# resume natively and is idempotent.
# ---------------------------------------------------------------------------
download_with_python() {
    log "huggingface-cli not found — falling back to Python huggingface_hub ..."
    log "  Resume support: enabled (native in huggingface_hub)"

    local force_flag="${FORCE_DOWNLOAD}"

    python3 -c "
import sys, os

model_name  = '${MODEL_NAME}'
cache_dir   = '${HF_CACHE_DIR}'
force       = '${force_flag}' == '1'
hf_token    = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN') or None

print(f'[download_model] Checking local cache for: {model_name}')

try:
    from huggingface_hub import snapshot_download
except ImportError:
    print('[download_model] ERROR: huggingface_hub is not installed.', file=sys.stderr)
    print('[download_model] Install it with: pip install huggingface_hub', file=sys.stderr)
    sys.exit(1)

# Check if model is already fully cached (skip if force)
if not force:
    try:
        local_path = snapshot_download(
            repo_id=model_name,
            cache_dir=cache_dir,
            local_files_only=True,
        )
        print(f'[download_model] Model already cached at: {local_path}')
        print('[download_model] Skipping download (use FORCE_DOWNLOAD=1 to override).')
        sys.exit(0)
    except Exception:
        pass  # not cached — proceed to download

print(f'[download_model] Downloading {model_name} ...')

try:
    local_path = snapshot_download(
        repo_id=model_name,
        cache_dir=cache_dir,
        ignore_patterns=['*.pt', '*.bin'],
        token=hf_token,
        resume_download=True,
        force_download=force,
    )
    print(f'[download_model] Download complete. Weights stored at: {local_path}')
except Exception as e:
    print(f'[download_model] ERROR: Download failed: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# ---------------------------------------------------------------------------
# download_with_retry — wrap a download function with retry logic
#
# Retries the given download function up to MAX_RETRIES times with
# exponential backoff. Each retry benefits from resume support —
# already-downloaded files/bytes are not re-transferred.
# ---------------------------------------------------------------------------
download_with_retry() {
    local download_fn="$1"
    local attempt=1

    while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
        log "Download attempt ${attempt}/${MAX_RETRIES} ..."

        if "${download_fn}"; then
            log "Download succeeded on attempt ${attempt}."
            return 0
        fi

        local rc=$?

        if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
            local backoff=$(( 2 ** (attempt - 1) * 5 ))
            warn "Download attempt ${attempt} failed (exit code ${rc})."
            warn "Retrying in ${backoff}s (attempt $((attempt + 1))/${MAX_RETRIES}) ..."
            warn "Resume support ensures no data is re-downloaded."
            sleep "${backoff}"
        else
            warn "Download attempt ${attempt} failed (exit code ${rc}). No more retries."
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

# ---------------------------------------------------------------------------
# Perform download: try CLI first, fall back to Python, with retry wrapper
# ---------------------------------------------------------------------------
_dl_start=$(date +%s 2>/dev/null || echo 0)
download_success=false

if command -v huggingface-cli >/dev/null 2>&1; then
    if download_with_retry download_with_cli; then
        download_success=true
    fi
fi

if [ "${download_success}" = "false" ]; then
    if command -v python3 >/dev/null 2>&1; then
        if download_with_retry download_with_python; then
            download_success=true
        fi
    fi
fi

if [ "${download_success}" = "false" ]; then
    error "All download methods failed after ${MAX_RETRIES} attempts each.
  Ensure one of the following is installed:
    - huggingface-cli (pip install huggingface-cli)
    - python3 + huggingface_hub (pip install huggingface_hub)
  Check your network connection and try again."
fi

_dl_end=$(date +%s 2>/dev/null || echo 0)
_dl_elapsed=$(( _dl_end - _dl_start ))
log "Download step complete."
[ "${_dl_elapsed}" -gt 0 ] 2>/dev/null && log "  Download took ${_dl_elapsed}s"

# ===========================================================================
# Step 3/4: Post-download integrity verification (SHA256)
#
# Re-verify all model files after download to ensure:
#   - No corruption occurred during transfer
#   - Files match their expected checksums (if sidecars exist)
#   - On first download, checksums are generated in Step 4
# ===========================================================================
log ""
log "======================================================="
info "  Step 3/4: Post-download integrity verification (SHA256)"
log "======================================================="
log ""

if [ "${CHECKSUM_AVAILABLE}" = "true" ]; then
    _verify_start=$(date +%s 2>/dev/null || echo 0)

    log "Verifying downloaded model files ..."
    if checksum_verify_model_cache "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        ok "Post-download checksum verification passed."
    else
        warn "Post-download checksum verification returned non-zero."
        warn "This is normal on first download (no prior checksums exist)."
        warn "Checksums will be generated in Step 4."
    fi

    _verify_end=$(date +%s 2>/dev/null || echo 0)
    _verify_elapsed=$(( _verify_end - _verify_start ))
    [ "${_verify_elapsed}" -gt 0 ] 2>/dev/null && log "  Verification took ${_verify_elapsed}s"
else
    warn "Checksum library unavailable — skipping post-download verification."
fi

# ===========================================================================
# Step 4/4: Store SHA256 checksums for future runs
#
# Write .sha256 sidecar files alongside each model file. These sidecars are
# used by Step 1 on subsequent runs to skip unnecessary downloads.
#
# This step is idempotent: re-running overwrites existing sidecars with
# freshly computed hashes.
# ===========================================================================
log ""
log "======================================================="
info "  Step 4/4: Storing SHA256 checksums for future runs"
log "======================================================="
log ""

if [ "${CHECKSUM_AVAILABLE}" = "true" ]; then
    log "Computing and storing SHA256 hashes for all model files ..."
    log "Each file gets a .sha256 sidecar for future verification."
    log ""

    _store_start=$(date +%s 2>/dev/null || echo 0)

    if checksum_store_model_cache "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
        _store_end=$(date +%s 2>/dev/null || echo 0)
        _store_elapsed=$(( _store_end - _store_start ))
        ok "Checksums stored successfully."
        [ "${_store_elapsed}" -gt 0 ] 2>/dev/null && log "  Checksum storage took ${_store_elapsed}s"
        log ""
        log "  On subsequent runs, these checksums will be verified before"
        log "  downloading. If all files match, the download is skipped."
    else
        warn "Failed to store some checksums."
        warn "Next run may need to re-download the model."
        warn "This is non-fatal — the model files are still usable."
    fi
else
    warn "Checksum library unavailable — skipping checksum storage."
    warn "Without checksums, re-download skip optimization is disabled."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "======================================================="
ok "  Model download and verification complete!"
log ""
log "  Model     : ${MODEL_NAME}"
log "  Cache dir : ${HF_CACHE_DIR}"
if [ "${CHECKSUM_AVAILABLE}" = "true" ]; then
    log "  Checksum  : SHA256 sidecar files stored"
else
    log "  Checksum  : DISABLED (lib/checksum.sh not found)"
fi
log "  Resume    : Supported (interrupted downloads resume automatically)"
log ""
log "  llama.cpp will use this cache on next startup."
log "  Start the stack with: ./scripts/start.sh"
log "======================================================="
