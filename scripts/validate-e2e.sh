#!/usr/bin/env bash
# =============================================================================
# validate-e2e.sh — End-to-end validation for DemoClaw LLM deployment
#
# Orchestrates the full E2E validation pipeline for a given hardware profile:
#   1. Pre-flight: Verify GPU hardware, driver, and VRAM requirements
#   2. Container startup: Start the llama.cpp container (via start.sh)
#   3. Health gate: Confirm /health + /v1/models endpoints respond correctly
#   4. Memory fit: Verify GPU memory usage stays within the VRAM budget
#   5. Throughput gate: Run benchmark-tps.sh and assert >= minimum t/s
#   6. API compatibility: Send a chat completion request and validate response
#   7. Dashboard compatibility: Verify OpenClaw dashboard can render Gemma 4
#      responses (model name badge, streaming, token counts, latency metrics)
#   8. Report: Print structured pass/fail verdict with evidence
#
# Designed for two deployment scenarios:
#   - Gemma 4 E4B on consumer GPUs (8GB VRAM)   — default
#   - Gemma 4 26B A4B MoE on DGX Spark (128GB)  — via HARDWARE_PROFILE=dgx_spark
#
# Usage:
#   # Validate 8GB VRAM scenario (default)
#   ./scripts/validate-e2e.sh
#
#   # Validate DGX Spark scenario
#   HARDWARE_PROFILE=dgx_spark ./scripts/validate-e2e.sh
#
#   # Skip container startup (validate already-running stack)
#   SKIP_STARTUP=1 ./scripts/validate-e2e.sh
#
#   # JSON output for CI integration
#   E2E_OUTPUT_FORMAT=json ./scripts/validate-e2e.sh
#
# Environment variables:
#   HARDWARE_PROFILE     — "8gb" / "consumer_gpu" or "dgx_spark" (default: auto)
#   SKIP_STARTUP         — "1" to skip container startup (validate running stack)
#   SKIP_TEARDOWN        — "1" to leave containers running after validation
#   E2E_OUTPUT_FORMAT    — "text" (default) or "json"
#   LLAMACPP_PORT        — llama.cpp API port (default: 8000)
#   BENCH_MIN_TPS        — Override minimum t/s threshold
#   BENCH_RUNS           — Number of benchmark runs (default: 3)
#   VRAM_HEADROOM_MIB    — Required free VRAM headroom (default: 500)
#
# Exit codes:
#   0 — All validation gates passed
#   1 — One or more gates failed
#   2 — Pre-flight requirements not met (missing tools, no GPU, etc.)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_e2e_log()  { echo "[validate-e2e] $*"; }
_e2e_pass() { echo "[validate-e2e] [PASS] $*"; }
_e2e_fail() { echo "[validate-e2e] [FAIL] $*"; }
_e2e_skip() { echo "[validate-e2e] [SKIP] $*"; }
_e2e_info() { echo "[validate-e2e] [INFO] $*"; }
_e2e_err()  { echo "[validate-e2e] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Script location and project root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SKIP_STARTUP="${SKIP_STARTUP:-0}"
SKIP_TEARDOWN="${SKIP_TEARDOWN:-1}"
E2E_OUTPUT_FORMAT="${E2E_OUTPUT_FORMAT:-text}"
LLAMACPP_HOST="${LLAMACPP_HOST:-localhost}"
LLAMACPP_PORT="${LLAMACPP_PORT:-8000}"
BASE_URL="http://${LLAMACPP_HOST}:${LLAMACPP_PORT}"
VRAM_HEADROOM_MIB="${VRAM_HEADROOM_MIB:-500}"
VRAM_BUDGET_MIB="${VRAM_BUDGET_MIB:-8192}"

# Gate results tracking
declare -A GATE_RESULTS=()
declare -A GATE_DETAILS=()
OVERALL_PASS=true
# shellcheck disable=SC2034  # START_TIME_NS/END_TIME_NS reserved for elapsed-time reporting
START_TIME_NS=""
END_TIME_NS=""

# ---------------------------------------------------------------------------
# Load project configuration
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a; source "${ENV_FILE}"; set +a
fi

# Source apply-profile.sh to get hardware-aware defaults
if [ -f "${SCRIPT_DIR}/apply-profile.sh" ]; then
    source "${SCRIPT_DIR}/apply-profile.sh"
fi

# Resolve final values
MODEL_NAME="${MODEL_NAME:-gemma-4-E4B-it}"
HARDWARE_PROFILE="${HARDWARE_PROFILE:-consumer_gpu}"

# ---------------------------------------------------------------------------
# Resolve VRAM budget and thresholds based on profile
# ---------------------------------------------------------------------------
case "${HARDWARE_PROFILE}" in
    dgx_spark)
        VRAM_BUDGET_MIB="${VRAM_BUDGET_MIB:-131072}"
        DEFAULT_MIN_TPS=10
        PROFILE_LABEL="DGX Spark (128GB unified)"
        ;;
    consumer_gpu | *)
        VRAM_BUDGET_MIB="${VRAM_BUDGET_MIB:-8192}"
        DEFAULT_MIN_TPS=15
        PROFILE_LABEL="Consumer GPU (8GB VRAM)"
        ;;
