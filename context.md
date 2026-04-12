# DemoClaw — Project Context

## Dual-Engine Architecture (2026-04-11)

DemoClaw supports two LLM backends selected by the `LLM_ENGINE` env var, chosen by `scripts/apply-profile.sh` based on `HARDWARE_PROFILE`:

| `LLM_ENGINE` | Engine | Format | Primary hardware | Trigger profile |
|---|---|---|---|---|
| `llamacpp` (default) | llama.cpp | GGUF | Consumer GPU (8GB+ VRAM) | `consumer_gpu` / `8gb` |
| `vllm` | vLLM | safetensors / FP8 | DGX Spark GB10 (128GB unified) | `dgx_spark` |

Branching logic lives in `scripts/start.sh`, `scripts/start.bat`, `scripts/stop.sh`, `scripts/stop.bat`, and `scripts/apply-profile.{sh,bat}`. The `consumer_gpu` code path is intentionally unchanged — only `dgx_spark` gets the vLLM branch.

### vLLM path key variables

- `VLLM_IMAGE` — `vllm/vllm-openai:gemma4-cu130` (community pre-release image, CUDA 13.0 + Gemma 4 parsers)
- `VLLM_MODEL_ID` — `google/gemma-4-26B-A4B-it` (public Apache 2.0, no HF token needed)
- `VLLM_GPU_MEM_UTIL=0.70` — allocates ~90GB of 128GB unified memory, leaving headroom
- `VLLM_QUANTIZATION=fp8` + `--kv-cache-dtype fp8` — online FP8 quantization
- `VLLM_EXTRA_ARGS` — `--enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4 --enable-prefix-caching --enable-chunked-prefill --max-num-seqs 4 --max-num-batched-tokens 8192`
- `VLLM_MAX_MODEL_LEN=262144` — 256k context
- `VLLM_HEALTH_TIMEOUT=3600` — 1 hour (first-run model download is ~49GB)

### vLLM container must-have flags

All three are required for the vLLM container to function in DemoClaw's Docker network:
- `--host 0.0.0.0` — bind to all interfaces (default is 127.0.0.1, container-local only)
- `--ipc host` — required for vLLM's POSIX shared-memory CUDA IPC
- `-v ${MODEL_DIR}:/data/models` + `-e HF_HOME=/data/models` — persist HF cache across restarts

### Legacy llama.cpp variables

In `config/profiles/dgx-spark.env`, the old llama.cpp-specific vars (`MODEL_REPO`, `MODEL_FILE`, `CTX_SIZE`, `N_GPU_LAYERS`, `FLASH_ATTN`, `CACHE_TYPE_K/V`) are preserved as `# [legacy: llama.cpp]` comments for rollback. **Do not remove them** — they enable quick rollback if vLLM fails on new DGX Spark firmware.

### OpenClaw connection layer

Regardless of engine, OpenClaw always connects via `LLAMACPP_BASE_URL`, `LLAMACPP_MODEL_NAME`, etc. `start.sh` dynamically sets the base URL based on the active container's network alias (`llamacpp` or `vllm`) so OpenClaw's `entrypoint.sh` requires no changes. `CTX_SIZE` passed to OpenClaw is sourced from `VLLM_MAX_MODEL_LEN` in vLLM mode, `CTX_SIZE` in llama.cpp mode.

## Why vLLM on DGX Spark — Root Causes Documented

llama.cpp cannot reliably serve Gemma 4 26B A4B MoE on DGX Spark GB10. Root causes discovered during the trace pipeline (see `.omc/specs/deep-dive-trace-*.md`):

1. **mmproj CUDA SIGABRT** — llama.cpp issue #21402, Gemma 4 vision projector crashes on Blackwell CUDA
2. **KV cache OOM** — Q8_0 weights (~28GB) + q8_0 KV cache @ 262k context (~92GB) + mmproj + compute ≈ 125GB (128GB unified memory limit)
3. **sm_120 vs sm_121 mismatch** — `llamacpp/Dockerfile:60` hardcodes `CUDA_ARCHS="120"` for arm64, but GB10's real compute capability is 12.1. sm_120 binaries run via JIT PTX fallback, not native kernels.
4. **ggml Blackwell MoE kernel immaturity** — vLLM's `gemma4-cu130` image includes NVIDIA-tuned Blackwell grouped-GEMM for MoE dispatch; ggml-cuda does not yet.

## Known Decisions

- `vllm/vllm-openai:gemma4-cu130` is a community/pre-release image tag. Monitor for an official Gemma 4 release tag.
- Vision on vLLM is native (no `mmproj` file needed), unlike llama.cpp.
- `docs/openclaw-env-config.md` still documents only llama.cpp variables — intentional, since OpenClaw config is engine-agnostic.
- The `dgx-spark-ai-cluster/` directory at repo root is an **independent sibling repo** that is not a dependency. DemoClaw reimplements its vLLM configuration rather than taking a runtime dependency.

## Pitfalls & Gotchas (learned the hard way)

- `.sh` ↔ `.bat` parity is fragile. vLLM required `--host 0.0.0.0`, `--ipc host`, and `HF_HOME` volume mount — all three were missed in the initial `start.bat` pass and caught by code review before push.
- `CTX_SIZE` fallback via `${CTX_SIZE:-...}` is a footgun: `apply-profile.sh` always sets `CTX_SIZE`, so the fallback never fires. Use explicit engine branching: `if [ "${LLM_ENGINE}" = "vllm" ]; then OC_CTX_SIZE="${VLLM_MAX_MODEL_LEN}"; fi`
- `VLLM_EXTRA_ARGS` must be expanded inside a `set -f` / `set +f` guard to prevent shell glob expansion on the unquoted variable.
- Windows `if not defined CTX_SIZE` treats empty strings as defined. Don't rely on it for `.env`-loaded variables.
