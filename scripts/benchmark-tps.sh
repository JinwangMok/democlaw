#!/usr/bin/env bash
# =============================================================================
# benchmark-tps.sh — Token generation throughput benchmark for DemoClaw LLM
#
# Measures inference throughput (tokens/second) against the llama.cpp
# OpenAI-compatible API using standardized prompts, and reports pass/fail
# against a configurable threshold.
#
# Designed for two deployment scenarios:
#   - Gemma 4 E4B on consumer GPUs (8GB VRAM)   — default threshold: 15 t/s
#   - Gemma 4 26B A4B MoE on DGX Spark (128GB)  — default threshold: 20 t/s
#
# Usage:
#   # Run against local llama.cpp server with defaults
#   ./scripts/benchmark-tps.sh
#
#   # Override threshold and endpoint
#   BENCH_MIN_TPS=20 LLAMACPP_PORT=8000 ./scripts/benchmark-tps.sh
#
#   # Use hardware detection to pick the right threshold
#   source scripts/detect-hardware.sh
#   ./scripts/benchmark-tps.sh
#
#   # JSON output for CI integration
#   BENCH_OUTPUT_FORMAT=json ./scripts/benchmark-tps.sh
#
# Environment variables:
#   LLAMACPP_PORT        — llama.cpp API port (default: 8000)
#   LLAMACPP_HOST        — llama.cpp API host (default: localhost)
#   BENCH_MIN_TPS        — Minimum tokens/second to pass (default: auto-detect)
#   BENCH_MAX_TOKENS     — Max tokens to generate per prompt (default: 128)
#   BENCH_WARMUP_TOKENS  — Tokens for warmup request (default: 32)
#   BENCH_RUNS           — Number of benchmark runs per prompt (default: 3)
#   BENCH_OUTPUT_FORMAT  — Output format: "text" or "json" (default: text)
#   HARDWARE_PROFILE     — "dgx_spark" or "consumer_gpu" (from detect-hardware.sh)
#   MODEL_NAME           — Model name for API requests (auto-detected if empty)
#
# Exit codes:
#   0 — All benchmark runs passed the threshold
#   1 — One or more runs failed the threshold or an error occurred
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging (matches project convention: [tag] message)
# ---------------------------------------------------------------------------
_bench_log()  { echo "[benchmark] $*"; }
_bench_warn() { echo "[benchmark] WARNING: $*" >&2; }
_bench_err()  { echo "[benchmark] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LLAMACPP_HOST="${LLAMACPP_HOST:-localhost}"
LLAMACPP_PORT="${LLAMACPP_PORT:-8000}"
BASE_URL="http://${LLAMACPP_HOST}:${LLAMACPP_PORT}"

BENCH_MAX_TOKENS="${BENCH_MAX_TOKENS:-128}"
BENCH_WARMUP_TOKENS="${BENCH_WARMUP_TOKENS:-32}"
BENCH_RUNS="${BENCH_RUNS:-3}"
BENCH_OUTPUT_FORMAT="${BENCH_OUTPUT_FORMAT:-text}"
BENCH_TIMEOUT="${BENCH_TIMEOUT:-120}"

# ---------------------------------------------------------------------------
# Default throughput thresholds (tokens/second) by hardware profile
# ---------------------------------------------------------------------------
# These are validated minimums — real hardware typically exceeds these.
#   consumer_gpu (8GB):  Gemma 4 E4B Q4_K_M   — expect ~20-40 t/s, min 15
#   dgx_spark (128GB):   Gemma 4 26B A4B Q4_K_M — expect ~25-50 t/s, min 20
#     (MoE with 4 active experts on 128GB unified memory, NVLink bandwidth)
readonly DEFAULT_TPS_CONSUMER_GPU=15
readonly DEFAULT_TPS_DGX_SPARK=20

# ---------------------------------------------------------------------------
# Standardized benchmark prompts
# ---------------------------------------------------------------------------
# These prompts are chosen to exercise different generation patterns:
#   1. Factual/technical — tests structured knowledge generation
#   2. Creative/narrative — tests free-form text generation
#   3. Reasoning/step-by-step — tests chain-of-thought throughput
readonly BENCH_PROMPTS=(
    "Explain how a GPU processes parallel workloads in modern deep learning training pipelines. Cover thread blocks, warps, and memory coalescing."
    "Write a short story about a robot discovering it can dream. Include dialogue and sensory descriptions."
    "A farmer has 120 meters of fencing. What dimensions should a rectangular pen have to maximize enclosed area? Show your reasoning step by step."
)
readonly BENCH_PROMPT_LABELS=(
    "technical"
    "creative"
    "reasoning"
)

# ---------------------------------------------------------------------------
# Resolve hardware-aware threshold
# ---------------------------------------------------------------------------
resolve_threshold() {
    # Explicit override takes priority
    if [ -n "${BENCH_MIN_TPS:-}" ]; then
        echo "${BENCH_MIN_TPS}"
        return 0
    fi

    # Auto-detect from HARDWARE_PROFILE if available
    case "${HARDWARE_PROFILE:-}" in
        dgx_spark)
            echo "${DEFAULT_TPS_DGX_SPARK}"
            ;;
        consumer_gpu)
            echo "${DEFAULT_TPS_CONSUMER_GPU}"
            ;;
        *)
            # Default to the more conservative threshold
            echo "${DEFAULT_TPS_DGX_SPARK}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Detect model name from /v1/models endpoint
