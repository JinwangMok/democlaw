#!/usr/bin/env bash
# =============================================================================
# checksum.sh — SHA256 checksum calculation, storage, and verification library
#
# Provides functions for computing SHA256 hashes of model files, storing them
# in .sha256 sidecar files, and verifying file integrity on every run.
#
# Source this file from any script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/checksum.sh"
#
# After sourcing, the following functions are available:
#   checksum_compute <file>              — compute SHA256 hash, print to stdout
#   checksum_store <file>                — compute hash and write <file>.sha256
#   checksum_verify <file>               — verify file against its .sha256 sidecar
#   checksum_verify_or_fail <file>       — verify or exit 1 with error message
#   checksum_verify_dir <dir> [pattern]  — verify all files matching pattern in dir
#   checksum_store_dir <dir> [pattern]   — store checksums for all matching files
#
# Checksum file format (compatible with sha256sum):
#   <64-char-hex-hash>  <filename>
#
# This ensures idempotent model verification: every run re-computes the hash
# and compares against the stored value, catching corruption or tampering.
# =============================================================================

# Guard against double-sourcing
if [ "${_CHECKSUM_LIB_LOADED:-}" = "true" ]; then
    return 0 2>/dev/null || true
fi
_CHECKSUM_LIB_LOADED="true"

# ---------------------------------------------------------------------------
# Logging helpers (only defined if not already set by the sourcing script)
# ---------------------------------------------------------------------------
if ! declare -f _cksum_log > /dev/null 2>&1; then
    _cksum_log()   { echo "[checksum] $*"; }
fi
if ! declare -f _cksum_warn > /dev/null 2>&1; then
    _cksum_warn()  { echo "[checksum] WARNING: $*" >&2; }
fi
if ! declare -f _cksum_error > /dev/null 2>&1; then
    _cksum_error() { echo "[checksum] ERROR: $*" >&2; }
fi

# ---------------------------------------------------------------------------
# _checksum_detect_tool — detect available SHA256 tool on this platform
#
# Sets _CHECKSUM_TOOL to one of: "sha256sum", "shasum", "openssl", "certutil"
# Returns 1 if no suitable tool is found.
# ---------------------------------------------------------------------------
_CHECKSUM_TOOL=""

