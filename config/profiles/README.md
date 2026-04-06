# DemoClaw — Deployment Profiles

Pre-configured `.env` files for different hardware targets. Copy one to the project root as `.env` to activate it.

## Available Profiles

| Profile | Model | Hardware Target | VRAM / Memory |
|---------|-------|-----------------|---------------|
| `gemma4-e4b-8gb.env` | Gemma 4 E4B Q4_K_M | Consumer GPU (RTX 3070/4070) | 8 GB VRAM |
| `dgx-spark.env` | Gemma 4 26B A4B MoE Q4_K_M | NVIDIA DGX Spark | 128 GB unified |

## Usage

```bash
# Option 1: Copy profile to project root
cp config/profiles/dgx-spark.env .env

# Option 2: Merge with existing .env (append model settings)
cat config/profiles/dgx-spark.env >> .env

# Then start as usual
make start
# or
./scripts/start.sh
```

## Profile Details

### Gemma 4 E4B — 8GB VRAM (`gemma4-e4b-8gb.env`)

- **Model**: `unsloth/gemma-4-E4B-it-GGUF` (Q4_K_M, ~4.7 GB)
- **Context**: 8,192 tokens (increase to 32k if VRAM permits)
- **Memory**: ~4-6 GB total GPU usage
- **Use case**: Local development, consumer hardware

### Gemma 4 26B A4B MoE — DGX Spark (`dgx-spark.env`)

- **Model**: `unsloth/gemma-4-26B-A4B-it-GGUF` (Q4_K_M, ~15-16 GB)
- **Context**: 131,072 tokens (128k)
- **Memory**: ~40-51 GB total (well within 128 GB unified memory)
- **Use case**: Production inference on DGX Spark, high-throughput multi-turn

## Customization

All profiles use the same environment variables as `.env.example`. You can override any value after copying. Key tuning parameters:

| Variable | Description | DGX Spark | 8GB VRAM |
|----------|-------------|-----------|----------|
| `CTX_SIZE` | Max context tokens | 131072 | 8192 |
| `N_GPU_LAYERS` | Layers on GPU | 99 (all) | 99 (all) |
| `FLASH_ATTN` | Flash attention | 1 (on) | 1 (on) |
| `CACHE_TYPE_K` | KV cache key type | q8_0 | q4_0 |
| `CACHE_TYPE_V` | KV cache value type | q8_0 | q4_0 |
