# DGX Spark Benchmark Validation — Gemma 4 26B A4B MoE

## Overview

This document describes the end-to-end validation procedure for Gemma 4 26B A4B
MoE (Q4_K_M) on NVIDIA DGX Spark (128GB unified memory). The acceptance
criterion is **>= 20 tokens/second** sustained generation throughput measured by
the DemoClaw benchmark script.

## Hardware Target

| Attribute            | Value                                         |
|----------------------|-----------------------------------------------|
| System               | NVIDIA DGX Spark                              |
| GPU                  | Grace Blackwell (GH200 / GB-series)           |
| Memory               | 128 GB unified CPU+GPU (NVLink-C2C)           |
| CUDA toolkit         | 12.6.3 (container base)                       |
| Driver               | >= 550.0                                      |

## Model Configuration

| Parameter      | Value                                          |
|----------------|------------------------------------------------|
| MODEL_REPO     | `unsloth/gemma-4-26B-A4B-it-GGUF`             |
| MODEL_FILE     | `gemma-4-26B-A4B-it-Q4_K_M.gguf`              |
| MODEL_NAME     | `gemma-4-26B-A4B-it`                           |
| Quantization   | Q4_K_M (~15-16 GB on disk)                    |
| Architecture   | Mixture of Experts (4 active / N total)        |
| CTX_SIZE       | 262144 (256k tokens)                           |
| N_GPU_LAYERS   | 99 (full offload)                              |
| FLASH_ATTN     | 1 (enabled)                                    |
| CACHE_TYPE_K   | q8_0                                           |
| CACHE_TYPE_V   | q8_0                                           |
| Format         | GGUF via llama.cpp                             |

## Memory Budget (128 GB unified)

| Component                  | Estimated Size  |
|----------------------------|-----------------|
| Model weights (Q4_K_M)    | ~15-16 GB       |
| KV cache (q8_0, 128k ctx) | ~20-25 GB       |
| Compute scratch/buffers    | ~5-10 GB        |
| **Total estimated**        | **~40-51 GB**   |
| Remaining headroom         | ~77-88 GB       |

The model fits well within the 128 GB unified memory pool with substantial
headroom for concurrent requests and system processes.

## Throughput Expectations

| Metric                     | Value           |
|----------------------------|-----------------|
| Minimum threshold (pass)   | **20 t/s**      |
| Expected typical range     | 25-50 t/s       |
| Benchmark max_tokens       | 128 per prompt  |
| Warmup tokens              | 32              |
| Runs per prompt            | 3               |
| Prompt types               | 3 (technical, creative, reasoning) |

### Why >= 20 t/s is achievable

- **Unified memory bandwidth**: DGX Spark's NVLink-C2C provides ~900 GB/s
  bandwidth between Grace CPU and Blackwell GPU, eliminating PCIe bottlenecks
  that limit consumer GPUs.
- **Full GPU offload**: All model layers on GPU (N_GPU_LAYERS=99) with unified
  memory means zero CPU-GPU data transfer overhead during inference.
- **MoE efficiency**: Only 4 experts are active per token, so effective compute
  per token is much lower than a dense 26B model. Active parameters per forward
  pass are estimated at ~8-10B equivalent.
- **Q4_K_M quantization**: Reduces memory bandwidth requirements by ~4x compared
  to FP16, allowing the memory subsystem to feed tokens faster.
- **llama.cpp optimizations**: Flash attention reduces KV cache memory traffic;
  q8_0 cache quantization further reduces bandwidth pressure.

## Validation Procedure

### Step 1: Apply DGX Spark Profile

```bash
cp config/profiles/dgx-spark.env .env
```

Or set the hardware profile explicitly:

```bash
export HARDWARE_PROFILE=dgx_spark
```

### Step 2: Start the Stack

```bash
make start
# Wait for model download (first run) and health check
```

Verify the container is healthy:

```bash
curl -sf http://localhost:8000/health
# Should return: {"status":"ok"}
```

### Step 3: Run the Benchmark

**Basic run (uses auto-detected threshold of 20 t/s for dgx_spark):**

```bash
HARDWARE_PROFILE=dgx_spark ./scripts/benchmark-tps.sh
```

**Explicit 20 t/s threshold override:**

```bash
BENCH_MIN_TPS=20 ./scripts/benchmark-tps.sh
```

**JSON output for CI integration:**

```bash
HARDWARE_PROFILE=dgx_spark BENCH_OUTPUT_FORMAT=json ./scripts/benchmark-tps.sh
```

**Windows:**

```cmd
set HARDWARE_PROFILE=dgx_spark
set MIN_TPS=20
scripts\benchmark-tps.bat
```

### Step 4: Interpret Results

The benchmark runs 3 prompts x 3 runs = 9 total generation requests. Each
reports tokens/second. The overall result is PASS if **all runs** meet the
threshold.

Example expected output:

