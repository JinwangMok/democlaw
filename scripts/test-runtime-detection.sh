#!/usr/bin/env bash
# =============================================================================
# test-runtime-detection.sh — Unit tests for scripts/lib/runtime.sh
#
# Verifies that the container-runtime auto-detection logic works correctly:
#
#   1. Docker is preferred over podman when both are available
#   2. Podman is used when docker is absent
#   3. CONTAINER_RUNTIME env var overrides auto-detection
#   4. A clear error is printed and the process exits when no runtime exists
#   5. RUNTIME_IS_PODMAN is set correctly for each runtime
#   6. runtime_gpu_flags() returns --gpus all for docker
#   7. runtime_gpu_flags() returns CDI flags for podman >= 4
#   8. runtime_gpu_flags() returns legacy /dev/nvidia* flags for podman < 4
#   9. All orchestration scripts source lib/runtime.sh
#  10. RUNTIME and RUNTIME_IS_PODMAN are exported to the environment
#
# No GPU, container daemon, or real docker/podman installation required.
# Fake binaries are placed in a temporary directory and injected via PATH.
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed
#
# Usage:
#   ./scripts/test-runtime-detection.sh
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib/runtime.sh"

if [ ! -f "${LIB}" ]; then
    echo "ERROR: cannot find ${LIB}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Test tracking
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