# ---------------------------------------------------------------------------
detect_model_name() {
    if [ -n "${MODEL_NAME:-}" ]; then
        echo "${MODEL_NAME}"
        return 0
    fi

    local models_response
    models_response=$(curl -sf --max-time 10 "${BASE_URL}/v1/models" 2>/dev/null || echo "")

    if [ -z "${models_response}" ]; then
        _bench_warn "Could not query /v1/models. Using empty model name."
        echo ""
        return 0
    fi

    # Extract the first model ID
    local model_id
    model_id=$(echo "${models_response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    if models:
        print(models[0].get('id', ''))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo "")

    echo "${model_id}"
}

# ---------------------------------------------------------------------------
# Pre-flight check — verify llama.cpp is healthy and responding
# ---------------------------------------------------------------------------
preflight_check() {
    _bench_log "Pre-flight: checking llama.cpp at ${BASE_URL} ..."

    # Check /health endpoint
    local health_code
    health_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        --max-time 10 "${BASE_URL}/health" 2>/dev/null || echo "000")

    if [ "${health_code}" != "200" ]; then
        _bench_err "llama.cpp /health returned HTTP ${health_code} (expected 200)"
        _bench_err "Is the llama.cpp server running? Start with: make start"
        return 1
    fi

    _bench_log "Pre-flight: /health OK (HTTP 200)"
    return 0
}

# ---------------------------------------------------------------------------
# Warmup — send a short generation request to prime the model
# ---------------------------------------------------------------------------
warmup() {
    local model_name="${1}"
    _bench_log "Warming up model (${BENCH_WARMUP_TOKENS} tokens) ..."

    local warmup_payload
    warmup_payload=$(python3 -c "
import json, sys
model = sys.argv[1]
max_tok = int(sys.argv[2])
print(json.dumps({
    'model': model,
    'messages': [{'role': 'user', 'content': 'Hello, how are you?'}],
    'max_tokens': max_tok,
    'temperature': 0.1
}))
" "${model_name}" "${BENCH_WARMUP_TOKENS}" 2>/dev/null)

    curl -sf --max-time "${BENCH_TIMEOUT}" \
        -H "Content-Type: application/json" \
        -d "${warmup_payload}" \
        "${BASE_URL}/v1/chat/completions" >/dev/null 2>&1 || true

    _bench_log "Warmup complete."
}

# ---------------------------------------------------------------------------
# run_single_benchmark — execute one generation and measure throughput
#
# Arguments:
#   $1 — model name
#   $2 — prompt text
#   $3 — prompt label (for reporting)
#   $4 — run number
#
# Outputs to stdout: JSON object with benchmark results
# ---------------------------------------------------------------------------
run_single_benchmark() {
    local model_name="${1}"
    local prompt="${2}"
    local label="${3}"
    local run_num="${4}"

    # Build the request payload safely via python3 argv (no shell interpolation)
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'messages': [{'role': 'user', 'content': sys.argv[2]}],
    'max_tokens': int(sys.argv[3]),
    'temperature': 0.1,
    'stream': False
}))
" "${model_name}" "${prompt}" "${BENCH_MAX_TOKENS}" 2>/dev/null)

    # Measure wall-clock time for the full request
    local start_ns end_ns
    start_ns=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")

    # Write response to temp file to avoid shell escaping issues
    local tmpfile
    tmpfile=$(mktemp)

    local curl_exit=0
    curl -sf --max-time "${BENCH_TIMEOUT}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        -o "${tmpfile}" \
        "${BASE_URL}/v1/chat/completions" 2>/dev/null || curl_exit=$?

    end_ns=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")

    if [ "${curl_exit}" -ne 0 ] || [ ! -s "${tmpfile}" ]; then
        rm -f "${tmpfile}"
        echo '{"error": "empty_response", "label": "'"${label}"'", "run": '"${run_num}"'}'
        return 1
    fi

    # Parse the response and compute throughput — read from temp file via stdin
    python3 -c "
