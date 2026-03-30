#!/usr/bin/env bash
# =============================================================================
# benchmark-tps.sh — Measure llama.cpp server tokens-per-second throughput
#
# Tests the llama.cpp server (OpenAI-compatible API on port 8000) at multiple
# context lengths (4k, 16k, 32k, 64k) and measures:
#   - Prompt processing speed (prefill tokens/sec)
#   - Generation speed (decode tokens/sec)
#   - Total tokens/sec
#   - Time-to-first-token (TTFT)
#
# The script generates synthetic prompts sized to approximate each target
# context length, then requests a fixed number of completion tokens to
# measure generation throughput independently.
#
# Exit codes:
#   0 — All benchmarks completed
#   1 — Server unreachable or a benchmark failed
#
# Usage:
#   ./scripts/benchmark-tps.sh
#   LLAMA_BASE_URL=http://localhost:8000 ./scripts/benchmark-tps.sh
#   CONTEXT_LENGTHS="4096 16384" ./scripts/benchmark-tps.sh   # subset
#   COMPLETION_TOKENS=256 ./scripts/benchmark-tps.sh          # custom output len
#   OUTPUT_FORMAT=json ./scripts/benchmark-tps.sh              # JSON output
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

LLAMA_HOST_PORT="${LLAMA_HOST_PORT:-8000}"
LLAMA_BASE_URL="${LLAMA_BASE_URL:-http://localhost:${LLAMA_HOST_PORT}}"

# Model name — auto-detected from /v1/models if not specified
MODEL_NAME="${MODEL_NAME:-}"

# Context lengths to benchmark (space-separated)
CONTEXT_LENGTHS="${CONTEXT_LENGTHS:-4096 16384 32768 65536}"

# Number of completion tokens to generate at each context length
COMPLETION_TOKENS="${COMPLETION_TOKENS:-128}"

# Number of warmup requests before timing
WARMUP_REQUESTS="${WARMUP_REQUESTS:-1}"

# Output format: "table" (default) or "json"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"

# Curl timeouts (seconds)
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
# Per-benchmark timeout scales with context length; base value for 4k
BENCH_TIMEOUT_BASE="${BENCH_TIMEOUT_BASE:-120}"

# Optional API key
API_KEY="${API_KEY:-}"

# ---------------------------------------------------------------------------
# TPS Pass/Fail Thresholds (overridable via environment)
#
# Format: TPS_THRESHOLD_<context_length>=<min_tps>
# These define the minimum acceptable tokens-per-second at each context size.
# A benchmark result below its threshold is a FAIL.
# ---------------------------------------------------------------------------
TPS_THRESHOLD_4096="${TPS_THRESHOLD_4096:-30}"
TPS_THRESHOLD_16384="${TPS_THRESHOLD_16384:-20}"
TPS_THRESHOLD_32768="${TPS_THRESHOLD_32768:-15}"
TPS_THRESHOLD_65536="${TPS_THRESHOLD_65536:-10}"

# Enable/disable threshold validation (set to "false" to skip)
VALIDATE_THRESHOLDS="${VALIDATE_THRESHOLDS:-true}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

if [ ! -t 1 ]; then
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

