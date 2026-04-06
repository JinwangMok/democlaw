#!/usr/bin/env python3
"""
DemoClaw — LLM Throughput Benchmark (Python Driver)

Measures inference throughput (tokens/second) by sending specific test prompts
to the llama.cpp OpenAI-compatible API and computing t/s from the response's
usage.completion_tokens divided by wall-clock elapsed time.

This is NOT server-log parsing — every measurement comes from an actual API
round-trip with a real prompt and a real generated response.

Designed for two deployment scenarios:
  - Gemma 4 E4B on consumer GPUs (8 GB VRAM)   — default threshold: 15 t/s
  - Gemma 4 26B A4B MoE on DGX Spark (128 GB)  — default threshold: 20 t/s

Usage:
  # Default (auto-detect model, auto threshold)
  python3 scripts/benchmark_tps.py

  # Override threshold and endpoint
  BENCH_MIN_TPS=20 LLAMACPP_PORT=9000 python3 scripts/benchmark_tps.py

  # JSON output for CI
  BENCH_OUTPUT_FORMAT=json python3 scripts/benchmark_tps.py

  # Target specific hardware profile
  HARDWARE_PROFILE=dgx_spark python3 scripts/benchmark_tps.py

Environment variables:
  LLAMACPP_HOST        — API host (default: localhost)
  LLAMACPP_PORT        — API port (default: 8000)
  BENCH_MIN_TPS        — Minimum t/s to pass (default: auto from HARDWARE_PROFILE)
  BENCH_MAX_TOKENS     — Max tokens per generation (default: 128)
  BENCH_WARMUP_TOKENS  — Warmup generation tokens (default: 32)
  BENCH_RUNS           — Runs per prompt (default: 3)
  BENCH_TIMEOUT        — Timeout per request in seconds (default: 120)
  BENCH_OUTPUT_FORMAT  — "text" or "json" (default: text)
  HARDWARE_PROFILE     — "dgx_spark" or "consumer_gpu" (from detect-hardware.sh)
  MODEL_NAME           — Model name override (auto-detected if empty)
  BENCH_MODEL_NAME     — Alias for MODEL_NAME

Exit codes:
  0 — All benchmark runs met the threshold
  1 — One or more runs failed or an error occurred
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from typing import Optional

# =============================================================================
# Configuration
# =============================================================================

HOST = os.environ.get("LLAMACPP_HOST", "localhost")
PORT = os.environ.get("LLAMACPP_PORT", "8000")
BASE_URL = f"http://{HOST}:{PORT}"

MAX_TOKENS = int(os.environ.get("BENCH_MAX_TOKENS", "128"))
WARMUP_TOKENS = int(os.environ.get("BENCH_WARMUP_TOKENS", "32"))
RUNS = int(os.environ.get("BENCH_RUNS", "3"))
TIMEOUT = int(os.environ.get("BENCH_TIMEOUT", "120"))
OUTPUT_FMT = os.environ.get("BENCH_OUTPUT_FORMAT", "text")
HW_PROFILE = os.environ.get("HARDWARE_PROFILE", "")
MODEL_NAME_ENV = os.environ.get(
    "BENCH_MODEL_NAME", os.environ.get("MODEL_NAME", "")
)
MIN_TPS_OVERRIDE = os.environ.get("BENCH_MIN_TPS", "")

# Default thresholds per hardware profile (validated minimums)
DEFAULT_TPS = {
    "consumer_gpu": 15,
    "dgx_spark": 20,
}

# =============================================================================
# Standardized Benchmark Prompts
# =============================================================================
# Each prompt exercises a different generation pattern to ensure the benchmark
# reflects real-world throughput across varied workloads — not a single cherry-
# picked prompt.

PROMPTS: list[tuple[str, str]] = [
    (
        "technical",
        "Explain how a GPU processes parallel workloads in modern deep learning "
        "training pipelines. Cover thread blocks, warps, and memory coalescing.",
    ),
    (
        "creative",
        "Write a short story about a robot discovering it can dream. "
        "Include dialogue and sensory descriptions.",
    ),
    (
        "reasoning",
        "A farmer has 120 meters of fencing. What dimensions should a "
        "rectangular pen have to maximize enclosed area? Show your reasoning "
        "step by step.",
    ),
]


# =============================================================================
# Data structures
# =============================================================================

@dataclass
class BenchmarkResult:
    """Result from a single benchmark run."""

    label: str
    run: int
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0
    elapsed_s: float = 0.0
    tokens_per_second: float = 0.0
    error: Optional[str] = None


@dataclass
class BenchmarkSummary:
    """Aggregate summary across all runs."""

    model: str
    hardware_profile: str
    threshold_tps: float
    max_tokens: int
    total_runs: int
    passed: int
    failed: int
    errors: int
    average_tps: float
    min_tps: float
    max_tps: float
    overall_pass: bool
    results: list[dict] = field(default_factory=list)


# =============================================================================
# Logging
# =============================================================================

def log(msg: str) -> None:
    print(f"[benchmark] {msg}")


def warn(msg: str) -> None:
    print(f"[benchmark] WARNING: {msg}", file=sys.stderr)


def err(msg: str) -> None:
    print(f"[benchmark] ERROR: {msg}", file=sys.stderr)


# =============================================================================
# Threshold resolution
# =============================================================================

def resolve_threshold() -> float:
    """Return the t/s threshold. Explicit override > hardware profile > default."""
    if MIN_TPS_OVERRIDE:
        return float(MIN_TPS_OVERRIDE)
    return float(DEFAULT_TPS.get(HW_PROFILE, DEFAULT_TPS["dgx_spark"]))


# =============================================================================
# Model auto-detection
# =============================================================================

def detect_model() -> str:
    """Auto-detect model name from /v1/models endpoint."""
    if MODEL_NAME_ENV:
        return MODEL_NAME_ENV
    try:
        req = urllib.request.Request(
            f"{BASE_URL}/v1/models",
            headers={"Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            models = data.get("data", [])
            return models[0]["id"] if models else ""
    except Exception:
        return ""


# =============================================================================
# Pre-flight health check
# =============================================================================

def preflight() -> bool:
    """Verify llama.cpp is healthy and responding."""
    try:
        with urllib.request.urlopen(f"{BASE_URL}/health", timeout=10) as resp:
            return resp.status == 200
    except Exception:
        return False


# =============================================================================
# Core benchmark: single run
# =============================================================================

def run_single_benchmark(
    model: str,
    prompt: str,
    label: str,
    run_num: int,
) -> BenchmarkResult:
    """
    Send a chat completion request and measure throughput.

    t/s = usage.completion_tokens / wall_clock_elapsed_seconds

    This deliberately uses non-streaming mode so that we get a single
    response with a reliable usage.completion_tokens count from the server.
    Wall-clock time captures the full round trip including TTFT + generation.
    """
    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": MAX_TOKENS,
            "temperature": 0.1,
            "stream": False,
        }
    )

    # Use curl via subprocess for robust timeout + redirect handling
    tmp_fh = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
    tmp = tmp_fh.name
    tmp_fh.close()

    start = time.perf_counter()
    try:
        proc = subprocess.run(
            [
                "curl",
                "-s",
                "-o", tmp,
                "-w", "%{http_code}",
                "--max-time", str(TIMEOUT),
                "-H", "Content-Type: application/json",
                "-d", payload,
                f"{BASE_URL}/v1/chat/completions",
            ],
            capture_output=True,
            text=True,
            timeout=TIMEOUT + 10,
        )
        elapsed = time.perf_counter() - start
        http_code = proc.stdout.strip()
    except Exception as exc:
        return BenchmarkResult(label=label, run=run_num, error=f"request_failed: {exc}")

    if http_code != "200":
        _cleanup(tmp)
        return BenchmarkResult(
            label=label,
            run=run_num,
            error=f"http_{http_code}",
        )

    # Parse the JSON response
    try:
        with open(tmp, "r", encoding="utf-8", errors="replace") as fh:
            resp = json.load(fh)
    except Exception:
        _cleanup(tmp)
        return BenchmarkResult(label=label, run=run_num, error="parse_failed")
    finally:
        _cleanup(tmp)

    usage = resp.get("usage", {})
    completion_tokens = usage.get("completion_tokens", 0)
    prompt_tokens = usage.get("prompt_tokens", 0)
    total_tokens = usage.get("total_tokens", 0)

    if completion_tokens == 0 or elapsed <= 0:
        return BenchmarkResult(label=label, run=run_num, error="zero_tokens")

    tps = completion_tokens / elapsed

    return BenchmarkResult(
        label=label,
        run=run_num,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=total_tokens,
        elapsed_s=round(elapsed, 3),
        tokens_per_second=round(tps, 2),
    )


def _cleanup(path: str) -> None:
    """Remove temp file if it exists."""
    try:
        os.unlink(path)
    except OSError:
        pass


# =============================================================================
# Warmup
# =============================================================================

def warmup(model: str) -> None:
    """Send a short generation to prime the model / KV cache."""
    log("Warming up model ...")
    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": "Hello, how are you?"}],
            "max_tokens": WARMUP_TOKENS,
            "temperature": 0.1,
        }
    )
    try:
        subprocess.run(
            [
                "curl",
                "-s",
                "-o", os.devnull if os.name != "nt" else "NUL",
                "--max-time", str(TIMEOUT),
                "-H", "Content-Type: application/json",
                "-d", payload,
                f"{BASE_URL}/v1/chat/completions",
            ],
            capture_output=True,
            timeout=TIMEOUT + 10,
        )
    except Exception:
        pass
    log("Warmup complete.")


# =============================================================================
# Output formatting
# =============================================================================

def format_result_line(r: BenchmarkResult, threshold: float) -> str:
    """Format a single result as a human-readable line."""
    if r.error:
        return f"  [x] [{r.label}] run {r.run}: ERROR -- {r.error}"
    status = "PASS" if r.tokens_per_second >= threshold else "FAIL"
    sym = "+" if status == "PASS" else "x"
    return (
        f"  [{sym}] [{r.label}] run {r.run}: "
        f"{r.tokens_per_second:.1f} t/s "
        f"({r.completion_tokens} tokens in {r.elapsed_s:.1f}s) "
        f"[threshold: {threshold} t/s] -- {status}"
    )


# =============================================================================
# Main
# =============================================================================

def main() -> int:
    log("========================================================")
    log("  DemoClaw -- LLM Throughput Benchmark")
    log("========================================================")

    # Pre-flight
    if not preflight():
        err(f"llama.cpp /health not reachable at {BASE_URL}")
        err("Is the llama.cpp server running? Start with: make start")
        return 1
    log("Pre-flight: /health OK (HTTP 200)")

    # Model detection
    model = detect_model()
    if not model:
        warn("Could not detect model name. Requests will use server default.")

    # Threshold
    threshold = resolve_threshold()
    hw = HW_PROFILE or "auto"

    log("Configuration:")
    log(f"  Endpoint     : {BASE_URL}/v1/chat/completions")
    log(f"  Model        : {model or '<server default>'}")
    log(f"  Hardware     : {hw}")
    log(f"  Threshold    : {threshold} t/s (minimum to pass)")
    log(f"  Max tokens   : {MAX_TOKENS}")
    log(f"  Runs/prompt  : {RUNS}")
    log(f"  Prompts      : {len(PROMPTS)}")
    log(f"  Timeout      : {TIMEOUT}s per request")

    # Warmup
    warmup(model)
    log("")
    log("--- Benchmark Results ---")

    # Execute benchmark runs
    results: list[BenchmarkResult] = []
    passed = failed = errors = 0
    tps_values: list[float] = []

    for label, prompt in PROMPTS:
        for run_num in range(1, RUNS + 1):
            r = run_single_benchmark(model, prompt, label, run_num)
            results.append(r)

            if r.error:
                errors += 1
            elif r.tokens_per_second >= threshold:
                passed += 1
                tps_values.append(r.tokens_per_second)
            else:
                failed += 1
                tps_values.append(r.tokens_per_second)

            if OUTPUT_FMT == "text":
                log(format_result_line(r, threshold))

    # Compute summary statistics
    total = passed + failed + errors
    avg_tps = round(sum(tps_values) / len(tps_values), 2) if tps_values else 0.0
    min_tps = round(min(tps_values), 2) if tps_values else 0.0
    max_tps_val = round(max(tps_values), 2) if tps_values else 0.0
    overall = failed == 0 and errors == 0

    summary = BenchmarkSummary(
        model=model,
        hardware_profile=hw,
        threshold_tps=threshold,
        max_tokens=MAX_TOKENS,
        total_runs=total,
        passed=passed,
        failed=failed,
        errors=errors,
        average_tps=avg_tps,
        min_tps=min_tps,
        max_tps=max_tps_val,
        overall_pass=overall,
        results=[asdict(r) for r in results],
    )

    # Output
    if OUTPUT_FMT == "json":
        print(json.dumps(asdict(summary), indent=2))
    else:
        log("")
        log("========================================================")
        log("  Benchmark Summary")
        log("========================================================")
        log(f"  Model        : {model or '<server default>'}")
        log(f"  Hardware     : {hw}")
        log(f"  Threshold    : {threshold} t/s")
        log(f"  Average      : {avg_tps} t/s")
        log(f"  Min          : {min_tps} t/s")
        log(f"  Max          : {max_tps_val} t/s")
        log(f"  Runs         : {total} total")
        log(f"    Passed     : {passed}")
        log(f"    Failed     : {failed}")
        log(f"    Errors     : {errors}")
        log("")
        if overall:
            log("  Result: PASS")
        else:
            log("  Result: FAIL")
            err(f"Benchmark did not meet the {threshold} t/s threshold.")
            if errors > 0:
                err(f"{errors} run(s) returned errors.")
        log("========================================================")

    return 0 if overall else 1


if __name__ == "__main__":
    sys.exit(main())