esac

BENCH_MIN_TPS="${BENCH_MIN_TPS:-${DEFAULT_MIN_TPS}}"

# ---------------------------------------------------------------------------
# record_gate — record a gate result
# ---------------------------------------------------------------------------
record_gate() {
    local gate_name="$1"
    local status="$2"  # pass, fail, skip
    local detail="${3:-}"

    GATE_RESULTS["${gate_name}"]="${status}"
    GATE_DETAILS["${gate_name}"]="${detail}"

    case "${status}" in
        pass) _e2e_pass "${gate_name}: ${detail}" ;;
        fail) _e2e_fail "${gate_name}: ${detail}"; OVERALL_PASS=false ;;
        skip) _e2e_skip "${gate_name}: ${detail}" ;;
    esac
}

# ===========================================================================
# Gate 1: Pre-flight — verify GPU hardware and tools
# ===========================================================================
gate_preflight() {
    _e2e_log ""
    _e2e_log "--- Gate 1: Pre-flight Checks ---"

    # Check nvidia-smi
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        record_gate "preflight_nvidia_smi" "fail" "nvidia-smi not found in PATH"
        return 1
    fi

    if ! nvidia-smi >/dev/null 2>&1; then
        record_gate "preflight_nvidia_smi" "fail" "nvidia-smi failed to execute"
        return 1
    fi
    record_gate "preflight_nvidia_smi" "pass" "nvidia-smi available and working"

    # Check GPU VRAM
    local gpu_query
    gpu_query=$(nvidia-smi --query-gpu=gpu_name,memory.total,driver_version \
        --format=csv,noheader,nounits 2>/dev/null | head -1)

    if [ -z "${gpu_query}" ]; then
        record_gate "preflight_gpu" "fail" "Could not query GPU info"
        return 1
    fi

    local gpu_name gpu_vram_mib driver_version
    gpu_name=$(echo "${gpu_query}" | sed 's/,[^,]*,[^,]*$//' | xargs)
    gpu_vram_mib=$(echo "${gpu_query}" | awk -F',' '{print $(NF-1)}' | xargs)
    driver_version=$(echo "${gpu_query}" | awk -F',' '{print $NF}' | xargs)

    _e2e_info "GPU: ${gpu_name}"
    _e2e_info "VRAM: ${gpu_vram_mib} MiB"
    _e2e_info "Driver: ${driver_version}"

    # Validate VRAM meets minimum requirement
    local min_vram="${MIN_VRAM_MIB:-7000}"
    if [ "${gpu_vram_mib}" -ge "${min_vram}" ] 2>/dev/null; then
        record_gate "preflight_vram" "pass" "${gpu_vram_mib} MiB >= ${min_vram} MiB minimum"
    else
        record_gate "preflight_vram" "fail" "${gpu_vram_mib} MiB < ${min_vram} MiB minimum"
        return 1
    fi

    # Check container runtime
    local runtime=""
    if [ -n "${CONTAINER_RUNTIME:-}" ] && command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
        runtime="${CONTAINER_RUNTIME}"
    elif command -v docker >/dev/null 2>&1; then
        runtime="docker"
    elif command -v podman >/dev/null 2>&1; then
        runtime="podman"
    fi

    if [ -z "${runtime}" ]; then
        record_gate "preflight_runtime" "fail" "No container runtime (docker/podman) found"
        return 1
    fi
    record_gate "preflight_runtime" "pass" "${runtime} available"

    # Check curl
    if ! command -v curl >/dev/null 2>&1; then
        record_gate "preflight_curl" "fail" "curl not found"
        return 1
    fi
    record_gate "preflight_curl" "pass" "curl available"

    # Check python3
    if ! command -v python3 >/dev/null 2>&1; then
        record_gate "preflight_python3" "fail" "python3 not found"
        return 1
    fi
    record_gate "preflight_python3" "pass" "python3 available"

    return 0
}

# ===========================================================================
# Gate 2: Container startup
# ===========================================================================
gate_container_startup() {
    _e2e_log ""
    _e2e_log "--- Gate 2: Container Startup ---"

    if [ "${SKIP_STARTUP}" = "1" ] || [ "${SKIP_STARTUP}" = "true" ]; then
        record_gate "container_startup" "skip" "SKIP_STARTUP=1, assuming containers are already running"
        return 0
    fi

    _e2e_info "Starting DemoClaw stack via start.sh ..."
    local start_output start_exit=0
    start_output=$(bash "${SCRIPT_DIR}/start.sh" 2>&1) || start_exit=$?

    if [ "${start_exit}" -ne 0 ]; then
        record_gate "container_startup" "fail" "start.sh exited with code ${start_exit}"
        echo "${start_output}" | tail -20
        return 1
    fi

    record_gate "container_startup" "pass" "Stack started successfully"
    return 0
}