info()    { echo -e "${CYAN}▶${NC} $*"; }
pass()    { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
header()  { echo -e "\n${BOLD}$*${NC}"; }

# ---------------------------------------------------------------------------
# Threshold lookup helper
# ---------------------------------------------------------------------------
# Returns the minimum TPS threshold for a given context length.
# Falls back to interpolating between defined thresholds, or 0 if none match.
get_tps_threshold() {
    local ctx_len="$1"
    python3 -c "
import os, sys

ctx = int(sys.argv[1])

# Defined thresholds (context_length -> min TPS)
thresholds = {
    4096:  int(os.environ.get('TPS_THRESHOLD_4096',  '30')),
    16384: int(os.environ.get('TPS_THRESHOLD_16384', '20')),
    32768: int(os.environ.get('TPS_THRESHOLD_32768', '15')),
    65536: int(os.environ.get('TPS_THRESHOLD_65536', '10')),
}

# Exact match
if ctx in thresholds:
    print(thresholds[ctx])
    sys.exit(0)

# Interpolate: find bracketing thresholds
keys = sorted(thresholds.keys())
if ctx <= keys[0]:
    print(thresholds[keys[0]])
elif ctx >= keys[-1]:
    print(thresholds[keys[-1]])
else:
    for i in range(len(keys) - 1):
        lo, hi = keys[i], keys[i + 1]
        if lo <= ctx <= hi:
            ratio = (ctx - lo) / (hi - lo)
            tps = thresholds[lo] + ratio * (thresholds[hi] - thresholds[lo])
            print(int(tps))
            break
" "${ctx_len}"
}

# ---------------------------------------------------------------------------
# Validation: compare benchmark results against thresholds
# ---------------------------------------------------------------------------
# Accepts JSON results array (one per line via args) and prints pass/fail
# per context level. Returns the number of threshold failures via stdout
# as the last line: "THRESHOLD_FAILURES=<N>"
validate_thresholds() {
    python3 -c "
import json, os, sys

results_json = sys.argv[1:]

# Threshold map
thresholds = {
    4096:  int(os.environ.get('TPS_THRESHOLD_4096',  '30')),
    16384: int(os.environ.get('TPS_THRESHOLD_16384', '20')),
    32768: int(os.environ.get('TPS_THRESHOLD_32768', '15')),
    65536: int(os.environ.get('TPS_THRESHOLD_65536', '10')),
}

def get_threshold(ctx):
    if ctx in thresholds:
        return thresholds[ctx]
    keys = sorted(thresholds.keys())
    if ctx <= keys[0]:
        return thresholds[keys[0]]
    if ctx >= keys[-1]:
        return thresholds[keys[-1]]
    for i in range(len(keys) - 1):
        lo, hi = keys[i], keys[i + 1]
        if lo <= ctx <= hi:
            ratio = (ctx - lo) / (hi - lo)
            return int(thresholds[lo] + ratio * (thresholds[hi] - thresholds[lo]))
    return 0

failures = 0
total = 0
pass_count = 0
results_detail = []

for rj in results_json:
    r = json.loads(rj)
    ctx = r.get('context_length', 0)
    threshold = get_threshold(ctx)
    total += 1

    if 'error' in r:
        failures += 1
        status = 'FAIL'
        reason = f'error: {r[\"error\"]}'
        actual_tps = 0.0
    else:
        # Use decode TPS (generation speed) as the primary metric
        # Fall back to native llama.cpp timings if available
        timings = r.get('timings', {})
        actual_tps = timings.get('predicted_per_second', r.get('decode_tps', 0))

        if actual_tps >= threshold:
            status = 'PASS'
            reason = ''
            pass_count += 1
        else:
            status = 'FAIL'
            reason = f'{actual_tps:.2f} < {threshold} TPS'
            failures += 1

    results_detail.append({
        'context_length': ctx,
        'threshold_tps': threshold,
        'actual_tps': round(actual_tps, 2),
        'status': status,
        'reason': reason,
    })

# Print validation report
print()
print('  \033[1mThreshold Validation\033[0m')
print('  ' + '-' * 60)
print(f'  {\"Context\":<10}  {\"Threshold\":>10}  {\"Actual\":>10}  {\"Status\":>8}')
print('  ' + '-' * 60)
for d in results_detail:
    ctx_label = f'{d[\"context_length\"]}'
    if d['status'] == 'PASS':
        status_str = '\033[0;32mPASS\033[0m'
    else:
        status_str = '\033[0;31mFAIL\033[0m'
    detail = f'  ({d[\"reason\"]})' if d['reason'] else ''
    print(f'  {ctx_label:<10}  {d[\"threshold_tps\"]:>8} TPS  {d[\"actual_tps\"]:>8.2f} TPS  {status_str}{detail}')
print('  ' + '-' * 60)
print(f'  Results: {pass_count}/{total} passed, {failures}/{total} failed')
print()

# Output failure count for the shell to capture
print(f'THRESHOLD_FAILURES={failures}')
" "$@"
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
for cmd in curl python3; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
        echo "ERROR: '${cmd}' is required but not found in PATH." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Build curl auth args
# ---------------------------------------------------------------------------
_CURL_AUTH_ARGS=()
case "${API_KEY:-}" in
    "" | EMPTY | none | no-auth )
        ;;
    *)
        _CURL_AUTH_ARGS=(-H "Authorization: Bearer ${API_KEY}")
        ;;
