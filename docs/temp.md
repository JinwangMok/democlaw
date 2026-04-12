# DGX Spark vLLM troubleshooting — actionable one-shot

모든 커맨드는 이 파일에서 직접 복사하세요. 원격지에서
`cat docs/temp.md` / `less docs/temp.md`로 읽으면 됩니다.

## TL;DR — 한 줄만 실행

```bash
cd democlaw && git pull origin master && ./scripts/vllm-manual.sh
```

이 한 줄이 전부입니다. 내부에서 자동으로:

1. podman / docker 자동 감지 (podman 우선)
2. 알려진 good digest(`sha256:0d152595...fea833`)로 이미지 **고정**
   (기본값 `--pin`. 며칠 전 동작했던 증거가 있는 그 digest로 강제)
3. 컨테이너 GPU 스모크 테스트 — CDI `--device nvidia.com/gpu=all` 우선,
   실패 시 legacy `--gpus all` 자동 폴백
4. `/home/user/models` 마운트
5. dgx-spark-ai-cluster reference verbatim serve 플래그 그대로
6. **sm_121 우회 env**: `TORCH_CUDA_ARCH_LIST=12.0` 외 NCCL/IPC 안전값
7. `VLLM_LOGGING_LEVEL=DEBUG` + `NCCL_DEBUG=INFO`로 스톨 시 마지막 줄이 원인 단서
8. 포그라운드 실행 + `tee /tmp/vllm-debug.log`. Ctrl+C 시 컨테이너 자동 정리
   (INT/TERM/EXIT 트랩). 노드 프리즈 예방.

## 왜 지금까지 안 됐는가 (조사 결과)

### 증거 1: `vllm/vllm-openai:gemma4-cu130` 태그가 rewrite됨

- 베어메탈에서 성공한 dgx-vllm이 썼던 digest: `sha256:0d152595...fea833`
- 현재 Docker Hub 최신 digest: `sha256:b154b0cb...` (다른 값)
- mutable tag라 `docker pull`이 며칠 전과 다른 이미지를 가져옴 =
  **"며칠 전엔 됐는데 지금은 안 됨" regression의 가장 유력한 원인.**

### 증거 2: vLLM 이슈 #28589 — Blackwell GB10 sm_121a 버그

```
triton.runtime.errors.PTXASError:
ptxas fatal : Value 'sm_121a' is not defined for option 'gpu-name'
```

```
ValueError: Selected backend AttentionBackendEnum.XFORMERS is not valid.
Reason: ['sink setting not supported']
```

- 새 이미지(PyTorch/Triton 업데이트 포함)에서 ptxas가 `sm_121a`를 모름 →
  Triton이 attention 커널 PTX 생성에서 에러 루프.
- 다른 백엔드(XFORMERS/FLASH_ATTN/FLASHINFER)는 Gemma 4의 **attention sinks**를
  지원 안 해서 거부 → v1 엔진이 폴백할 선택지가 없어 Triton으로 떨어지고
  거기서 멈춤. **우리 증상과 정확히 일치.**

### 증거 3: 환경이 분할됨

- **성공한 환경** = 베어메탈 DGX Spark + docker
- **실패한 환경** = 같은 물리 장비 위 nested custom container (k8s pod 형태) +
  **podman**. cgroup 격리 제한, `--shm-size` + `--ipc host` 공존 불가,
  `docker top`/`docker stats`가 "cannot create cgroup" 에러.
- dgx-spark-ai-cluster의 setup-single.sh / docker-compose는 nested podman을
  전혀 대비하지 않음 (순수 docker 전제).

### 증거 4: 작은 모델(opt-125m)은 우회로 성공

- `VLLM_ATTENTION_BACKEND=TORCH_SDPA --enforce-eager --max-model-len 2048`로
  opt-125m은 `Uvicorn running`까지 도달.
- 같은 env로 gemma-4-26B는 실패 → Gemma 4 MoE의 sink 요구 + 큰 kernel surface
  조합에서만 재현. "작은 모델 된다고 큰 모델 된다"는 공식은 거짓.