_pass()    { echo "  ✓ $*";     PASS=$((PASS + 1)); }
_fail()    { echo "  ✗ $*" >&2; FAIL=$((FAIL + 1)); }
_section() { echo ""; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# make_fake_bin <dir> <name> <stdout_text>
# Creates an executable shell script in <dir> that prints <stdout_text>.
# ---------------------------------------------------------------------------
make_fake_bin() {
    local dir="$1" name="$2" out="$3"
    printf '#!/bin/sh\necho "%s"\n' "${out}" > "${dir}/${name}"
    chmod +x "${dir}/${name}"
}

# ---------------------------------------------------------------------------
# source_lib_fresh <tmpbin>
# (Re-)sources lib/runtime.sh with detection enabled, PATH prefixed with
# <tmpbin>, and logging silenced.  Must be called inside a subshell so that
# the guard variable (_RUNTIME_LIB_LOADED) is reset automatically.
#
# After sourcing, prints "RUNTIME=<value>" and "RUNTIME_IS_PODMAN=<value>"
# to stdout so the caller can capture them.
# ---------------------------------------------------------------------------
# (Implemented inline in each subshell below — avoids nested function quoting
#  complexity and keeps shellcheck happy.)

# ---------------------------------------------------------------------------
# Temporary directories for fake binaries — all cleaned up on EXIT
# ---------------------------------------------------------------------------
TMPBIN_BOTH=""
TMPBIN_PODMAN_ONLY=""
TMPBIN_EMPTY=""
TMPBIN_PODMAN4=""
TMPBIN_PODMAN3=""

TMPBIN_BOTH="$(mktemp -d)"
TMPBIN_PODMAN_ONLY="$(mktemp -d)"
TMPBIN_EMPTY="$(mktemp -d)"
TMPBIN_PODMAN4="$(mktemp -d)"
TMPBIN_PODMAN3="$(mktemp -d)"

# shellcheck disable=SC2064
trap "rm -rf '${TMPBIN_BOTH}' '${TMPBIN_PODMAN_ONLY}' '${TMPBIN_EMPTY}' '${TMPBIN_PODMAN4}' '${TMPBIN_PODMAN3}'" EXIT

# Populate fake binaries
make_fake_bin "${TMPBIN_BOTH}"         "docker" "Docker version 24.0.0, build abc1234"
make_fake_bin "${TMPBIN_BOTH}"         "podman" "podman version 4.9.3"
make_fake_bin "${TMPBIN_PODMAN_ONLY}"  "podman" "podman version 4.9.3"
make_fake_bin "${TMPBIN_PODMAN4}"      "podman" "podman version 4.9.3"
make_fake_bin "${TMPBIN_PODMAN3}"      "podman" "podman version 3.4.7"

# =============================================================================
# TEST 1 — Docker preferred when both docker and podman are in PATH
# =============================================================================
_section "Test 1: docker preferred over podman when both available"

result1=""
result1=$(
    export PATH="${TMPBIN_BOTH}:${PATH}"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
    echo "RUNTIME=${RUNTIME:-}"
    echo "RUNTIME_IS_PODMAN=${RUNTIME_IS_PODMAN:-}"
)

rt1=$(echo "${result1}"    | grep '^RUNTIME='          | cut -d= -f2-)
rip1=$(echo "${result1}"   | grep '^RUNTIME_IS_PODMAN=' | cut -d= -f2-)

if [ "${rt1}" = "docker" ]; then
    _pass "RUNTIME='docker' (docker preferred when both available)"
else
    _fail "Expected RUNTIME='docker', got '${rt1}'"
fi

if [ "${rip1}" = "false" ]; then
    _pass "RUNTIME_IS_PODMAN='false' for docker"
else
    _fail "Expected RUNTIME_IS_PODMAN='false', got '${rip1}'"
fi

# =============================================================================
# TEST 2 — Podman used as fallback when docker is absent
# =============================================================================
_section "Test 2: podman fallback when docker is absent"

result2=""
result2=$(
    export PATH="${TMPBIN_PODMAN_ONLY}:${PATH}"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
    echo "RUNTIME=${RUNTIME:-}"
    echo "RUNTIME_IS_PODMAN=${RUNTIME_IS_PODMAN:-}"
)

rt2=$(echo "${result2}"    | grep '^RUNTIME='          | cut -d= -f2-)
rip2=$(echo "${result2}"   | grep '^RUNTIME_IS_PODMAN=' | cut -d= -f2-)

if [ "${rt2}" = "podman" ]; then
    _pass "RUNTIME='podman' when docker is not in PATH"
else
    _fail "Expected RUNTIME='podman', got '${rt2}'"
fi

if [ "${rip2}" = "true" ]; then
    _pass "RUNTIME_IS_PODMAN='true' for podman"
else
    _fail "Expected RUNTIME_IS_PODMAN='true', got '${rip2}'"
fi

# =============================================================================
# TEST 3 — CONTAINER_RUNTIME env var overrides auto-detection (force podman)
# =============================================================================
_section "Test 3: CONTAINER_RUNTIME=podman overrides auto-detection"

result3a=""
result3a=$(
    export PATH="${TMPBIN_BOTH}:${PATH}"
    export CONTAINER_RUNTIME="podman"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
    echo "RUNTIME=${RUNTIME:-}"
    echo "RUNTIME_IS_PODMAN=${RUNTIME_IS_PODMAN:-}"
)

rt3a=$(echo "${result3a}" | grep '^RUNTIME=' | cut -d= -f2-)

if [ "${rt3a}" = "podman" ]; then
    _pass "CONTAINER_RUNTIME=podman override respected (docker also available)"
else
    _fail "Expected RUNTIME='podman' via override, got '${rt3a}'"
fi

result3b=""
result3b=$(
    export PATH="${TMPBIN_BOTH}:${PATH}"
    export CONTAINER_RUNTIME="docker"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
    echo "RUNTIME=${RUNTIME:-}"
)

rt3b=$(echo "${result3b}" | grep '^RUNTIME=' | cut -d= -f2-)

if [ "${rt3b}" = "docker" ]; then
    _pass "CONTAINER_RUNTIME=docker override respected (podman also available)"
else
    _fail "Expected RUNTIME='docker' via override, got '${rt3b}'"
fi

# =============================================================================
# TEST 4 — Clear error and non-zero exit when no runtime found
# =============================================================================
_section "Test 4: clear error exit when no runtime found"

err4=""
exit4=0
err4=$(
    export PATH="${TMPBIN_EMPTY}"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
) 2>&1 || exit4=$?

if [ "${exit4}" -ne 0 ]; then
    _pass "Non-zero exit when no runtime found (exit ${exit4})"
else
    _fail "Expected non-zero exit when no runtime found, got exit 0"
fi

if echo "${err4}" | grep -qi "no container runtime\|not found\|install docker\|podman"; then
    _pass "Error message mentions missing runtime (actionable)"
else
    _fail "Error message did not mention missing runtime. Output: ${err4}"
fi

# =============================================================================
# TEST 5 — CONTAINER_RUNTIME override pointing to missing binary exits clearly
# =============================================================================
_section "Test 5: invalid CONTAINER_RUNTIME value exits with clear error"

err5=""
exit5=0
err5=$(
    export PATH="${TMPBIN_EMPTY}"
    export CONTAINER_RUNTIME="nonexistent_runtime_xyz"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
) 2>&1 || exit5=$?

if [ "${exit5}" -ne 0 ]; then
    _pass "Non-zero exit when CONTAINER_RUNTIME points to missing binary"
else
    _fail "Expected non-zero exit for invalid CONTAINER_RUNTIME, got exit 0"
fi

if echo "${err5}" | grep -qi "not found\|nonexistent_runtime_xyz"; then
    _pass "Error message references the invalid CONTAINER_RUNTIME value"
else
    _fail "Error message did not reference invalid runtime. Output: ${err5}"
fi

# =============================================================================
# TEST 6 — runtime_gpu_flags() returns --gpus all for docker
# =============================================================================
_section "Test 6: runtime_gpu_flags() returns --gpus all for docker"

gpu6=""
gpu6=$(
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    _SKIP_RUNTIME_DETECT=true
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
    RUNTIME="docker"
    RUNTIME_IS_PODMAN="false"
    export RUNTIME RUNTIME_IS_PODMAN
    runtime_gpu_flags
)

if echo "${gpu6}" | grep -q -- "--gpus all"; then
    _pass "runtime_gpu_flags() returns '--gpus all' for docker"
else
    _fail "Expected '--gpus all' for docker, got: '${gpu6}'"
fi

# =============================================================================
# TEST 7 — runtime_gpu_flags() returns CDI flag for podman >= 4
# =============================================================================
_section "Test 7: runtime_gpu_flags() returns CDI flag for podman >= 4"

gpu7=""
gpu7=$(
    export PATH="${TMPBIN_PODMAN4}:${PATH}"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    _SKIP_RUNTIME_DETECT=true
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
    RUNTIME="podman"
    RUNTIME_IS_PODMAN="true"
    export RUNTIME RUNTIME_IS_PODMAN
    runtime_gpu_flags
)

if echo "${gpu7}" | grep -q "nvidia.com/gpu=all"; then
    _pass "runtime_gpu_flags() returns '--device nvidia.com/gpu=all' for podman >= 4"
else
    _fail "Expected '--device nvidia.com/gpu=all' for podman >= 4, got: '${gpu7}'"
fi

# =============================================================================
# TEST 8 — runtime_gpu_flags() returns legacy /dev/nvidia* flags for podman < 4
# =============================================================================
_section "Test 8: runtime_gpu_flags() returns /dev/nvidia* flags for podman < 4"

gpu8=""
gpu8=$(
    export PATH="${TMPBIN_PODMAN3}:${PATH}"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    _SKIP_RUNTIME_DETECT=true
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
    RUNTIME="podman"
    RUNTIME_IS_PODMAN="true"
    export RUNTIME RUNTIME_IS_PODMAN
    runtime_gpu_flags
)

if echo "${gpu8}" | grep -q "/dev/nvidia"; then
    _pass "runtime_gpu_flags() returns '/dev/nvidia*' device flags for podman < 4"
else
    _fail "Expected '/dev/nvidia*' flags for podman < 4, got: '${gpu8}'"
fi

# =============================================================================
# TEST 9 — All main scripts source lib/runtime.sh
# =============================================================================
_section "Test 9: all orchestration scripts source lib/runtime.sh"

for script in \
    "${SCRIPT_DIR}/start.sh" \
    "${SCRIPT_DIR}/start-vllm.sh" \
    "${SCRIPT_DIR}/start-openclaw.sh" \
    "${SCRIPT_DIR}/stop.sh" \
    "${SCRIPT_DIR}/healthcheck.sh" \
    "${SCRIPT_DIR}/check-gpu.sh"; do

    if grep -q "lib/runtime.sh" "${script}" 2>/dev/null; then
        _pass "$(basename "${script}") sources lib/runtime.sh"
    else
        _fail "$(basename "${script}") does NOT source lib/runtime.sh"
    fi
done

# =============================================================================
# TEST 10 — RUNTIME and RUNTIME_IS_PODMAN are exported to the environment
# =============================================================================
_section "Test 10: RUNTIME and RUNTIME_IS_PODMAN are exported"

env10=""
env10=$(
    export PATH="${TMPBIN_BOTH}:${PATH}"
    unset _RUNTIME_LIB_LOADED 2>/dev/null || true
    _rt_log()   { :; }
    _rt_warn()  { echo "[rt-warn] $*" >&2; }
    _rt_error() { echo "[rt-error] $*" >&2; exit 1; }
    # shellcheck source=lib/runtime.sh
    source "${LIB}"
    # Print the exported environment to confirm the vars are exported
    env | grep -E '^(RUNTIME|RUNTIME_IS_PODMAN)=' | sort
)

if echo "${env10}" | grep -q "^RUNTIME="; then
    _pass "RUNTIME is exported to the environment"
else
    _fail "RUNTIME is not exported. env check output: '${env10}'"
fi

if echo "${env10}" | grep -q "^RUNTIME_IS_PODMAN="; then
    _pass "RUNTIME_IS_PODMAN is exported to the environment"
else
    _fail "RUNTIME_IS_PODMAN is not exported. env check output: '${env10}'"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================================"
echo "  Runtime detection tests: ${PASS} passed, ${FAIL} failed"
echo "========================================================"
echo ""

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
exit 0