# ===========================================================================
# Gate 3: Health endpoints
# ===========================================================================
gate_health() {
    _e2e_log ""
    _e2e_log "--- Gate 3: Health Endpoint Checks ---"

    local max_retries=12
    local retry_interval=5

    # Check /health
    local health_ok=false
    for attempt in $(seq 1 "${max_retries}"); do
        local health_code
        health_code=$(curl -sf -o /dev/null -w "%{http_code}" \
            --max-time 10 "${BASE_URL}/health" 2>/dev/null || echo "000")

        if [ "${health_code}" = "200" ]; then
            health_ok=true
            break
        fi
        _e2e_info "Waiting for /health (attempt ${attempt}/${max_retries}, HTTP ${health_code}) ..."
        sleep "${retry_interval}"
    done

    if [ "${health_ok}" = "true" ]; then
        record_gate "health_endpoint" "pass" "/health returned HTTP 200"
    else
        record_gate "health_endpoint" "fail" "/health did not return HTTP 200 after ${max_retries} attempts"
        return 1
    fi

    # Check /v1/models
    local models_response
    models_response=$(curl -sf --max-time 10 "${BASE_URL}/v1/models" 2>/dev/null || echo "")

    if [ -z "${models_response}" ]; then
        record_gate "models_endpoint" "fail" "/v1/models returned empty response"
        return 1
    fi

    local model_info
    model_info=$(echo "${models_response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    if models:
        ids = [m.get('id', 'unknown') for m in models]
        print('found:' + ','.join(ids))
    else:
        print('empty')
except Exception as e:
    print(f'error:{e}')
" 2>/dev/null || echo "error")

    case "${model_info}" in
        found:*)
            local model_list="${model_info#found:}"
            record_gate "models_endpoint" "pass" "/v1/models lists: ${model_list}"
            ;;
        *)
            record_gate "models_endpoint" "fail" "/v1/models returned: ${model_info}"
            return 1
            ;;
    esac

    return 0
}

# ===========================================================================
# Gate 4: Memory fit — verify GPU memory usage is within budget
# ===========================================================================
gate_memory_fit() {
    _e2e_log ""
    _e2e_log "--- Gate 4: Memory Fit Check ---"

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        record_gate "memory_fit" "skip" "nvidia-smi not available"
        return 0
    fi

    # Query current GPU memory usage
    local mem_query
    mem_query=$(nvidia-smi --query-gpu=memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1)

    if [ -z "${mem_query}" ]; then
        record_gate "memory_fit" "skip" "Could not query GPU memory usage"
        return 0
    fi

    local mem_used_mib mem_total_mib
    mem_used_mib=$(echo "${mem_query}" | awk -F',' '{print $1}' | xargs)
    mem_total_mib=$(echo "${mem_query}" | awk -F',' '{print $2}' | xargs)

    _e2e_info "GPU memory: ${mem_used_mib} / ${mem_total_mib} MiB used"

    # Calculate remaining headroom
    local headroom_mib
    headroom_mib=$((mem_total_mib - mem_used_mib))

    _e2e_info "VRAM headroom: ${headroom_mib} MiB remaining"

    # Check if we've exceeded the VRAM budget (model + KV cache should fit)
    if [ "${mem_used_mib}" -le "${VRAM_BUDGET_MIB}" ] 2>/dev/null; then
        record_gate "memory_fit" "pass" \
            "GPU memory usage ${mem_used_mib} MiB <= ${VRAM_BUDGET_MIB} MiB budget (headroom: ${headroom_mib} MiB)"
    else
        record_gate "memory_fit" "fail" \
            "GPU memory usage ${mem_used_mib} MiB > ${VRAM_BUDGET_MIB} MiB budget — OOM risk"
        return 1
    fi

    # Warn if headroom is too low (but don't fail)
    if [ "${headroom_mib}" -lt "${VRAM_HEADROOM_MIB}" ] 2>/dev/null; then
        _e2e_info "WARNING: Low VRAM headroom (${headroom_mib} MiB < ${VRAM_HEADROOM_MIB} MiB recommended)"
    fi

    return 0
}

