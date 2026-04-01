#!/usr/bin/env bash
# =============================================================================
# download-model.sh — Pre-download GGUF model weights for DemoClaw (Linux)
#
# Downloads Qwen3.5-9B-Q4_K_M.gguf from HuggingFace so llama.cpp startup is
# fast — no download delay on first container run.
#
# Usage:
#   ./scripts/download-model.sh
#   ./scripts/download-model.sh --model-dir /path/to/models
#
# Environment variables:
#   MODEL_REPO      — HuggingFace repo ID (default: unsloth/Qwen3.5-9B-GGUF)
#   MODEL_FILE      — GGUF filename       (default: Qwen3.5-9B-Q4_K_M.gguf)
#   MODEL_DIR       — Local directory      (default: ~/.cache/democlaw/models)
#   HF_TOKEN        — HuggingFace token for gated models (optional)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_use_color() { [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; }

log()   { echo "[download-model] $*"; }
warn()  { if _use_color; then echo -e "\033[33m[download-model] WARNING: $*\033[0m" >&2; else echo "[download-model] WARNING: $*" >&2; fi; }
error() { if _use_color; then echo -e "\033[31m[download-model] ERROR: $*\033[0m" >&2; else echo "[download-model] ERROR: $*" >&2; fi; exit 1; }
ok()    { if _use_color; then echo -e "\033[32m[download-model] $*\033[0m"; else echo "[download-model] OK: $*"; fi; }
info()  { if _use_color; then echo -e "\033[36m[download-model] $*\033[0m"; else echo "[download-model] $*"; fi; }

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment)
# ---------------------------------------------------------------------------
MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.5-9B-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen3.5-9B-Q4_K_M.gguf}"
MODEL_DIR="${MODEL_DIR:-${HOME}/.cache/democlaw/models}"
HF_TOKEN="${HF_TOKEN:-}"

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --model-dir)   MODEL_DIR="$2"; shift 2 ;;
        --model-repo)  MODEL_REPO="$2"; shift 2 ;;
        --model-file)  MODEL_FILE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--model-dir DIR] [--model-repo REPO] [--model-file FILE]"
            exit 0
            ;;
        *) error "Unknown argument: $1" ;;
    esac
done

MODEL_PATH="${MODEL_DIR}/${MODEL_FILE}"
HF_URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
log "======================================================="
log "  DemoClaw — Model Pre-Download (GGUF)"
log "  Repo      : ${MODEL_REPO}"
log "  File      : ${MODEL_FILE}"
log "  Save to   : ${MODEL_PATH}"
log "======================================================="
log "This may take several minutes on first run (~5.7 GB download)."
log "Subsequent runs detect the cached model and finish instantly."

# ---------------------------------------------------------------------------
# Ensure model directory exists
# ---------------------------------------------------------------------------
mkdir -p "${MODEL_DIR}"

# ---------------------------------------------------------------------------
# Check if model already exists and is valid
# ---------------------------------------------------------------------------
EXPECTED_SIZE_MIN=5000000000  # ~5 GB minimum for Q4_K_M 9B

if [ -f "${MODEL_PATH}" ]; then
    file_size=$(stat -c%s "${MODEL_PATH}" 2>/dev/null || stat -f%z "${MODEL_PATH}" 2>/dev/null || echo "0")

    if [ "${file_size}" -gt "${EXPECTED_SIZE_MIN}" ]; then
        ok "Model already downloaded and valid."
        log "  Path: ${MODEL_PATH}"
        log "  Size: ${file_size} bytes"

        # Verify SHA256 if sidecar exists
        sha_file="${MODEL_PATH}.sha256"
        if [ -f "${sha_file}" ]; then
            stored_hash=$(cat "${sha_file}" | awk '{print $1}')
            log "  Verifying SHA256 checksum ..."
            if command -v sha256sum >/dev/null 2>&1; then
                computed_hash=$(sha256sum "${MODEL_PATH}" | awk '{print $1}')
            elif command -v shasum >/dev/null 2>&1; then
                computed_hash=$(shasum -a 256 "${MODEL_PATH}" | awk '{print $1}')
            else
                warn "No SHA256 tool found — skipping checksum verification."
                computed_hash="${stored_hash}"
            fi

            if [ "${computed_hash}" = "${stored_hash}" ]; then
                ok "SHA256 checksum verified."
            else
                warn "SHA256 mismatch! Re-downloading ..."
                rm -f "${MODEL_PATH}"
            fi
        fi

        # If file still exists after checksum check, we're good
        if [ -f "${MODEL_PATH}" ]; then
            log ""
            log "======================================================="
            ok "  Model ready! (verified from cache)"
            log ""
            log "  Start the stack with: ./scripts/start.sh"
            log "======================================================="
            exit 0
        fi
    else
        warn "Model file exists but appears incomplete (${file_size} bytes). Re-downloading ..."
        rm -f "${MODEL_PATH}"
    fi
fi

# ---------------------------------------------------------------------------
# Download model from HuggingFace
# ---------------------------------------------------------------------------
log ""
info "  Downloading ${MODEL_FILE} ..."
log "  URL: ${HF_URL}"
log ""

# Build curl args
curl_args=(
    -L                       # follow redirects
    --retry 3                # retry on failure
    --retry-delay 5          # wait between retries
    -C -                     # resume partial downloads
    --progress-bar           # show progress
    -o "${MODEL_PATH}.tmp"   # write to temp file
)

# Add auth header if HF_TOKEN is set
if [ -n "${HF_TOKEN}" ]; then
    curl_args+=(-H "Authorization: Bearer ${HF_TOKEN}")
    log "  Using HF_TOKEN for authenticated download."
fi

# Download
if ! curl "${curl_args[@]}" "${HF_URL}"; then
    rm -f "${MODEL_PATH}.tmp"
    error "Download failed. Check your network connection and try again."
fi

# Verify downloaded file size
tmp_size=$(stat -c%s "${MODEL_PATH}.tmp" 2>/dev/null || stat -f%z "${MODEL_PATH}.tmp" 2>/dev/null || echo "0")
if [ "${tmp_size}" -lt "${EXPECTED_SIZE_MIN}" ]; then
    rm -f "${MODEL_PATH}.tmp"
    error "Downloaded file is too small (${tmp_size} bytes). Expected >= ${EXPECTED_SIZE_MIN}. Download may be corrupted."
fi

# Move temp file to final location (atomic on same filesystem)
mv "${MODEL_PATH}.tmp" "${MODEL_PATH}"

log ""
ok "Download complete: ${MODEL_PATH} (${tmp_size} bytes)"

# ---------------------------------------------------------------------------
# Store SHA256 checksum for future verification
# ---------------------------------------------------------------------------
log ""
info "  Computing SHA256 checksum ..."

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${MODEL_PATH}" > "${MODEL_PATH}.sha256"
    ok "SHA256 checksum stored: ${MODEL_PATH}.sha256"
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${MODEL_PATH}" > "${MODEL_PATH}.sha256"
    ok "SHA256 checksum stored: ${MODEL_PATH}.sha256"
else
    warn "No SHA256 tool available — skipping checksum storage."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log ""
log "======================================================="
ok "  Model download and verification complete!"
log ""
log "  Model     : ${MODEL_FILE}"
log "  Repo      : ${MODEL_REPO}"
log "  Location  : ${MODEL_PATH}"
log ""
log "  llama.cpp will use this file on next startup."
log "  Start the stack with: ./scripts/start.sh"
log "======================================================="
