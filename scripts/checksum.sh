#!/usr/bin/env bash
# =============================================================================
# checksum.sh — CLI wrapper for SHA256 checksum operations on model files
#
# This script provides a command-line interface to the checksum library
# (scripts/lib/checksum.sh). Use it for standalone checksum operations
# on Linux, macOS, and WSL2.
#
# Usage:
#   ./scripts/checksum.sh compute  <file>
#   ./scripts/checksum.sh store    <file>
#   ./scripts/checksum.sh verify   <file>
#   ./scripts/checksum.sh verify-dir  <directory> [pattern]
#   ./scripts/checksum.sh store-dir   <directory> [pattern]
#   ./scripts/checksum.sh verify-model-cache <model-name> [cache-dir]
#
# Examples:
#   ./scripts/checksum.sh compute model.safetensors
#   ./scripts/checksum.sh verify-model-cache Qwen/Qwen3-4B-AWQ
#   ./scripts/checksum.sh verify-dir ./models/ "*.safetensors"
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the checksum library
# shellcheck source=lib/checksum.sh
source "${SCRIPT_DIR}/lib/checksum.sh"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage: checksum.sh <action> [arguments]

Actions:
  compute  <file>                          Compute and print SHA256 hash
  store    <file>                          Compute hash and write .sha256 file
  verify   <file>                          Verify file against .sha256 sidecar
  verify-dir  <directory> [pattern]        Verify all matching files in directory
  store-dir   <directory> [pattern]        Store checksums for matching files
  verify-model-cache <model> [cache-dir]   Verify HF model cache checksums
  needs-download <model> [cache-dir]       Check if model needs (re-)download
  store-model-cache <model> [cache-dir]    Store checksums after model download

Default pattern: "*.safetensors *.bin *.gguf *.json"
Default cache dir: ~/.cache/huggingface
USAGE
    exit 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
    usage
fi

ACTION="$1"
shift

case "${ACTION}" in
    compute)
        [ $# -lt 1 ] && { echo "ERROR: compute requires a file path." >&2; exit 1; }
        checksum_compute "$1"
        ;;

    store)
        [ $# -lt 1 ] && { echo "ERROR: store requires a file path." >&2; exit 1; }
        checksum_store "$1"
        ;;

    verify)
        [ $# -lt 1 ] && { echo "ERROR: verify requires a file path." >&2; exit 1; }
        checksum_verify_or_fail "$1"
        ;;

    verify-dir)
        [ $# -lt 1 ] && { echo "ERROR: verify-dir requires a directory path." >&2; exit 1; }
        dir="$1"
        pattern="${2:-*.safetensors *.bin *.gguf *.json}"
        checksum_verify_dir "${dir}" "${pattern}"
        ;;

    store-dir)
        [ $# -lt 1 ] && { echo "ERROR: store-dir requires a directory path." >&2; exit 1; }
        dir="$1"
        pattern="${2:-*.safetensors *.bin *.gguf *.json}"
        checksum_store_dir "${dir}" "${pattern}"
        ;;

    verify-model-cache)
        [ $# -lt 1 ] && { echo "ERROR: verify-model-cache requires a model name." >&2; exit 1; }
        model_name="$1"
        cache_dir="${2:-${HOME}/.cache/huggingface}"
        checksum_verify_model_cache "${cache_dir}" "${model_name}"
        ;;

    needs-download)
        [ $# -lt 1 ] && { echo "ERROR: needs-download requires a model name." >&2; exit 1; }
        model_name="$1"
        cache_dir="${2:-${HOME}/.cache/huggingface}"
        if checksum_model_needs_download "${cache_dir}" "${model_name}"; then
            echo "true"
            exit 0
        else
            echo "false"
            exit 0
        fi
        ;;

    store-model-cache)
        [ $# -lt 1 ] && { echo "ERROR: store-model-cache requires a model name." >&2; exit 1; }
        model_name="$1"
        cache_dir="${2:-${HOME}/.cache/huggingface}"
        checksum_store_model_cache "${cache_dir}" "${model_name}"
        ;;

    -h|--help|help)
        usage
        ;;

    *)
        echo "ERROR: Unknown action '${ACTION}'." >&2
        usage
        ;;
esac