import json, sys

start_ns = int(sys.argv[1])
end_ns = int(sys.argv[2])
label = sys.argv[3]
run_num = int(sys.argv[4])

try:
    resp = json.load(sys.stdin)
except Exception:
    print(json.dumps({'error': 'parse_failed', 'label': label, 'run': run_num}))
    sys.exit(0)

usage = resp.get('usage', {})
completion_tokens = usage.get('completion_tokens', 0)
prompt_tokens = usage.get('prompt_tokens', 0)
total_tokens = usage.get('total_tokens', 0)

# Wall-clock elapsed time in seconds
elapsed_s = (end_ns - start_ns) / 1e9

# Tokens per second (generation throughput)
tps = completion_tokens / elapsed_s if elapsed_s > 0 else 0.0

result = {
    'label': label,
    'run': run_num,
    'prompt_tokens': prompt_tokens,
    'completion_tokens': completion_tokens,
    'total_tokens': total_tokens,
    'elapsed_s': round(elapsed_s, 3),
    'tokens_per_second': round(tps, 2),
    'error': None
}

print(json.dumps(result))
" "${start_ns}" "${end_ns}" "${label}" "${run_num}" < "${tmpfile}"

    rm -f "${tmpfile}"
}

# ---------------------------------------------------------------------------
# format_result_text — pretty-print a single benchmark result
# ---------------------------------------------------------------------------
format_result_text() {
    local result_json="${1}"
    local threshold="${2}"

    echo "${result_json}" | python3 -c "
import json, sys

r = json.load(sys.stdin)
threshold = float(sys.argv[1])

if r.get('error'):
    print(f'  [{r[\"label\"]}] run {r[\"run\"]}: ERROR -- {r[\"error\"]}')
    sys.exit(0)

tps = r['tokens_per_second']
status = 'PASS' if tps >= threshold else 'FAIL'
symbol = '+' if status == 'PASS' else 'x'

print(f'  [{symbol}] [{r[\"label\"]}] run {r[\"run\"]}: '
      f'{tps:.1f} t/s '
      f'({r[\"completion_tokens\"]} tokens in {r[\"elapsed_s\"]:.1f}s) '
      f'[threshold: {threshold} t/s] -- {status}')
" "${threshold}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    _bench_log "========================================================"
    _bench_log "  DemoClaw — LLM Throughput Benchmark"
    _bench_log "========================================================"

    # Pre-flight
    preflight_check || exit 1

    # Resolve model name
    local model_name
    model_name=$(detect_model_name)
    if [ -z "${model_name}" ]; then
        _bench_warn "Could not detect model name. Requests may use server default."
    fi

    # Resolve threshold
    local threshold
    threshold=$(resolve_threshold)

    local hw_profile="${HARDWARE_PROFILE:-auto}"

    _bench_log "Configuration:"
    _bench_log "  Endpoint     : ${BASE_URL}/v1/chat/completions"
    _bench_log "  Model        : ${model_name:-<server default>}"
    _bench_log "  Hardware     : ${hw_profile}"
    _bench_log "  Threshold    : ${threshold} t/s (minimum to pass)"
    _bench_log "  Max tokens   : ${BENCH_MAX_TOKENS}"
    _bench_log "  Runs/prompt  : ${BENCH_RUNS}"
    _bench_log "  Prompts      : ${#BENCH_PROMPTS[@]}"
    _bench_log "  Timeout      : ${BENCH_TIMEOUT}s per request"

    # Warmup
    warmup "${model_name}"

    _bench_log ""
    _bench_log "--- Benchmark Results ---"

    # Collect all results
    local all_results=()
    local total_runs=0
    local passed_runs=0
    local failed_runs=0
    local error_runs=0
    local tps_sum=0

    for i in "${!BENCH_PROMPTS[@]}"; do
        local prompt="${BENCH_PROMPTS[$i]}"
        local label="${BENCH_PROMPT_LABELS[$i]}"

        for run in $(seq 1 "${BENCH_RUNS}"); do
            total_runs=$((total_runs + 1))

            local result
            result=$(run_single_benchmark "${model_name}" "${prompt}" "${label}" "${run}")

            all_results+=("${result}")

            # Check for error and extract t/s in a single python call
            local has_error tps
            eval "$(echo "${result}" | python3 -c "
import json, sys
r = json.load(sys.stdin)
has_err = 'yes' if r.get('error') else 'no'
tps = r.get('tokens_per_second', 0)
print(f'has_error={has_err}')
print(f'tps={tps}')
" 2>/dev/null || echo "has_error=yes
tps=0")"

            if [ "${has_error}" = "yes" ]; then
                error_runs=$((error_runs + 1))
                if [ "${BENCH_OUTPUT_FORMAT}" = "text" ]; then
                    format_result_text "${result}" "${threshold}"
                fi
                continue
            fi

            # Accumulate for average
            tps_sum=$(python3 -c "print(${tps_sum} + ${tps})")

            local passes_threshold
            passes_threshold=$(python3 -c "print('yes' if ${tps} >= ${threshold} else 'no')")

            if [ "${passes_threshold}" = "yes" ]; then
                passed_runs=$((passed_runs + 1))
            else
                failed_runs=$((failed_runs + 1))
            fi

            if [ "${BENCH_OUTPUT_FORMAT}" = "text" ]; then
                format_result_text "${result}" "${threshold}"
            fi
        done
    done

    # Compute average t/s (excluding error runs)
    local successful_runs=$((total_runs - error_runs))
    local avg_tps="0"
    if [ "${successful_runs}" -gt 0 ]; then
        avg_tps=$(python3 -c "print(round(${tps_sum} / ${successful_runs}, 2))")
    fi

    # Determine overall verdict
    local overall_pass="true"
    if [ "${failed_runs}" -gt 0 ] || [ "${error_runs}" -gt 0 ]; then
        overall_pass="false"
    fi

    # --- Output ---
    if [ "${BENCH_OUTPUT_FORMAT}" = "json" ]; then
        # JSON output for CI integration — write results to temp file for safe parsing
        local results_tmpfile
        results_tmpfile=$(mktemp)
        printf '%s\n' "${all_results[@]}" > "${results_tmpfile}"

        python3 -c "
import json, sys

results = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                results.append(json.loads(line))
            except Exception:
                pass

summary = {
    'model': sys.argv[2],
    'hardware_profile': sys.argv[3],
    'threshold_tps': float(sys.argv[4]),
    'max_tokens': int(sys.argv[5]),
    'total_runs': int(sys.argv[6]),
    'passed': int(sys.argv[7]),
    'failed': int(sys.argv[8]),
    'errors': int(sys.argv[9]),
    'average_tps': float(sys.argv[10]),
    'overall_pass': sys.argv[11] == 'true',
    'results': results
}

print(json.dumps(summary, indent=2))
" "${results_tmpfile}" "${model_name}" "${hw_profile}" "${threshold}" \
  "${BENCH_MAX_TOKENS}" "${total_runs}" "${passed_runs}" "${failed_runs}" \
  "${error_runs}" "${avg_tps}" "${overall_pass}"

        rm -f "${results_tmpfile}"
    else
        # Text summary
        _bench_log ""
        _bench_log "========================================================"
        _bench_log "  Benchmark Summary"
        _bench_log "========================================================"
        _bench_log "  Model        : ${model_name:-<server default>}"
        _bench_log "  Hardware     : ${hw_profile}"
        _bench_log "  Threshold    : ${threshold} t/s"
        _bench_log "  Average      : ${avg_tps} t/s"
        _bench_log "  Runs         : ${total_runs} total"
        _bench_log "    Passed     : ${passed_runs}"
        _bench_log "    Failed     : ${failed_runs}"
        _bench_log "    Errors     : ${error_runs}"

        if [ "${overall_pass}" = "true" ]; then
            _bench_log ""
            _bench_log "  Result: PASS"
            _bench_log "========================================================"
        else
            _bench_log ""
            _bench_log "  Result: FAIL"
            _bench_log "========================================================"
            _bench_err "Benchmark did not meet the ${threshold} t/s threshold."
            if [ "${error_runs}" -gt 0 ]; then
                _bench_err "${error_runs} run(s) returned errors."
            fi
        fi
    fi

    # Exit code
    if [ "${overall_pass}" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Entrypoint — allow sourcing for testing or direct execution
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