_checksum_detect_tool() {
    if [ -n "${_CHECKSUM_TOOL}" ]; then
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        _CHECKSUM_TOOL="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        _CHECKSUM_TOOL="shasum"
    elif command -v openssl >/dev/null 2>&1; then
        _CHECKSUM_TOOL="openssl"
    elif command -v certutil >/dev/null 2>&1; then
        # certutil on Windows/WSL — check if it supports -hashfile
        if certutil -hashfile /dev/null SHA256 >/dev/null 2>&1 || true; then
            _CHECKSUM_TOOL="certutil"
        fi
    fi

    if [ -z "${_CHECKSUM_TOOL}" ]; then
        _cksum_error "No SHA256 tool found. Install sha256sum, shasum, or openssl."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# checksum_compute <file>
#
# Compute the SHA256 hash of a file and print it to stdout (hex string only).
# Returns 1 if the file does not exist or hashing fails.
# ---------------------------------------------------------------------------
checksum_compute() {
    local file="$1"

    if [ ! -f "${file}" ]; then
        _cksum_error "File not found: ${file}"
        return 1
    fi

    _checksum_detect_tool || return 1

    local hash=""

    case "${_CHECKSUM_TOOL}" in
        sha256sum)
            hash=$(sha256sum "${file}" | awk '{print $1}')
            ;;
        shasum)
            hash=$(shasum -a 256 "${file}" | awk '{print $1}')
            ;;
        openssl)
            hash=$(openssl dgst -sha256 "${file}" | awk '{print $NF}')
            ;;
        certutil)
            # certutil -hashfile outputs hash on the second line
            hash=$(certutil -hashfile "${file}" SHA256 2>/dev/null | sed -n '2p' | tr -d ' \r')
            ;;
        *)
            _cksum_error "Unknown checksum tool: ${_CHECKSUM_TOOL}"
            return 1
            ;;
    esac

    # Normalize to lowercase hex
    hash=$(echo "${hash}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    if [ -z "${hash}" ] || [ "${#hash}" -ne 64 ]; then
        _cksum_error "Failed to compute SHA256 hash for: ${file}"
        return 1
    fi

    echo "${hash}"
}

# ---------------------------------------------------------------------------
# checksum_store <file>
#
# Compute the SHA256 hash of <file> and write it to <file>.sha256 in the
# standard sha256sum-compatible format:
#   <hash>  <basename>
#
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
checksum_store() {
    local file="$1"

    if [ ! -f "${file}" ]; then
        _cksum_error "File not found: ${file}"
        return 1
    fi

    local hash
    hash=$(checksum_compute "${file}") || return 1

    local basename
    basename=$(basename "${file}")
    local checksum_file="${file}.sha256"

    echo "${hash}  ${basename}" > "${checksum_file}"
    _cksum_log "Stored checksum: ${checksum_file}"
    _cksum_log "  SHA256: ${hash}"
    _cksum_log "  File  : ${basename}"

    return 0
}

# ---------------------------------------------------------------------------
# checksum_read <checksum_file>
#
# Read the hash from a .sha256 sidecar file. Prints only the hex hash.
# Returns 1 if the file doesn't exist or is malformed.
# ---------------------------------------------------------------------------
checksum_read() {
    local checksum_file="$1"

    if [ ! -f "${checksum_file}" ]; then
        _cksum_error "Checksum file not found: ${checksum_file}"
        return 1
    fi

    local stored_hash
    stored_hash=$(awk '{print $1}' "${checksum_file}" | head -1 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    if [ -z "${stored_hash}" ] || [ "${#stored_hash}" -ne 64 ]; then
        _cksum_error "Malformed checksum file: ${checksum_file}"
        return 1
    fi

    echo "${stored_hash}"
}

# ---------------------------------------------------------------------------
# checksum_verify <file>
#
# Verify the SHA256 hash of <file> against the stored hash in <file>.sha256.
#
# Returns:
#   0 — hash matches
#   1 — hash mismatch (file is corrupted or tampered)
#   2 — no .sha256 file exists (first run; caller decides what to do)
#   3 — file does not exist
# ---------------------------------------------------------------------------
checksum_verify() {
    local file="$1"

    if [ ! -f "${file}" ]; then
        _cksum_error "File not found: ${file}"
        return 3
    fi

    local checksum_file="${file}.sha256"

    if [ ! -f "${checksum_file}" ]; then
        _cksum_warn "No checksum file found: ${checksum_file}"
        _cksum_warn "This is expected on first download. Generating checksum now."
        return 2
    fi

    _cksum_log "Verifying: $(basename "${file}")"

    local stored_hash
    stored_hash=$(checksum_read "${checksum_file}") || return 1

    local computed_hash
    computed_hash=$(checksum_compute "${file}") || return 1

    if [ "${computed_hash}" = "${stored_hash}" ]; then
        _cksum_log "  PASS: SHA256 matches (${computed_hash:0:16}...)"
        return 0
    else
        _cksum_error "  FAIL: SHA256 mismatch for $(basename "${file}")"
        _cksum_error "    Expected : ${stored_hash}"
        _cksum_error "    Computed : ${computed_hash}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# checksum_verify_or_fail <file>
#
# Verify file checksum. On mismatch, print error and exit 1.
# If no .sha256 file exists, generate one (first-run behavior).
# ---------------------------------------------------------------------------
checksum_verify_or_fail() {
    local file="$1"

    checksum_verify "${file}"
    local rc=$?

    case ${rc} in
        0)
            # Match — all good
            return 0
            ;;
        2)
            # No .sha256 file — first run, generate it
            _cksum_log "Generating initial checksum for: $(basename "${file}")"
            checksum_store "${file}" || {
                _cksum_error "Failed to generate checksum for: ${file}"
                exit 1
            }
            return 0
            ;;
        3)
            _cksum_error "Model file missing: ${file}"
            exit 1
            ;;
        *)
            _cksum_error "Checksum verification FAILED for: ${file}"
            _cksum_error "The file may be corrupted. Delete it and re-download."
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# checksum_store_dir <dir> [glob_pattern]
#
# Compute and store SHA256 checksums for all files matching the glob pattern
# in the specified directory. Default pattern: *.safetensors *.bin *.gguf
#
# Skips files that already have a valid .sha256 sidecar with a matching hash.
# Returns 0 on success, 1 if any file fails.
# ---------------------------------------------------------------------------
checksum_store_dir() {
    local dir="$1"
    local patterns="${2:-*.safetensors *.bin *.gguf *.json}"

    if [ ! -d "${dir}" ]; then
        _cksum_error "Directory not found: ${dir}"
        return 1
    fi

    local count=0
    local failed=0

    for pattern in ${patterns}; do
        # Use find to handle patterns safely
        while IFS= read -r -d '' file; do
            # Skip .sha256 files themselves
            case "${file}" in *.sha256) continue ;; esac

            count=$((count + 1))
            checksum_store "${file}" || failed=$((failed + 1))
        done < <(find "${dir}" -maxdepth 1 -name "${pattern}" -type f -print0 2>/dev/null)
    done

    _cksum_log "Stored checksums: ${count} files processed, ${failed} failures"

    if [ "${failed}" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# checksum_verify_dir <dir> [glob_pattern]
#
# Verify SHA256 checksums for all files matching the glob pattern in the
# specified directory. Files without .sha256 sidecars get checksums generated.
#
# Returns 0 if all files pass, 1 if any file fails verification.
# ---------------------------------------------------------------------------
checksum_verify_dir() {
    local dir="$1"
    local patterns="${2:-*.safetensors *.bin *.gguf *.json}"

    if [ ! -d "${dir}" ]; then
        _cksum_error "Directory not found: ${dir}"
        return 1
    fi

    local total=0
    local passed=0
    local generated=0
    local failed=0

    _cksum_log "Verifying checksums in: ${dir}"

    for pattern in ${patterns}; do
        while IFS= read -r -d '' file; do
            # Skip .sha256 files themselves
            case "${file}" in *.sha256) continue ;; esac

            total=$((total + 1))

            checksum_verify "${file}"
            local rc=$?

            case ${rc} in
                0)
                    passed=$((passed + 1))
                    ;;
                2)
                    # No checksum file — generate one
                    if checksum_store "${file}"; then
                        generated=$((generated + 1))
                    else
                        failed=$((failed + 1))
                    fi
                    ;;
                *)
                    failed=$((failed + 1))
                    ;;
            esac
        done < <(find "${dir}" -maxdepth 1 -name "${pattern}" -type f -print0 2>/dev/null)
    done

    _cksum_log "Verification summary: ${total} files"
    _cksum_log "  Passed    : ${passed}"
    _cksum_log "  Generated : ${generated} (first run)"
    _cksum_log "  Failed    : ${failed}"

    if [ "${failed}" -gt 0 ]; then
        _cksum_error "${failed} file(s) failed checksum verification!"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# checksum_verify_model_cache <cache_dir> <model_name>