```
[benchmark] ========================================================
[benchmark]   DemoClaw — LLM Throughput Benchmark
[benchmark] ========================================================
[benchmark] Pre-flight: checking llama.cpp at http://localhost:8000 ...
[benchmark] Pre-flight: /health OK (HTTP 200)
[benchmark] Configuration:
[benchmark]   Endpoint     : http://localhost:8000/v1/chat/completions
[benchmark]   Model        : gemma-4-26B-A4B-it
[benchmark]   Hardware     : dgx_spark
[benchmark]   Threshold    : 20 t/s (minimum to pass)
[benchmark]   Max tokens   : 128
[benchmark]   Runs/prompt  : 3
[benchmark]   Prompts      : 3
[benchmark]   Timeout      : 120s per request
[benchmark] Warming up model (32 tokens) ...
[benchmark] Warmup complete.
[benchmark]
[benchmark] --- Benchmark Results ---
  [+] [technical] run 1: 28.5 t/s (128 tokens in 4.5s) [threshold: 20 t/s] -- PASS
  [+] [technical] run 2: 30.2 t/s (128 tokens in 4.2s) [threshold: 20 t/s] -- PASS
  [+] [technical] run 3: 29.8 t/s (128 tokens in 4.3s) [threshold: 20 t/s] -- PASS
  [+] [creative]  run 1: 31.1 t/s (128 tokens in 4.1s) [threshold: 20 t/s] -- PASS
  [+] [creative]  run 2: 30.5 t/s (128 tokens in 4.2s) [threshold: 20 t/s] -- PASS
  [+] [creative]  run 3: 29.9 t/s (128 tokens in 4.3s) [threshold: 20 t/s] -- PASS
  [+] [reasoning] run 1: 27.3 t/s (128 tokens in 4.7s) [threshold: 20 t/s] -- PASS
  [+] [reasoning] run 2: 28.1 t/s (128 tokens in 4.6s) [threshold: 20 t/s] -- PASS
  [+] [reasoning] run 3: 27.9 t/s (128 tokens in 4.6s) [threshold: 20 t/s] -- PASS
[benchmark]
[benchmark] ========================================================
[benchmark]   Benchmark Summary
[benchmark] ========================================================
[benchmark]   Model        : gemma-4-26B-A4B-it
[benchmark]   Hardware     : dgx_spark
[benchmark]   Threshold    : 20 t/s
[benchmark]   Average      : 29.26 t/s
[benchmark]   Runs         : 9 total
[benchmark]     Passed     : 9
[benchmark]     Failed     : 0
[benchmark]     Errors     : 0
[benchmark]
[benchmark]   Result: PASS
[benchmark] ========================================================
```

### Step 5: Dashboard Compatibility Check

After the benchmark passes, verify OpenClaw dashboard renders Gemma 4 responses:

1. Open `http://localhost:18789` in a browser
2. Send a test message through the chat interface
3. Confirm the response renders correctly with proper formatting
4. Check the model name displays as `gemma-4-26B-A4B-it` in the UI

## Troubleshooting

### Throughput below 20 t/s

| Possible Cause                        | Fix                                          |
|---------------------------------------|----------------------------------------------|
| Context too large for current request | Reduce CTX_SIZE to 65536 for testing         |
| Other GPU workloads consuming memory  | Stop competing containers/processes           |
| Model not fully GPU-offloaded         | Verify N_GPU_LAYERS=99 in .env               |
| Flash attention disabled              | Verify FLASH_ATTN=1 in .env                  |
| KV cache not quantized                | Set CACHE_TYPE_K=q8_0 CACHE_TYPE_V=q8_0     |
| Cold start (first request)            | Warmup is included; re-run if first was slow |

### OOM or container crash

- Verify the DGX Spark has 128GB unified memory available
- Check `nvidia-smi` for memory usage by other processes
- Reduce CTX_SIZE to 65536 as a conservative option
- The model (~15-16 GB) + KV cache (~20-25 GB at 128k) should total ~40-51 GB

### Benchmark script errors

- Ensure `curl` and `python3` are available on PATH
- Check llama.cpp container is healthy: `curl http://localhost:8000/health`
- Increase `BENCH_TIMEOUT` if running on heavily loaded systems

## CI Integration

For automated validation in CI pipelines:

```bash
# Run with JSON output and explicit threshold
HARDWARE_PROFILE=dgx_spark \
BENCH_MIN_TPS=20 \
BENCH_OUTPUT_FORMAT=json \
./scripts/benchmark-tps.sh > benchmark-results.json

# Check exit code: 0 = PASS, 1 = FAIL
echo "Exit code: $?"
```

The JSON output contains structured results suitable for parsing:

```json
{
  "model": "gemma-4-26B-A4B-it",
  "hardware_profile": "dgx_spark",
  "threshold_tps": 20.0,
  "max_tokens": 128,
  "total_runs": 9,
  "passed": 9,
  "failed": 0,
  "errors": 0,
  "average_tps": 29.26,
  "overall_pass": true,
  "results": [...]
}
```

## Acceptance Criteria

- [ ] DGX Spark profile loads correctly via `config/profiles/dgx-spark.env`
- [ ] Hardware detection identifies DGX Spark (via GPU name, system ID, or memory threshold)
- [ ] Benchmark script auto-selects 20 t/s threshold for `dgx_spark` profile
- [ ] All 9 benchmark runs (3 prompts x 3 runs) achieve >= 20 t/s
- [ ] Average throughput exceeds 20 t/s
- [ ] Benchmark exits with code 0 (PASS)
- [ ] OpenClaw dashboard correctly renders Gemma 4 26B A4B responses
