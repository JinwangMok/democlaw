# DGX Spark vLLM troubleshooting scratchpad

임시 디버그 노트. 원격 노드(k8s pod, GB10, 580.82.07 driver, compute_cap 12.1,
/home/user on 3.4T NVMe)에서 vLLM 부팅이 `TRITON_ATTN backend` 직후 멈추는
문제를 추적 중. 문제 해결되면 파일 삭제.

## 확정된 사실

- **이미지**: `vllm/vllm-openai:gemma4-cu130` digest `sha256:0d15...fea833`.
  reference(`dgx-spark-ai-cluster`)의 dgx-vllm이 이전에 같은 노드에서 정상 서빙한
  적 있음(`"pong! 🏓"` 확인). 즉 이미지 자체는 이 하드웨어에서 동작 가능.
- **런타임**: podman-like, cgroup 격리 제한(`docker top`/`docker stats` 불가).
  `docker --gpus all` 경로가 막혀 CDI `--device nvidia.com/gpu=all`로 전환됨.
- **MODEL_DIR**: 현재 `/home/user/models` (3.4T 여유). apply-profile이
  auto-select 하도록 패치됨.
- **PyTorch arch_list 검증**:
  ```
  cuda_avail True
  dev_cap (12, 1)
  arch_list ['sm_80', 'sm_90', 'sm_100', 'sm_110', 'sm_120', 'compute_120']
  matmul_sum 1073741824.0
  ```
  **`sm_121`이 arch_list에 없음**. 단순 matmul은 cuBLAS + driver가 compute_120
  PTX를 sm_121로 JIT 폴백해서 성공.

## 현재 가설 (근거 있음)

vLLM이 `AttentionBackendEnum.TRITON_ATTN`을 고른 뒤 Triton이 자체 JIT 커널을
sm_121용으로 컴파일하려다 막힘. Triton은 PyTorch와 달리 자체 backend DB를
갖고 있어서 sm_121 프로파일이 없으면 autotune/compile 루프에 빠질 수 있음.

FlashAttention이 이 이미지의 Blackwell 빌드에 없거나 xformers 미포함이라
Triton으로 폴백한 것이 2차 원인.

## 이번 세션의 미해결 증상

- `Using AttentionBackendEnum.TRITON_ATTN backend` 출력 후 stdout 정지
- 네트워크 I/O 없음 (`du` 동일, `.incomplete` 없음)
- 컨테이너 살아있지만 다운로드 진입조차 못 함
- Ctrl+C 시 노드 프리즈 경험 있음 (통합 메모리 + 스크립트 detached 컨테이너
  조합). 반드시 새 쉘에서 `docker rm -f <name>`으로 중단할 것.

## 다음 단계: Triton 우회 + 최소 모델로 증명

### 테스트 A — TORCH_SDPA로 Triton 경로 우회 (최소 모델)

```bash
docker run --rm --device nvidia.com/gpu=all --ipc host --shm-size 16g \
  -p 8000:8000 \
  -e VLLM_ATTENTION_BACKEND=TORCH_SDPA \
  vllm/vllm-openai:gemma4-cu130 \
  --model facebook/opt-125m \
  --host 0.0.0.0 --port 8000 \
  --gpu-memory-utilization 0.30 \
  --enforce-eager \
  --max-model-len 2048 \
  --max-num-seqs 1
```

- 성공 기준: 로그에 `Using AttentionBackendEnum.TORCH_SDPA backend`가 찍히고
  `Uvicorn running on http://0.0.0.0:8000`까지 도달.
- 여전히 멈춤: 다른 백엔드 env 시도 (`FLASHINFER`, `XFORMERS`, `FLASH_ATTN`).

### 테스트 B — Gemma 4 26B 실전 (v0 + XFORMERS)

`--shm-size`는 podman + `--ipc host`에서 충돌하므로 제외.
TORCH_SDPA로 opt-125m은 올라갔지만 26B에선 여전히 TRITON_ATTN 멈춤이 재현됨
→ v1 엔진의 EngineCore 서브프로세스가 env를 제대로 못 받는 것이 유력.
v1을 끄고 attention 백엔드도 XFORMERS로 강제.

```bash
docker rm -f vllm 2>/dev/null
docker run -d --rm --name vllm \
  --device nvidia.com/gpu=all --ipc host \
  -p 8000:8000 \
  -v /home/user/models:/data/models \
  -e HF_HOME=/data/models \
  -e VLLM_USE_V1=0 \
  -e VLLM_ATTENTION_BACKEND=XFORMERS \
  vllm/vllm-openai:gemma4-cu130 \
  --model google/gemma-4-26B-A4B-it \
  --host 0.0.0.0 --port 8000 \
  --gpu-memory-utilization 0.60 \
  --dtype auto \
  --quantization fp8 \
  --kv-cache-dtype fp8 \
  --load-format safetensors \
  --max-model-len 32768 \
  --max-num-seqs 1 \
  --max-num-batched-tokens 4096 \
  --enforce-eager
```

1분 대기 후 **실제로 어떤 백엔드가 선택됐는지** 확인:

```bash
docker logs vllm 2>&1 | grep -iE 'backend|attention' | head -20
```

- `XFORMERS` / `xformers` → env 먹음. 로딩 계속 대기.
- 여전히 `TRITON_ATTN` → XFORMERS 미설치. env 값을 차례로
  `FLASH_ATTN`, `FLASHINFER`, `TORCH_SDPA`로 바꿔 재시도.
- `ImportError` / `not supported` → 해당 백엔드 미설치, 다음 후보로.

### 진행 상황 모니터링 (새 쉘)

```bash
docker logs -f vllm
# 다른 창에서:
watch -n 10 'du -sh /home/user/models; find /home/user/models -name "*.safetensors*" -exec ls -lh {} \;'
```

중단 필요 시 (Ctrl+C 금지):
```bash
docker rm -f vllm
```

## 테스트 결과 기록용 템플릿

다음 시도 결과를 여기 한 줄씩 적으면서 이분탐색:

- [ ] A-SDPA opt-125m:
- [ ] A-FLASHINFER opt-125m:
- [ ] A-XFORMERS opt-125m:
- [ ] A-FLASH_ATTN opt-125m:
- [ ] B-SDPA gemma-4-26B:
- [ ] C-gemma-2-2b (원 테스트 3, gated 주의):

## democlaw 레포 관련 (현 상태)

최근 커밋:
- `0be6208` fix(dgx-spark): guard Gemma 4 cache scan against pipefail abort
- `4714268` fix(dgx-spark): bound Gemma 4 cache scan with timeout + prune
- `d4feb91` fix(dgx-spark): filter ephemeral mounts in MODEL_DIR picker + doctor upgrades
- `bdb0bd8` fix(dgx-spark): auto-resolve MODEL_DIR + add doctor.sh diagnostic
- `3f7ff3d` fix(dgx-spark): pin MODEL_DIR to /data/models (초기 시도, 효과 없음)
- `65ec180` fix(dgx-spark): preflight container GPU access before starting vLLM

이번 디버그 결과에 따라 start.sh에 추가될 가능성 있는 것들:
1. `VLLM_ATTENTION_BACKEND` env 기본값 (Triton 회피)
2. SIGINT trap → `docker rm -f democlaw-vllm`
3. Shard progress watchdog → 무진행 시 조기 종료
4. `--enforce-eager` 기본값 (DGX Spark 프로파일 한정)
5. `VLLM_USE_V1=0` 기본값 (DGX Spark + v1 instability 확인 시)