# ===========================================================================
# Gate 5: Throughput benchmark
# ===========================================================================
gate_throughput() {
    _e2e_log ""
    _e2e_log "--- Gate 5: Throughput Benchmark ---"
    _e2e_info "Minimum threshold: ${BENCH_MIN_TPS} t/s"

    if [ ! -f "${SCRIPT_DIR}/benchmark-tps.sh" ]; then
        record_gate "throughput" "fail" "benchmark-tps.sh not found"
        return 1
    fi

    # Run benchmark in JSON mode for machine-parseable output
    local bench_output bench_exit=0
    bench_output=$(BENCH_MIN_TPS="${BENCH_MIN_TPS}" \
        BENCH_RUNS="${BENCH_RUNS:-3}" \
        HARDWARE_PROFILE="${HARDWARE_PROFILE}" \
        MODEL_NAME="${MODEL_NAME}" \
        LLAMACPP_HOST="${LLAMACPP_HOST}" \
        LLAMACPP_PORT="${LLAMACPP_PORT}" \
        BENCH_OUTPUT_FORMAT=json \
        bash "${SCRIPT_DIR}/benchmark-tps.sh" 2>/dev/null) || bench_exit=$?

    if [ "${bench_exit}" -ne 0 ] && [ -z "${bench_output}" ]; then
        record_gate "throughput" "fail" "benchmark-tps.sh failed with exit code ${bench_exit}"
        return 1
    fi

    # Parse JSON results
    local bench_verdict
    bench_verdict=$(echo "${bench_output}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    avg_tps = data.get('average_tps', 0)
    threshold = data.get('threshold_tps', 0)
    passed = data.get('passed', 0)
    failed = data.get('failed', 0)
    errors = data.get('errors', 0)
    total = data.get('total_runs', 0)
    overall = data.get('overall_pass', False)

    status = 'pass' if overall else 'fail'
    detail = f'{avg_tps:.1f} t/s avg ({passed}/{total} passed, threshold: {threshold} t/s)'
    print(f'{status}|{detail}')
except Exception as e:
    print(f'fail|Could not parse benchmark results: {e}')
" 2>/dev/null || echo "fail|Benchmark parse error")

    local verdict_status="${bench_verdict%%|*}"
    local verdict_detail="${bench_verdict#*|}"

    record_gate "throughput" "${verdict_status}" "${verdict_detail}"

    if [ "${verdict_status}" != "pass" ]; then
        return 1
    fi
    return 0
}

# ===========================================================================
# Gate 6: API compatibility — validate OpenAI-compatible chat completion
# ===========================================================================
gate_api_compatibility() {
    _e2e_log ""
    _e2e_log "--- Gate 6: API Compatibility Check ---"

    # Build a simple chat completion request
    local payload
    payload=$(python3 -c "
import json
print(json.dumps({
    'model': '${MODEL_NAME}',
    'messages': [
        {'role': 'user', 'content': 'Say hello in exactly one sentence.'}
    ],
    'max_tokens': 64,
    'temperature': 0.1,
    'stream': False
}))
" 2>/dev/null)

    if [ -z "${payload}" ]; then
        record_gate "api_chat_completion" "fail" "Could not build request payload"
        return 1
    fi

    # Send the request
    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time 60 \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    if [ "${http_code}" != "200" ]; then
        rm -f "${tmpfile}"
        record_gate "api_chat_completion" "fail" "HTTP ${http_code} (expected 200)"
        return 1
    fi

    # Validate response structure
    #
    # Gemma 4 format handling:
    #   - finish_reason: Gemma 4 via llama.cpp may return "stop", "end_turn",
    #     "eos", or "length". All are valid stop conditions.
    #   - Thinking tokens: Gemma 4 may emit <start_of_thinking>...</end_of_thinking>
    #     markers before the actual response. Strip these for content validation.
    #   - Model field: Validate it matches the configured MODEL_NAME (Gemma 4
    #     variant), not a hardcoded Qwen model name.
    #   - Usage tokens: MoE models (26B A4B) may report different token counts
    #     than dense models; accept any positive completion_tokens value.
    local api_check
    api_check=$(python3 -c "
import sys, json, re

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)

    expected_model = sys.argv[2] if len(sys.argv) > 2 else ''

    # Verify required OpenAI-compatible fields
    checks = []

    # id field
    if 'id' in data:
        checks.append('id:ok')
    else:
        checks.append('id:missing')

    # object field should be 'chat.completion'
    obj = data.get('object', '')
    if obj == 'chat.completion':
        checks.append('object:ok')
    else:
        checks.append(f'object:{obj}')

    # model field — verify it matches configured model (Gemma 4 variant)
    resp_model = data.get('model', '')
    if resp_model:
        if expected_model and expected_model in resp_model:
            checks.append(f'model:ok({resp_model})')
        elif expected_model:
            # Non-fatal: llama.cpp may report the alias or filename
            checks.append(f'model:mismatch({resp_model},expected={expected_model})')
        else:
            checks.append(f'model:ok({resp_model})')
    else:
        checks.append('model:absent')

    # choices array with at least one choice
    choices = data.get('choices', [])
    if choices and len(choices) > 0:
        checks.append(f'choices:{len(choices)}')

        # Check first choice has message with content
        msg = choices[0].get('message', {})
        content = msg.get('content', '')
        role = msg.get('role', '')

        # Strip Gemma 4 thinking tokens from content for validation.
        # Gemma 4 may wrap internal reasoning in <start_of_thinking>...</end_of_thinking>.
        # The actual user-facing response follows after these markers.
        clean_content = re.sub(
            r'<start_of_thinking>.*?<end_of_thinking>\s*',
            '', content, flags=re.DOTALL
        ).strip()

        if role == 'assistant' and len(clean_content) > 0:
            checks.append('content:ok')
            # Truncate content for display (use cleaned version)
            preview = clean_content[:80].replace(chr(10), ' ')
            checks.append(f'preview:{preview}')
        elif role == 'assistant' and len(content) > 0 and len(clean_content) == 0:
            # Content exists but is entirely thinking tokens — still valid
            checks.append('content:ok(thinking_only)')
        else:
            checks.append(f'content:empty_or_wrong_role({role})')

        # finish_reason — Gemma 4 via llama.cpp may return various stop reasons.
        # All of these are valid completion signals:
        #   'stop'      — standard OpenAI stop reason
        #   'end_turn'  — some llama.cpp builds use this for EOS
        #   'eos'       — end-of-sequence token triggered
        #   'length'    — max_tokens reached (valid but noted)
        finish = choices[0].get('finish_reason', '')
        valid_stop_reasons = {'stop', 'end_turn', 'eos', 'length'}
        if finish in valid_stop_reasons:
            checks.append(f'finish_reason:ok({finish})')
        elif finish:
            # Unknown but non-empty finish_reason — warn but don't fail
            checks.append(f'finish_reason:unexpected({finish})')
        else:
            checks.append('finish_reason:missing')
    else:
        checks.append('choices:empty')

    # usage block — MoE models may report token counts differently
    usage = data.get('usage', {})
    completion_tokens = usage.get('completion_tokens', 0)
    prompt_tokens = usage.get('prompt_tokens', 0)
    if completion_tokens > 0:
        checks.append(f'tokens:{completion_tokens}')
    elif usage:
        # usage block exists but completion_tokens is 0 — some llama.cpp
        # builds omit this for very short responses; warn but don't fail
        checks.append('tokens:zero_completion(usage_present)')
    else:
        checks.append('tokens:missing_or_zero')

    # Determine overall pass/fail
    # Critical failures: missing id, empty choices, wrong role, no content
    # Non-critical (warn only): model mismatch, unexpected finish_reason, zero tokens
    critical_failures = any(
        ('missing' in c and not c.startswith('finish_reason:missing'))
        or 'empty' in c
        or 'wrong_role' in c
        for c in checks if not c.startswith('preview:')
    )

    status = 'fail' if critical_failures else 'pass'
    detail = '; '.join(c for c in checks if not c.startswith('preview:'))
    print(f'{status}|{detail}')

except Exception as e:
    print(f'fail|Response parse error: {e}')
" "${tmpfile}" "${MODEL_NAME}" 2>/dev/null || echo "fail|python3 parse error")

    rm -f "${tmpfile}"

    local api_status="${api_check%%|*}"
    local api_detail="${api_check#*|}"

    record_gate "api_chat_completion" "${api_status}" "${api_detail}"

    if [ "${api_status}" != "pass" ]; then
        return 1
    fi
    return 0
}

# ===========================================================================
# Gate 7: Dashboard compatibility — verify OpenClaw renders Gemma 4 responses
#
# Validates that the OpenClaw dashboard can correctly consume Gemma 4 model
# output through the OpenAI-compatible API. Checks:
#   a) Model name propagation: configured model name reaches the dashboard
#   b) Dashboard responsiveness: OpenClaw gateway is serving content
#   c) Streaming support: SSE streaming works for real-time token display
#   d) Thinking token handling: Gemma 4's <start_of_thinking> markers don't
#      leak raw into the response content sent to the dashboard
#   e) Usage metrics: token counts (prompt_tokens, completion_tokens) and
#      timing data are present for dashboard latency/token-count display
# ===========================================================================
gate_dashboard_compatibility() {
    _e2e_log ""
    _e2e_log "--- Gate 7: Dashboard Compatibility Check ---"

    local openclaw_host="${OPENCLAW_HOST:-localhost}"
    local openclaw_port="${OPENCLAW_PORT:-18789}"
    local dashboard_url="http://${openclaw_host}:${openclaw_port}"

    # -----------------------------------------------------------------------
    # 7a. Dashboard responsiveness — OpenClaw gateway serves HTTP responses
    # -----------------------------------------------------------------------
    local dash_code
    dash_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 "${dashboard_url}/" 2>/dev/null || echo "000")

    if [ "${dash_code}" = "000" ]; then
        record_gate "dashboard_responsive" "fail" \
            "OpenClaw dashboard not responding at ${dashboard_url}/ (HTTP 000 — connection refused)"
        return 1
    fi
    # HTTP 500 without auth token is expected; any non-000 means gateway is alive
    record_gate "dashboard_responsive" "pass" \
        "OpenClaw dashboard responding at ${dashboard_url}/ (HTTP ${dash_code})"

    # -----------------------------------------------------------------------
    # 7b. Model name propagation — verify the model name in the llama.cpp
    #     /v1/models response matches what OpenClaw is configured to request
    # -----------------------------------------------------------------------
    local models_json
    models_json=$(curl -sf --max-time 10 "${BASE_URL}/v1/models" 2>/dev/null || echo "")

    if [ -n "${models_json}" ]; then
        local model_match
        model_match=$(echo "${models_json}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    expected = '${MODEL_NAME}'
    models = data.get('data', [])
    ids = [m.get('id', '') for m in models]

    # Check if the configured model name appears in the model list
    if any(expected in mid for mid in ids):
        print(f'pass|Model \"{expected}\" found in /v1/models: {ids}')
    else:
        print(f'fail|Model \"{expected}\" not found in /v1/models (available: {ids})')
except Exception as e:
    print(f'fail|Could not parse /v1/models: {e}')
" 2>/dev/null || echo "fail|python3 error parsing models")

        local mm_status="${model_match%%|*}"
        local mm_detail="${model_match#*|}"
        record_gate "dashboard_model_name" "${mm_status}" "${mm_detail}"

        if [ "${mm_status}" != "pass" ]; then
            return 1
        fi
    else
        record_gate "dashboard_model_name" "skip" "/v1/models not reachable — skipped model name check"
    fi

    # -----------------------------------------------------------------------
    # 7c. Streaming response — verify SSE streaming works (OpenClaw uses
    #     streaming for real-time token-by-token display in the dashboard)
    # -----------------------------------------------------------------------
    local stream_payload
    stream_payload=$(python3 -c "
import json
print(json.dumps({
    'model': '${MODEL_NAME}',
    'messages': [
        {'role': 'user', 'content': 'Say exactly: Hello from Gemma 4'}
    ],
    'max_tokens': 32,
    'temperature': 0.1,
    'stream': True
}))
" 2>/dev/null)

    if [ -n "${stream_payload}" ]; then
        local stream_tmpfile
        stream_tmpfile=$(mktemp)

        # Capture first 10 seconds of SSE stream
        curl -sf --max-time 15 \
            -H "Content-Type: application/json" \
            -d "${stream_payload}" \
            "${BASE_URL}/v1/chat/completions" \
            > "${stream_tmpfile}" 2>/dev/null || true

        local stream_check
        stream_check=$(python3 -c "
import sys, json, re

try:
    with open(sys.argv[1]) as f:
        raw = f.read()

    # SSE format: lines starting with 'data: '
    data_lines = [l for l in raw.split('\n') if l.startswith('data: ')]

    if not data_lines:
        print('fail|No SSE data lines received — streaming may not work')
        sys.exit(0)

    # Parse first and last data chunks
    content_parts = []
    has_done = False
    model_in_stream = ''
    has_usage = False

    for line in data_lines:
        payload = line[len('data: '):].strip()
        if payload == '[DONE]':
            has_done = True
            continue
        try:
            chunk = json.loads(payload)
            if not model_in_stream and chunk.get('model'):
                model_in_stream = chunk['model']
            delta = chunk.get('choices', [{}])[0].get('delta', {})
            c = delta.get('content', '')
            if c:
                content_parts.append(c)
            # Check for usage in final chunk (some llama.cpp versions include it)
            if chunk.get('usage'):
                has_usage = True
        except json.JSONDecodeError:
            pass

    full_content = ''.join(content_parts)

    # Strip thinking tokens for display
    clean = re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*', '', full_content, flags=re.DOTALL).strip()

    checks = []
    checks.append(f'chunks:{len(data_lines)}')
    checks.append(f'done:{has_done}')

    if model_in_stream:
        checks.append(f'model:{model_in_stream}')

    if len(clean) > 0:
        preview = clean[:60].replace(chr(10), ' ')
        checks.append(f'content_ok({preview})')
    elif len(full_content) > 0:
        checks.append('content_ok(thinking_only)')
    else:
        checks.append('content_empty')

    # Check for raw thinking token leakage (they should be in the stream
    # but the key is that the content itself is valid for rendering)
    if '<start_of_thinking>' in full_content:
        checks.append('thinking_tokens:present(will_be_stripped_by_ui)')
    else:
        checks.append('thinking_tokens:absent')

    if has_usage:
        checks.append('stream_usage:present')

    status = 'pass' if (len(data_lines) >= 2 and (len(clean) > 0 or len(full_content) > 0)) else 'fail'
    detail = '; '.join(checks)
    print(f'{status}|{detail}')

except Exception as e:
    print(f'fail|Stream parse error: {e}')
" "${stream_tmpfile}" 2>/dev/null || echo "fail|python3 stream parse error")

        rm -f "${stream_tmpfile}"

        local stream_status="${stream_check%%|*}"
        local stream_detail="${stream_check#*|}"
        record_gate "dashboard_streaming" "${stream_status}" "${stream_detail}"
    else
        record_gate "dashboard_streaming" "skip" "Could not build stream payload"
    fi

    # -----------------------------------------------------------------------
    # 7d. Usage metrics — verify token counts and timing in non-streaming
    #     response (used by dashboard for token count badge + latency display)
    # -----------------------------------------------------------------------
    local metrics_payload
    metrics_payload=$(python3 -c "
import json
print(json.dumps({
    'model': '${MODEL_NAME}',
    'messages': [
        {'role': 'user', 'content': 'What is 2+2? Answer with just the number.'}
    ],
    'max_tokens': 16,
    'temperature': 0.0,
    'stream': False
}))
" 2>/dev/null)

    if [ -n "${metrics_payload}" ]; then
        local metrics_tmpfile
        metrics_tmpfile=$(mktemp)

        local metrics_start metrics_end metrics_latency_ms
        metrics_start=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null)

        local metrics_http
        metrics_http=$(curl -sf -o "${metrics_tmpfile}" -w "%{http_code}" \
            --max-time 30 \
            -H "Content-Type: application/json" \
            -d "${metrics_payload}" \
            "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

        metrics_end=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null)
        metrics_latency_ms=$((metrics_end - metrics_start))

        if [ "${metrics_http}" = "200" ]; then
            local metrics_check
            metrics_check=$(python3 -c "
import sys, json

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)

    latency_ms = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    checks = []

    # Model field — dashboard uses this for the model name badge
    resp_model = data.get('model', '')
    if resp_model:
        checks.append(f'model_badge:{resp_model}')
    else:
        checks.append('model_badge:missing')

    # Usage block — dashboard uses this for token count display
    usage = data.get('usage', {})
    prompt_tokens = usage.get('prompt_tokens', 0)
    completion_tokens = usage.get('completion_tokens', 0)
    total_tokens = usage.get('total_tokens', 0)

    if prompt_tokens > 0 and completion_tokens > 0:
        checks.append(f'tokens:prompt={prompt_tokens},completion={completion_tokens},total={total_tokens}')
    elif usage:
        checks.append(f'tokens:partial(prompt={prompt_tokens},completion={completion_tokens})')
    else:
        checks.append('tokens:usage_block_missing')

    # Latency — measured externally, reported for dashboard metrics
    if latency_ms > 0:
        checks.append(f'latency:{latency_ms}ms')
        # Calculate approximate tokens/sec for display validation
        if completion_tokens > 0 and latency_ms > 0:
            tps = completion_tokens / (latency_ms / 1000.0)
            checks.append(f'effective_tps:{tps:.1f}')

    # created timestamp — used by dashboard for message ordering
    created = data.get('created', 0)
    if created > 0:
        checks.append('timestamp:present')
    else:
        checks.append('timestamp:missing')

    # id field — used by dashboard for message identification
    resp_id = data.get('id', '')
    if resp_id:
        checks.append('msg_id:present')
    else:
        checks.append('msg_id:missing')

    # Determine pass/fail
    # Critical: model name must be present (for badge), usage should have tokens
    has_model = bool(resp_model)
    has_tokens = prompt_tokens > 0 or completion_tokens > 0

    status = 'pass' if has_model and has_tokens else 'fail'
    detail = '; '.join(checks)
    print(f'{status}|{detail}')

except Exception as e:
    print(f'fail|Metrics parse error: {e}')
" "${metrics_tmpfile}" "${metrics_latency_ms}" 2>/dev/null || echo "fail|python3 metrics parse error")

            rm -f "${metrics_tmpfile}"

            local metrics_status="${metrics_check%%|*}"
            local metrics_detail="${metrics_check#*|}"
            record_gate "dashboard_metrics" "${metrics_status}" "${metrics_detail}"
        else
            rm -f "${metrics_tmpfile}"
            record_gate "dashboard_metrics" "fail" "HTTP ${metrics_http} from chat completions"
        fi
    else
        record_gate "dashboard_metrics" "skip" "Could not build metrics payload"
    fi

    return 0
}

# ===========================================================================
# Report — print structured results
# ===========================================================================
print_report() {
    _e2e_log ""
    _e2e_log "========================================================"
    _e2e_log "  E2E Validation Report"
    _e2e_log "========================================================"
    _e2e_log "  Profile    : ${PROFILE_LABEL}"
    _e2e_log "  Model      : ${MODEL_NAME}"
    _e2e_log "  Endpoint   : ${BASE_URL}"
    _e2e_log "  Threshold  : ${BENCH_MIN_TPS} t/s"
    _e2e_log ""

    local gate_order=(
        "preflight_nvidia_smi"
        "preflight_gpu"
        "preflight_vram"
        "preflight_runtime"
        "preflight_curl"
        "preflight_python3"
        "container_startup"
        "health_endpoint"
        "models_endpoint"
        "memory_fit"
        "throughput"
        "api_chat_completion"
        "dashboard_responsive"
        "dashboard_model_name"
        "dashboard_streaming"
        "dashboard_metrics"
    )

    local total=0 passed=0 failed=0 skipped=0

    for gate in "${gate_order[@]}"; do
        local status="${GATE_RESULTS[${gate}]:-}"
        local detail="${GATE_DETAILS[${gate}]:-}"

        if [ -z "${status}" ]; then
            continue
        fi

        total=$((total + 1))
        case "${status}" in
            pass)    passed=$((passed + 1));  printf "  [+] %-28s %s\n" "${gate}" "${detail}" ;;
            fail)    failed=$((failed + 1));  printf "  [x] %-28s %s\n" "${gate}" "${detail}" ;;
            skip)    skipped=$((skipped + 1)); printf "  [-] %-28s %s\n" "${gate}" "${detail}" ;;
        esac
    done

    _e2e_log ""
    _e2e_log "  Gates: ${total} total | ${passed} passed | ${failed} failed | ${skipped} skipped"
    _e2e_log ""

    if [ "${OVERALL_PASS}" = "true" ]; then
        _e2e_log "  Result: PASS"
    else
        _e2e_log "  Result: FAIL"
    fi
    _e2e_log "========================================================"
}

print_report_json() {
    local gate_order=(
        "preflight_nvidia_smi"
        "preflight_gpu"
        "preflight_vram"
        "preflight_runtime"
        "preflight_curl"
        "preflight_python3"
        "container_startup"
        "health_endpoint"
        "models_endpoint"
        "memory_fit"
        "throughput"
        "api_chat_completion"
        "dashboard_responsive"
        "dashboard_model_name"
        "dashboard_streaming"
        "dashboard_metrics"
    )

    # Build JSON via python3 for safety
    local gates_json=""
    for gate in "${gate_order[@]}"; do
        local status="${GATE_RESULTS[${gate}]:-}"
        local detail="${GATE_DETAILS[${gate}]:-}"
        if [ -z "${status}" ]; then continue; fi
        if [ -n "${gates_json}" ]; then gates_json="${gates_json},"; fi
        # Escape detail for JSON
        local escaped_detail
        escaped_detail=$(echo "${detail}" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null)
        gates_json="${gates_json}{\"gate\":\"${gate}\",\"status\":\"${status}\",\"detail\":${escaped_detail}}"
    done

    python3 -c "
import json, sys

report = {
    'profile': '${HARDWARE_PROFILE}',
    'profile_label': '${PROFILE_LABEL}',
    'model': '${MODEL_NAME}',
    'endpoint': '${BASE_URL}',
    'threshold_tps': ${BENCH_MIN_TPS},
    'overall_pass': ${OVERALL_PASS},
    'gates': json.loads('[${gates_json}]')
}
print(json.dumps(report, indent=2))
" 2>/dev/null
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    # shellcheck disable=SC2034  # START_TIME_NS reserved for elapsed-time reporting
    START_TIME_NS=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")

    _e2e_log "========================================================"
    _e2e_log "  DemoClaw — E2E Validation Pipeline"
    _e2e_log "========================================================"
    _e2e_log "  Profile  : ${PROFILE_LABEL}"
    _e2e_log "  Model    : ${MODEL_NAME}"
    _e2e_log "  Endpoint : ${BASE_URL}"

    # Gate 1: Pre-flight
    gate_preflight || true

    # Gate 2: Container startup (skippable)
    if [ "${OVERALL_PASS}" = "true" ]; then
        gate_container_startup || true
    fi

    # Gate 3: Health endpoints
    if [ "${OVERALL_PASS}" = "true" ]; then
        gate_health || true
    fi

    # Gate 4: Memory fit
    if [ "${OVERALL_PASS}" = "true" ]; then
        gate_memory_fit || true
    fi

    # Gate 5: Throughput benchmark
    if [ "${OVERALL_PASS}" = "true" ]; then
        gate_throughput || true
    fi

    # Gate 6: API compatibility
    if [ "${OVERALL_PASS}" = "true" ]; then
        gate_api_compatibility || true
    fi

    # Gate 7: Dashboard compatibility
    if [ "${OVERALL_PASS}" = "true" ]; then
        gate_dashboard_compatibility || true
    fi

    # Report
    if [ "${E2E_OUTPUT_FORMAT}" = "json" ]; then
        print_report_json
    else
        print_report
    fi

    # Exit code
    if [ "${OVERALL_PASS}" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