esac

# ---------------------------------------------------------------------------
# Helper: check server health
# ---------------------------------------------------------------------------
check_server() {
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        --max-time "${CURL_TIMEOUT}" \
        "${_CURL_AUTH_ARGS[@]}" \
        "${LLAMA_BASE_URL}/health" 2>/dev/null || echo "000")

    if [ "${http_code}" != "200" ]; then
        fail "Server at ${LLAMA_BASE_URL} is not reachable (HTTP ${http_code})"
        echo ""
        echo "  Ensure the llama.cpp server is running:"
        echo "    docker ps | grep llama"
        echo "    curl ${LLAMA_BASE_URL}/health"
        exit 1
    fi
    pass "Server is healthy at ${LLAMA_BASE_URL}"
}

# ---------------------------------------------------------------------------
# Helper: auto-detect model name from /v1/models
# ---------------------------------------------------------------------------
detect_model() {
    if [ -n "${MODEL_NAME}" ]; then
        return
    fi

    local response
    response=$(curl -sf --max-time "${CURL_TIMEOUT}" \
        -H "Accept: application/json" \
        "${_CURL_AUTH_ARGS[@]}" \
        "${LLAMA_BASE_URL}/v1/models" 2>/dev/null || echo "")

    MODEL_NAME=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    if models:
        print(models[0].get('id', ''))
except Exception:
    pass
" 2>/dev/null || echo "")

    if [ -z "${MODEL_NAME}" ]; then
        fail "Could not auto-detect model name from /v1/models"
        echo "  Set MODEL_NAME env var manually."
        exit 1
    fi
    pass "Detected model: ${MODEL_NAME}"
}

# ---------------------------------------------------------------------------
# Helper: generate a synthetic prompt of approximately N tokens
#
# Uses a repeated pattern of common English words. Approximate ratio:
# ~1.3 tokens per word for typical English text with GPT-style tokenizers.
# We aim slightly over to ensure we hit the target context window.
# ---------------------------------------------------------------------------
generate_prompt() {
    local target_tokens="$1"
    python3 -c "
import sys

target = int(sys.argv[1])
# Reserve tokens for system message, message framing, and completion
# Approximate 1.3 tokens per word
words_needed = int(target / 1.3)

# Use a repeating pattern of varied words to simulate realistic text
pattern = (
    'The quick brown fox jumps over the lazy dog near the river bank. '
    'In the morning light, shadows dance across the ancient stone walls '
    'of the castle that overlooks the valley below. Birds sing their songs '
    'while the wind carries the scent of wildflowers through the meadow. '
    'A traveler walks along the winding path, carrying stories from distant '
    'lands where mountains touch the clouds and rivers flow to the sea. '
    'Knowledge grows like a tree, branching out in every direction, reaching '
    'toward the light of understanding and wisdom passed through generations. '
)
pattern_words = pattern.split()
words = []
i = 0
while len(words) < words_needed:
    words.append(pattern_words[i % len(pattern_words)])
    i += 1

print(' '.join(words))
" "${target_tokens}"
}