#
# Verify all model files for a specific HuggingFace model in the cache.
# Resolves the model snapshot directory from the HF cache layout:
#   <cache_dir>/hub/models--<org>--<name>/snapshots/<revision>/
#
# Returns 0 if all files pass, 1 on any failure.
# ---------------------------------------------------------------------------
checksum_verify_model_cache() {
    local cache_dir="$1"
    local model_name="$2"

    # Convert model name to HF cache directory format: org/name -> models--org--name
    local cache_name
    cache_name="models--$(echo "${model_name}" | tr '/' '--')"

    local model_dir="${cache_dir}/hub/${cache_name}"

    if [ ! -d "${model_dir}" ]; then
        _cksum_warn "Model cache directory not found: ${model_dir}"
        _cksum_warn "Model may not have been downloaded yet."
        return 1
    fi

    # Find the latest snapshot directory
    local snapshot_dir
    snapshot_dir=$(find "${model_dir}/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)

    if [ -z "${snapshot_dir}" ] || [ ! -d "${snapshot_dir}" ]; then
        _cksum_warn "No model snapshots found in: ${model_dir}/snapshots"
        return 1
    fi

    _cksum_log "Model cache: ${model_name}"
    _cksum_log "Snapshot   : $(basename "${snapshot_dir}")"

    # Verify safetensors and other model files
    checksum_verify_dir "${snapshot_dir}" "*.safetensors *.json"
}

# ---------------------------------------------------------------------------
# checksum_resolve_snapshot_dir <cache_dir> <model_name>
#
# Resolve the HuggingFace model snapshot directory. Prints the path to stdout.
# Returns 1 if the model cache or snapshot directory does not exist.
# ---------------------------------------------------------------------------
checksum_resolve_snapshot_dir() {
    local cache_dir="$1"
    local model_name="$2"

    local cache_name
    cache_name="models--$(echo "${model_name}" | tr '/' '--')"
    local model_dir="${cache_dir}/hub/${cache_name}"

    if [ ! -d "${model_dir}" ]; then
        return 1
    fi

    local snapshot_dir
    snapshot_dir=$(find "${model_dir}/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)

    if [ -z "${snapshot_dir}" ] || [ ! -d "${snapshot_dir}" ]; then
        return 1
    fi

    echo "${snapshot_dir}"
}

# ---------------------------------------------------------------------------
# checksum_model_needs_download <cache_dir> <model_name>
#
# Determines whether a model needs to be (re-)downloaded by comparing existing
# model files against their stored SHA256 checksums.
#
# Decision logic:
#   1. If no snapshot directory exists         -> needs download (return 0)
#   2. If no .safetensors files are present    -> needs download (return 0)
#   3. If any .sha256 sidecar is missing       -> needs download (return 0)
#   4. If any file's hash mismatches its sidecar -> needs download (return 0)
#   5. If ALL files pass checksum verification -> skip download (return 1)
#
# Returns:
#   0 — download IS needed (no valid cached model, or checksum mismatch)
#   1 — download is NOT needed (all files present and checksums match)
#
# Callers should use it like:
#   if checksum_model_needs_download "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
#       # perform download
#   else
#       echo "Model already cached and verified — skipping download."
#   fi
# ---------------------------------------------------------------------------
checksum_model_needs_download() {
    local cache_dir="$1"
    local model_name="$2"

    _cksum_log "Checking if model '${model_name}' needs download ..."

    # Step 1: Resolve snapshot directory
    local snapshot_dir
    snapshot_dir=$(checksum_resolve_snapshot_dir "${cache_dir}" "${model_name}") || {
        _cksum_log "  No cached snapshot found — download needed."
        return 0
    }

    _cksum_log "  Found snapshot: $(basename "${snapshot_dir}")"

    # Step 2: Check for .safetensors model files
    local model_files
    model_files=$(find "${snapshot_dir}" -maxdepth 1 -name "*.safetensors" -type f 2>/dev/null)

    if [ -z "${model_files}" ]; then
        _cksum_log "  No .safetensors files found — download needed."
        return 0
    fi

    # Step 3: Verify each model file against its .sha256 sidecar
    local all_pass=true

    while IFS= read -r file; do
        [ -z "${file}" ] && continue

        local checksum_file="${file}.sha256"

        # 3a. Missing sidecar -> needs download
        if [ ! -f "${checksum_file}" ]; then
            _cksum_log "  Missing checksum for: $(basename "${file}") — download needed."
            all_pass=false
            break
        fi

        # 3b. Compute current hash and compare
        local stored_hash
        stored_hash=$(checksum_read "${checksum_file}") || {
            _cksum_log "  Malformed checksum for: $(basename "${file}") — download needed."
            all_pass=false
            break
        }

        local computed_hash
        computed_hash=$(checksum_compute "${file}") || {
            _cksum_log "  Failed to hash: $(basename "${file}") — download needed."
            all_pass=false
            break
        }

        if [ "${computed_hash}" != "${stored_hash}" ]; then
            _cksum_log "  Checksum MISMATCH for: $(basename "${file}")"
            _cksum_log "    Expected : ${stored_hash}"
            _cksum_log "    Computed : ${computed_hash}"
            _cksum_log "  Re-download needed."
            all_pass=false
            break
        fi

        _cksum_log "  PASS: $(basename "${file}") (${computed_hash:0:12}...)"
    done <<< "${model_files}"

    if [ "${all_pass}" = "true" ]; then
        # Also verify key JSON config files
        local json_pass=true
        while IFS= read -r -d '' jfile; do
            local jchecksum="${jfile}.sha256"
            if [ -f "${jchecksum}" ]; then
                checksum_verify "${jfile}" > /dev/null 2>&1
                local rc=$?
                if [ "${rc}" -eq 1 ]; then
                    _cksum_log "  JSON config checksum mismatch: $(basename "${jfile}") — download needed."
                    json_pass=false
                    break
                fi
            fi
        done < <(find "${snapshot_dir}" -maxdepth 1 -type f \( -name "config.json" -o -name "tokenizer.json" \) -print0 2>/dev/null)

        if [ "${json_pass}" = "true" ]; then
            _cksum_log "  All checksums verified — model is intact. Skipping download."
            return 1  # 1 = download NOT needed
        fi
    fi

    return 0  # 0 = download IS needed
}

# ---------------------------------------------------------------------------
# checksum_store_model_cache <cache_dir> <model_name>
#
# After a successful model download, compute and store SHA256 checksums for
# all model files in the snapshot directory. This creates the .sha256 sidecar
# files needed by checksum_model_needs_download() on subsequent runs.
#
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
checksum_store_model_cache() {
    local cache_dir="$1"
    local model_name="$2"

    _cksum_log "Storing checksums for model '${model_name}' ..."

    local snapshot_dir
    snapshot_dir=$(checksum_resolve_snapshot_dir "${cache_dir}" "${model_name}") || {
        _cksum_error "Cannot store checksums — no snapshot directory found for '${model_name}'"
        return 1
    }

    _cksum_log "  Snapshot: $(basename "${snapshot_dir}")"

    # Store checksums for model weight files and key JSON configs
    checksum_store_dir "${snapshot_dir}" "*.safetensors *.json"
}
