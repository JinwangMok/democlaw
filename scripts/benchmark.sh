#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — Alias for benchmark-tps.sh
#
# The Makefile `benchmark` target calls this script.
# Delegates to benchmark-tps.sh which performs the actual throughput measurement
# using specific test prompts against the OpenAI-compatible API.
#
# Alternatively, you can run the Python driver directly:
#   python3 scripts/benchmark_tps.py
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/benchmark-tps.sh" "$@"