### 증거 5: "safety" 변형이 오히려 깨뜨림

이 디버그 과정에서 제가 시도한 `--enforce-eager`, `VLLM_USE_V1=0`,
`gpu_memory_utilization=0.60`, `max_model_len=32768`, 백엔드 override —
**전부 reference와 다른 코드 경로**. reference가 성공했을 때 하나도 안 썼음.
`vllm-manual.sh`은 이 모든 변형을 기본값에서 제거했고, 필요 시 `--backend`
`--v0` 플래그로 **수동** 재활성만 가능.

## 시나리오별 다음 수

### (a) 성공 — `Uvicorn running on http://0.0.0.0:8000` 로그 보임

끝. 검증:
```bash
curl -sf http://localhost:8000/v1/models | head
curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
```

### (b) 스톨 — 60초 이상 새 로그 없음

Ctrl+C로 빠져나오고(포그라운드 + 트랩 덕에 안전), `/tmp/vllm-debug.log`의
**마지막 40줄만** 복사해서 저에게 전달:
```bash
tail -40 /tmp/vllm-debug.log
```

그 40줄이 원인 레이어를 찍어줍니다:
- `NCCL INFO Bootstrap ...` 뒤 정지 → NCCL 초기화 (env로 방어 시도됨)
- `HfHub ... retrying ...` → HF 접근 (HF_TOKEN 필요)
- `Starting to load model ...` 뒤 정지 → 로더 워커 spawn (podman 격리 이슈)
- `compiling ...` / `ptxas ... sm_121a` → Triton sm_121a 버그 확정
- `cuda.py:274` 뒤 정말 아무것도 없음 → OS syscall deadlock (재부팅 필요)

### (c) 에러 종료

```bash
tail -40 /tmp/vllm-debug.log
```

### 디지스트 확인만 먼저 하고 싶을 때

```bash
./scripts/vllm-manual.sh --probe
```

GPU 스모크만 돌리고 종료. 현재 pull된 digest가 known-good과 같은지 한 줄 비교.

### 이미지 고정을 원치 않을 때 (현재 태그로 실험)

```bash
./scripts/vllm-manual.sh --no-pin
```

### 백엔드 override / v0 엔진 강제

```bash
./scripts/vllm-manual.sh --backend TORCH_SDPA
./scripts/vllm-manual.sh --v0
./scripts/vllm-manual.sh --backend FLASH_ATTN --v0
```

## 안전 수칙 (다시 강조)

- **절대 `-d` 백그라운드로 vLLM을 띄우지 말 것**. 스톨 시 Ctrl+C가 안 먹고
  컨테이너가 통합 메모리를 쥔 채 남아 노드가 프리즈합니다. `vllm-manual.sh`은
  포그라운드 강제.
- **Ctrl+C가 이상하면** 새 쉘에서 `podman rm -f vllm` (또는 `docker rm -f vllm`).
- 로드 중 `podman stats`/`podman top` 금지 (cgroup 에러로 실패).
- 5분 넘어가는데 새 로그가 안 찍히면 즉시 중단 — 메모리 압박이 누적되기 전.

## 커밋 이력 (이번 세션 관련)

- `65ec180` fix(dgx-spark): preflight container GPU access before starting vLLM
- `3f7ff3d` fix(dgx-spark): pin MODEL_DIR to /data/models (초기 시도, 효과 없음)
- `bdb0bd8` fix(dgx-spark): auto-resolve MODEL_DIR + add doctor.sh diagnostic
- `d4feb91` fix(dgx-spark): filter ephemeral mounts in MODEL_DIR picker + doctor upgrades
- `4714268` fix(dgx-spark): bound Gemma 4 cache scan with timeout + prune
- `0be6208` fix(dgx-spark): guard Gemma 4 cache scan against pipefail abort
- `67221fe` docs(dgx-spark): temp.md troubleshooting scratchpad
- `876e915` docs(dgx-spark): update temp.md test B to v0+XFORMERS
- (다음 커밋) fix(dgx-spark): add vllm-manual.sh — single-command reference-verbatim launcher with sm_121 workarounds and known-good digest pin