# ---------------------------------------------------------------------------
# Helper: run a single benchmark at a given context length
#
# Returns a JSON line with results via stdout.
# Progress messages go to stderr.
# ---------------------------------------------------------------------------
run_benchmark() {
    local ctx_len="$1"
    local prompt_tokens=$((ctx_len - COMPLETION_TOKENS - 50))  # reserve for framing

    if [ "${prompt_tokens}" -lt 100 ]; then
        echo "{\"context_length\": ${ctx_len}, \"error\": \"context too small for ${COMPLETION_TOKENS} completion tokens\"}"
        return
    fi

    # Scale timeout with context length (larger contexts take longer)
    local timeout_secs=$(( BENCH_TIMEOUT_BASE * ctx_len / 4096 ))
    if [ "${timeout_secs}" -lt "${BENCH_TIMEOUT_BASE}" ]; then
        timeout_secs="${BENCH_TIMEOUT_BASE}"
    fi

    # Generate the prompt
    echo -e "  ${DIM}Generating ~${prompt_tokens}-token prompt...${NC}" >&2
    local prompt_text
    prompt_text=$(generate_prompt "${prompt_tokens}")

    # Build the request payload
    local payload
    payload=$(python3 -c "
import json, sys

prompt = sys.stdin.read()
payload = {
    'model': '${MODEL_NAME}',
    'messages': [
        {'role': 'system', 'content': 'You are a helpful assistant. Respond naturally.'},
        {'role': 'user', 'content': prompt}
    ],
    'max_tokens': ${COMPLETION_TOKENS},
    'temperature': 0.7,
    'stream': False
}
print(json.dumps(payload))
" <<< "${prompt_text}")

    # Record wall-clock start time
    local start_ns
    start_ns=$(python3 -c "import time; print(int(time.time() * 1e9))")

    # Make the API call
    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time "${timeout_secs}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        "${_CURL_AUTH_ARGS[@]}" \
        -d "${payload}" \
        "${LLAMA_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    local end_ns
    end_ns=$(python3 -c "import time; print(int(time.time() * 1e9))")

    local response
    response=$(cat "${tmpfile}" 2>/dev/null || echo "")
    rm -f "${tmpfile}"

    if [ "${http_code}" != "200" ]; then
        echo "{\"context_length\": ${ctx_len}, \"error\": \"HTTP ${http_code}\", \"timeout_secs\": ${timeout_secs}}"
        return
    fi

    # Parse the response and compute TPS metrics
    python3 -c "
import sys, json

response_json = sys.stdin.read()
start_ns = int(sys.argv[1])
end_ns = int(sys.argv[2])
ctx_len = int(sys.argv[3])

try:
    data = json.loads(response_json)

    usage = data.get('usage', {})
    prompt_tokens = usage.get('prompt_tokens', 0)
    completion_tokens = usage.get('completion_tokens', 0)
    total_tokens = prompt_tokens + completion_tokens

    # Wall-clock elapsed time in seconds
    elapsed_s = (end_ns - start_ns) / 1e9

    # Total TPS (prompt + completion over total time)
    total_tps = total_tokens / elapsed_s if elapsed_s > 0 else 0

    # Estimate prefill and decode speeds
    # For non-streaming, we approximate:
    #   - Prefill time is proportional to prompt_tokens
    #   - Decode time is proportional to completion_tokens
    # Without streaming TTFT, we estimate based on the ratio
    if total_tokens > 0 and elapsed_s > 0:
        # Rough estimate: prefill is much faster than decode
        # Use the total time and token counts
        decode_tps = completion_tokens / elapsed_s if completion_tokens > 0 else 0
        prefill_tps = prompt_tokens / elapsed_s if prompt_tokens > 0 else 0
    else:
        decode_tps = 0
        prefill_tps = 0

    # Check for llama.cpp-specific timing info in the response
    # llama.cpp may include timings in the response
    timings = data.get('timings', {})
    if timings:
        if 'prompt_per_second' in timings:
            prefill_tps = timings['prompt_per_second']
        if 'predicted_per_second' in timings:
            decode_tps = timings['predicted_per_second']

    result = {
        'context_length': ctx_len,
        'prompt_tokens': prompt_tokens,
        'completion_tokens': completion_tokens,
        'total_tokens': total_tokens,
        'elapsed_s': round(elapsed_s, 3),
        'total_tps': round(total_tps, 2),
        'prefill_tps': round(prefill_tps, 2),
        'decode_tps': round(decode_tps, 2),
        'finish_reason': data.get('choices', [{}])[0].get('finish_reason', 'unknown'),
    }

    # Add llama.cpp native timings if available
    if timings:
        result['timings'] = {
            'prompt_ms': timings.get('prompt_ms', 0),
            'predicted_ms': timings.get('predicted_ms', 0),
            'prompt_per_second': timings.get('prompt_per_second', 0),
            'predicted_per_second': timings.get('predicted_per_second', 0),
        }

    print(json.dumps(result))

except Exception as e:
    print(json.dumps({
        'context_length': ctx_len,
        'error': f'parse error: {str(e)}'
    }))
" <<< "${response}" "${start_ns}" "${end_ns}" "${ctx_len}"
}

# ---------------------------------------------------------------------------
# Helper: run streaming benchmark to measure TTFT accurately
# ---------------------------------------------------------------------------
run_streaming_benchmark() {
    local ctx_len="$1"
    local prompt_tokens=$((ctx_len - COMPLETION_TOKENS - 50))

    if [ "${prompt_tokens}" -lt 100 ]; then
        echo "{\"context_length\": ${ctx_len}, \"error\": \"context too small\"}"
        return
    fi

    local timeout_secs=$(( BENCH_TIMEOUT_BASE * ctx_len / 4096 ))
    if [ "${timeout_secs}" -lt "${BENCH_TIMEOUT_BASE}" ]; then
        timeout_secs="${BENCH_TIMEOUT_BASE}"
    fi

    echo -e "  ${DIM}Streaming TTFT measurement for ${ctx_len} ctx...${NC}" >&2

    local prompt_text
    prompt_text=$(generate_prompt "${prompt_tokens}")

    local payload
    payload=$(python3 -c "
import json, sys
prompt = sys.stdin.read()
payload = {
    'model': '${MODEL_NAME}',
    'messages': [
        {'role': 'system', 'content': 'You are a helpful assistant.'},
        {'role': 'user', 'content': prompt}
    ],
    'max_tokens': 16,
    'temperature': 0.7,
    'stream': True
}
print(json.dumps(payload))
" <<< "${prompt_text}")

    # Use python to measure TTFT via streaming
    python3 -c "
import sys, json, time, urllib.request, urllib.error

payload = sys.stdin.read()
url = '${LLAMA_BASE_URL}/v1/chat/completions'
ctx_len = ${ctx_len}
timeout = ${timeout_secs}

headers = {
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
}
api_key = '${API_KEY}'
if api_key and api_key not in ('', 'EMPTY', 'none', 'no-auth'):
    headers['Authorization'] = f'Bearer {api_key}'

try:
    req = urllib.request.Request(url, data=payload.encode(), headers=headers)
    start = time.time()
    resp = urllib.request.urlopen(req, timeout=timeout)

    ttft = None
    for line in resp:
        line = line.decode('utf-8', errors='replace').strip()
        if line.startswith('data: ') and line != 'data: [DONE]':
            if ttft is None:
                ttft = time.time() - start
            break

    if ttft is None:
        ttft = time.time() - start

    print(json.dumps({
        'context_length': ctx_len,
        'ttft_s': round(ttft, 4),
    }))
except Exception as e:
    print(json.dumps({
        'context_length': ctx_len,
        'ttft_error': str(e),
    }))
" <<< "${payload}"
}

# ===========================================================================
# Main
# ===========================================================================

echo ""
echo "======================================================="
echo "  llama.cpp TPS Benchmark"
echo "======================================================="
echo "  Server URL       : ${LLAMA_BASE_URL}"
echo "  Context lengths  : ${CONTEXT_LENGTHS}"
echo "  Completion tokens: ${COMPLETION_TOKENS}"
echo "  Warmup requests  : ${WARMUP_REQUESTS}"
echo "  Output format    : ${OUTPUT_FORMAT}"
echo "  Validate TPS     : ${VALIDATE_THRESHOLDS}"
if [ "${VALIDATE_THRESHOLDS}" = "true" ]; then
echo "  Thresholds       : 4k>=${TPS_THRESHOLD_4096}, 16k>=${TPS_THRESHOLD_16384}, 32k>=${TPS_THRESHOLD_32768}, 64k>=${TPS_THRESHOLD_65536} TPS"
fi
echo "======================================================="
echo ""

# --- Pre-flight checks ---
header "Pre-flight checks"
check_server
detect_model
echo ""

# --- Warmup ---
if [ "${WARMUP_REQUESTS}" -gt 0 ]; then
    header "Warmup (${WARMUP_REQUESTS} request(s) at 128 tokens)"
    for i in $(seq 1 "${WARMUP_REQUESTS}"); do
        info "Warmup request ${i}/${WARMUP_REQUESTS}..."
        local_payload=$(python3 -c "
import json
print(json.dumps({
    'model': '${MODEL_NAME}',
    'messages': [
        {'role': 'user', 'content': 'Say hello in one word.'}
    ],
    'max_tokens': 16,
    'temperature': 0
}))
")
        curl -sf -o /dev/null --max-time 60 \
            -H "Content-Type: application/json" \
            "${_CURL_AUTH_ARGS[@]}" \
            -d "${local_payload}" \
            "${LLAMA_BASE_URL}/v1/chat/completions" 2>/dev/null || true
        pass "Warmup ${i} done"
    done
    echo ""
fi

# --- Run benchmarks ---
RESULTS=()
TTFT_RESULTS=()

for ctx in ${CONTEXT_LENGTHS}; do
    header "Benchmark: context_length=${ctx}"
    info "Target: ~$((ctx - COMPLETION_TOKENS - 50)) prompt tokens + ${COMPLETION_TOKENS} completion tokens"

    result=$(run_benchmark "${ctx}")
    RESULTS+=("${result}")

    # Parse and display inline result
    python3 -c "
import json, sys
r = json.loads(sys.argv[1])
if 'error' in r:
    print(f'  \033[0;31m✗\033[0m Context {r[\"context_length\"]}: ERROR — {r[\"error\"]}')
else:
    print(f'  \033[0;32m✓\033[0m Context {r[\"context_length\"]}:')
    print(f'      Prompt tokens   : {r[\"prompt_tokens\"]}')
    print(f'      Completion tokens: {r[\"completion_tokens\"]}')
    print(f'      Elapsed          : {r[\"elapsed_s\"]}s')
    print(f'      Total TPS        : {r[\"total_tps\"]}')
    print(f'      Prefill TPS      : {r[\"prefill_tps\"]}')
    print(f'      Decode TPS       : {r[\"decode_tps\"]}')
    if 'timings' in r:
        t = r['timings']
        print(f'      [llama.cpp native timings]')
        print(f'        Prompt  : {t[\"prompt_per_second\"]:.1f} tok/s ({t[\"prompt_ms\"]:.0f}ms)')
        print(f'        Predict : {t[\"predicted_per_second\"]:.1f} tok/s ({t[\"predicted_ms\"]:.0f}ms)')
    print(f'      Finish reason    : {r[\"finish_reason\"]}')
" "${result}" 2>/dev/null || echo "  (result parse error)"

    # Measure TTFT via streaming
    ttft_result=$(run_streaming_benchmark "${ctx}")
    TTFT_RESULTS+=("${ttft_result}")

    python3 -c "
import json, sys
r = json.loads(sys.argv[1])
if 'ttft_s' in r:
    print(f'      TTFT             : {r[\"ttft_s\"]}s')
elif 'ttft_error' in r:
    print(f'      TTFT             : error — {r[\"ttft_error\"]}')
" "${ttft_result}" 2>/dev/null || true

    echo ""
done

# --- Summary ---
echo "======================================================="
echo -e "  ${BOLD}Benchmark Summary${NC}"
echo "======================================================="

if [ "${OUTPUT_FORMAT}" = "json" ]; then
    # JSON output (includes threshold validation results)
    python3 -c "
import json, os, sys

results_raw = sys.argv[1:]
half = len(results_raw) // 2
bench_results = results_raw[:half]
ttft_results = results_raw[half:]

# Threshold map
thresholds = {
    4096:  int(os.environ.get('TPS_THRESHOLD_4096',  '30')),
    16384: int(os.environ.get('TPS_THRESHOLD_16384', '20')),
    32768: int(os.environ.get('TPS_THRESHOLD_32768', '15')),
    65536: int(os.environ.get('TPS_THRESHOLD_65536', '10')),
}

def get_threshold(ctx):
    if ctx in thresholds:
        return thresholds[ctx]
    keys = sorted(thresholds.keys())
    if ctx <= keys[0]:
        return thresholds[keys[0]]
    if ctx >= keys[-1]:
        return thresholds[keys[-1]]
    for i in range(len(keys) - 1):
        lo, hi = keys[i], keys[i + 1]
        if lo <= ctx <= hi:
            ratio = (ctx - lo) / (hi - lo)
            return int(thresholds[lo] + ratio * (thresholds[hi] - thresholds[lo]))
    return 0

combined = []
for i, br in enumerate(bench_results):
    entry = json.loads(br)
    if i < len(ttft_results):
        ttft = json.loads(ttft_results[i])
        if 'ttft_s' in ttft:
            entry['ttft_s'] = ttft['ttft_s']

    # Add threshold validation
    ctx = entry.get('context_length', 0)
    threshold = get_threshold(ctx)
    entry['threshold_tps'] = threshold
    if 'error' not in entry:
        timings = entry.get('timings', {})
        actual_tps = timings.get('predicted_per_second', entry.get('decode_tps', 0))
        entry['threshold_pass'] = actual_tps >= threshold
    else:
        entry['threshold_pass'] = False

    combined.append(entry)

validate = os.environ.get('VALIDATE_THRESHOLDS', 'true').lower() == 'true'
output = {
    'benchmark': 'llama.cpp TPS',
    'server_url': '${LLAMA_BASE_URL}',
    'model': '${MODEL_NAME}',
    'completion_tokens_requested': ${COMPLETION_TOKENS},
    'thresholds': thresholds,
    'threshold_validation_enabled': validate,
    'results': combined,
}
if validate:
    pass_count = sum(1 for e in combined if e.get('threshold_pass', False))
    output['threshold_summary'] = {
        'total': len(combined),
        'passed': pass_count,
        'failed': len(combined) - pass_count,
        'all_passed': pass_count == len(combined),
    }
print(json.dumps(output, indent=2))
" "${RESULTS[@]}" "${TTFT_RESULTS[@]}"
else
    # Table output
    echo ""
    printf "  ${BOLD}%-10s  %8s  %8s  %10s  %10s  %10s  %8s${NC}\n" \
        "Context" "Prompt" "Compl" "Total TPS" "Prefill" "Decode" "TTFT"
    printf "  %-10s  %8s  %8s  %10s  %10s  %10s  %8s\n" \
        "----------" "--------" "--------" "----------" "----------" "----------" "--------"

    for i in "${!RESULTS[@]}"; do
        result="${RESULTS[$i]}"
        ttft_r="${TTFT_RESULTS[$i]:-{\}}"
        python3 -c "
import json, sys
r = json.loads(sys.argv[1])
ttft = json.loads(sys.argv[2])
ttft_val = f'{ttft[\"ttft_s\"]:.3f}s' if 'ttft_s' in ttft else 'n/a'

if 'error' in r:
    print(f'  {r[\"context_length\"]:<10}  {\"ERR\":>8}  {\"ERR\":>8}  {\"— \" + r[\"error\"]:>10}')
else:
    # Use native llama.cpp timings if available
    prefill = r.get('timings', {}).get('prompt_per_second', r.get('prefill_tps', 0))
    decode = r.get('timings', {}).get('predicted_per_second', r.get('decode_tps', 0))
    print(f'  {r[\"context_length\"]:<10}  {r[\"prompt_tokens\"]:>8}  {r[\"completion_tokens\"]:>8}  {r[\"total_tps\"]:>10.2f}  {prefill:>10.2f}  {decode:>10.2f}  {ttft_val:>8}')
" "${result}" "${ttft_r}" 2>/dev/null || echo "  (parse error for entry ${i})"
    done

    echo ""
    echo "  Notes:"
    echo "    - Total TPS = (prompt + completion tokens) / wall-clock time"
    echo "    - Prefill/Decode: native llama.cpp timings when available,"
    echo "      otherwise estimated from wall-clock time"
    echo "    - TTFT = time-to-first-token measured via streaming request"
    echo ""
fi

# --- Threshold Validation ---
THRESHOLD_FAIL_COUNT=0

if [ "${VALIDATE_THRESHOLDS}" = "true" ]; then
    echo "======================================================="
    echo -e "  ${BOLD}Threshold Validation${NC}"
    echo "  Thresholds: 4k>=${TPS_THRESHOLD_4096} TPS, 16k>=${TPS_THRESHOLD_16384} TPS, 32k>=${TPS_THRESHOLD_32768} TPS, 64k>=${TPS_THRESHOLD_65536} TPS"
    echo "======================================================="

    # Run validation and capture output
    VALIDATION_OUTPUT=$(validate_thresholds "${RESULTS[@]}")

    # Print everything except the THRESHOLD_FAILURES line
    echo "${VALIDATION_OUTPUT}" | grep -v "^THRESHOLD_FAILURES="

    # Extract failure count
    THRESHOLD_FAIL_COUNT=$(echo "${VALIDATION_OUTPUT}" | grep "^THRESHOLD_FAILURES=" | cut -d= -f2)
    THRESHOLD_FAIL_COUNT="${THRESHOLD_FAIL_COUNT:-0}"
fi

# --- Check if any benchmark had errors ---
BENCH_ERRORS=0
for result in "${RESULTS[@]}"; do
    if echo "${result}" | python3 -c "
import sys, json
r = json.loads(sys.stdin.read())
sys.exit(0 if 'error' not in r else 1)
" 2>/dev/null; then
        :
    else
        BENCH_ERRORS=$((BENCH_ERRORS + 1))
    fi
done

# --- Final verdict ---
echo "======================================================="
TOTAL_FAILURES=$((BENCH_ERRORS + THRESHOLD_FAIL_COUNT))

if [ "${BENCH_ERRORS}" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}${BENCH_ERRORS} benchmark(s) had errors${NC}"
fi

if [ "${VALIDATE_THRESHOLDS}" = "true" ] && [ "${THRESHOLD_FAIL_COUNT}" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}${THRESHOLD_FAIL_COUNT} context level(s) below TPS threshold${NC}"
fi

if [ "${TOTAL_FAILURES}" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}OVERALL: FAIL${NC}"
    echo "======================================================="
    exit 1
else
    echo -e "  ${GREEN}${BOLD}OVERALL: PASS — All benchmarks completed and meet TPS thresholds${NC}"
    echo "======================================================="
    exit 0
fi
