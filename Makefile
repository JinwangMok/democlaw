# =============================================================================
# DemoClaw — Makefile
#
# Container lifecycle targets for the llama.cpp + OpenClaw stack.
# All targets invoke the shell scripts in scripts/ which auto-detect
# the container runtime (docker or podman).
#
# Self-documenting: run  make help  to list all targets with descriptions.
# Lines starting with  ##@  define section headers.
# Lines starting with  ##   immediately before a target define its description.
#
# Override the container runtime:
#   make start CONTAINER_RUNTIME=podman
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS_DIR  := $(PROJECT_ROOT)scripts

# ---------------------------------------------------------------------------
# Container runtime detection (mirrors scripts/lib/runtime.sh logic).
# Honour CONTAINER_RUNTIME env var first, then prefer docker, then podman.
# ---------------------------------------------------------------------------
CONTAINER_RUNTIME ?= $(shell \
	if command -v docker >/dev/null 2>&1; then echo docker; \
	elif command -v podman >/dev/null 2>&1; then echo podman; \
	else echo ""; \
	fi)

# Container and image names (match defaults in scripts and .env.example)
LLAMACPP_CONTAINER_NAME ?= democlaw-llamacpp
OPENCLAW_CONTAINER_NAME ?= democlaw-openclaw
LLAMACPP_IMAGE_TAG      ?= democlaw/llamacpp:latest
OPENCLAW_IMAGE_TAG      ?= democlaw/openclaw:latest
DEMOCLAW_NETWORK        ?= democlaw-net

# ---------------------------------------------------------------------------
# Build options
# Set NO_CACHE=1 to force a clean rebuild (passes --no-cache to the runtime).
# BUILDKIT is enabled by default for Docker; podman uses BuildKit natively.
# Override image tags at the command line:
#   make build LLAMACPP_IMAGE_TAG=my-org/llamacpp:dev OPENCLAW_IMAGE_TAG=my-org/openclaw:dev
# ---------------------------------------------------------------------------
NO_CACHE              ?=
DOCKER_BUILDKIT       ?= 1
_BUILD_NOCACHE_FLAG    = $(if $(NO_CACHE),--no-cache,)

export DOCKER_BUILDKIT

# ---------------------------------------------------------------------------
# Version and build metadata
# VERSION:     derived from git describe (semver tag); falls back to "dev"
# BUILD_DATE:  ISO-8601 UTC timestamp injected as OCI label at build time
# GIT_COMMIT:  short SHA of the current HEAD for traceability
# ---------------------------------------------------------------------------
VERSION    ?= $(shell git -C "$(PROJECT_ROOT)" describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_DATE ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT ?= $(shell git -C "$(PROJECT_ROOT)" rev-parse --short HEAD 2>/dev/null || echo "unknown")
REPO_URL   ?= https://github.com/democlaw/democlaw

# ---------------------------------------------------------------------------
# Component versions used as Docker build arguments
# Override these to pin specific upstream releases:
#   make build LLAMA_CPP_TAG=b5000 NODE_MAJOR=22
# ---------------------------------------------------------------------------
LLAMA_CPP_TAG        ?= master
CUDA_VERSION         ?= 12.6.3
CUDA_ARCHITECTURES   ?= 86
NODE_MAJOR           ?= 20
OPENCLAW_NPM_VERSION ?= latest

# Base image references used by the 'pull-*' targets.
OPENCLAW_BASE_IMAGE ?= ubuntu:24.04

# ---------------------------------------------------------------------------
# Model and port configuration (mirrors .env.example defaults)
# ---------------------------------------------------------------------------
MODEL_NAME             ?= Qwen3.5-9B-Q4_K_M
MODEL_REPO             ?= unsloth/Qwen3.5-9B-GGUF
MODEL_FILE             ?= Qwen3.5-9B-Q4_K_M.gguf
LLAMACPP_PORT          ?= 8000
LLAMACPP_HOST_PORT     ?= 8000
OPENCLAW_PORT          ?= 18789
OPENCLAW_HOST_PORT     ?= 18789
CTX_SIZE               ?= 32768
N_GPU_LAYERS           ?= 99
FLASH_ATTN             ?= 1
CACHE_TYPE_K           ?= q8_0
CACHE_TYPE_V           ?= q8_0
LLAMACPP_BASE_URL      ?= http://llamacpp:8000/v1
LLAMACPP_API_KEY       ?= EMPTY
LLAMACPP_MODEL_NAME    ?= Qwen3.5-9B-Q4_K_M
MODEL_DIR              ?= $(HOME)/.cache/democlaw/models
HF_TOKEN               ?=

# ---------------------------------------------------------------------------
# GPU passthrough flags
# docker uses --gpus all (nvidia-container-toolkit OCI hook).
# podman 4+ uses CDI: --device nvidia.com/gpu=all
# podman <4 falls back to raw device nodes.
# ---------------------------------------------------------------------------
GPU_FLAGS ?= $(shell \
	if [ "$(CONTAINER_RUNTIME)" = "podman" ]; then \
		pv=$$($(CONTAINER_RUNTIME) --version 2>/dev/null | grep -oE '[0-9]+' | head -1); \
		if [ "$${pv:-0}" -ge 4 ] 2>/dev/null; then \
			echo "--device nvidia.com/gpu=all"; \
		else \
			echo "--device /dev/nvidia0 --device /dev/nvidiactl --device /dev/nvidia-uvm"; \
		fi; \
	else \
		echo "--gpus all"; \
	fi)

# ---------------------------------------------------------------------------
# Runtime availability guard
# The _require-runtime internal target is wired as a prerequisite to all
# targets that invoke the container runtime.  It fails fast with a clear,
# actionable error when neither docker nor podman can be found.
# ---------------------------------------------------------------------------
define _runtime_missing_msg
[error] No container runtime found in PATH.
[error] Install docker  : https://docs.docker.com/engine/install/
[error] Install podman  : https://podman.io/getting-started/installation
[error] Or override via : make <target> CONTAINER_RUNTIME=docker
endef
export _runtime_missing_msg

# Export so shell scripts inherit these values
export CONTAINER_RUNTIME
export LLAMACPP_CONTAINER_NAME
export OPENCLAW_CONTAINER_NAME
export LLAMACPP_IMAGE_TAG
export OPENCLAW_IMAGE_TAG
export DEMOCLAW_NETWORK
export MODEL_NAME
export LLAMACPP_PORT
export LLAMACPP_HOST_PORT
export OPENCLAW_PORT
export OPENCLAW_HOST_PORT
export MAX_MODEL_LEN
export GPU_MEMORY_UTILIZATION
export QUANTIZATION
export DTYPE
export LLAMACPP_BASE_URL
export LLAMACPP_API_KEY
export LLAMACPP_MODEL_NAME
export HF_CACHE_DIR
export HF_TOKEN
export GPU_FLAGS
export VERSION
export BUILD_DATE
export GIT_COMMIT
export NODE_MAJOR
export OPENCLAW_NPM_VERSION
export OPENCLAW_BASE_IMAGE

# =============================================================================
# .PHONY declarations
# =============================================================================

.PHONY: build build-all start stop restart restart-all clean prune status logs help \
       health health-check validate-api validate-korean validate-connection validate-connection-host ps follow follow-llamacpp follow-openclaw \
       shell shell-llamacpp shell-openclaw inspect-llamacpp inspect-openclaw \
       top-llamacpp top-openclaw env-check check-gpu build-info \
       run-llamacpp run-openclaw start-all stop-llamacpp stop-openclaw stop-all \
       restart-llamacpp restart-openclaw \
       build-llamacpp build-openclaw start-llamacpp start-openclaw logs-llamacpp logs-openclaw \
       build-docker build-podman \
       build-llamacpp-docker build-llamacpp-podman \
       build-openclaw-docker build-openclaw-podman \
       run-llamacpp-docker run-llamacpp-podman \
       run-openclaw-docker run-openclaw-podman \
       start-llamacpp-docker start-llamacpp-podman \
       start-openclaw-docker start-openclaw-podman \
       start-docker start-podman \
       pull pull-llamacpp pull-openclaw \
       _require-runtime

# =============================================================================
# Internal guards
# =============================================================================

# _require-runtime: Fail fast with a clear message if no container runtime found.
# Wired as a prerequisite to every target that invokes the container runtime so
# that errors surface immediately with actionable guidance rather than as a
# confusing "command not found" or empty-variable failure.
_require-runtime:
	@if [ -z "$(CONTAINER_RUNTIME)" ]; then \
		echo "$$_runtime_missing_msg" >&2; \
		exit 1; \
	fi
	@command -v "$(CONTAINER_RUNTIME)" >/dev/null 2>&1 || { \
		echo "[error] CONTAINER_RUNTIME='$(CONTAINER_RUNTIME)' not found in PATH." >&2; \
		echo "[error] Install $(CONTAINER_RUNTIME) or override: make <target> CONTAINER_RUNTIME=docker" >&2; \
		exit 1; \
	}

# =============================================================================
##@ Lifecycle
# =============================================================================

## build: Build both llama.cpp and OpenClaw container images
build: _require-runtime build-llamacpp build-openclaw

## build-all: Alias for build — build both llama.cpp and OpenClaw container images
build-all: _require-runtime build-llamacpp build-openclaw

## start: Start the full DemoClaw stack (llama.cpp + OpenClaw, with health wait)
start: _require-runtime
	@bash "$(SCRIPTS_DIR)/start.sh"

## start-all: Start both services in sequence (llama.cpp then OpenClaw, with validation and health checks)
start-all: _require-runtime start-llamacpp start-openclaw

## stop: Stop and remove all DemoClaw containers
stop: _require-runtime
	@bash "$(SCRIPTS_DIR)/stop.sh"

## stop-all: Stop OpenClaw then llama.cpp (ordered teardown)
stop-all: _require-runtime stop-openclaw stop-llamacpp

## restart: Stop then start the full stack (ordered: stop all, then start all)
restart: stop start

## restart-all: Alias for restart — stop all then start all containers
restart-all: stop start

## clean: Stop containers, remove images, dangling volumes, and the shared network
clean: _require-runtime
	@REMOVE_NETWORK=true bash "$(SCRIPTS_DIR)/stop.sh"
	@echo "[clean] Removing container images ..."
	@$(CONTAINER_RUNTIME) rmi -f $(LLAMACPP_IMAGE_TAG) 2>/dev/null || true
	@$(CONTAINER_RUNTIME) rmi -f $(OPENCLAW_IMAGE_TAG) 2>/dev/null || true
	@echo "[clean] Pruning dangling volumes ..."
	@$(CONTAINER_RUNTIME) volume prune -f 2>/dev/null || true
	@echo "[clean] Note: HuggingFace model cache at $(HF_CACHE_DIR) is a host bind mount"
	@echo "[clean]       and is intentionally preserved.  To also purge downloaded weights:"
	@echo "[clean]         rm -rf $(HF_CACHE_DIR)"
	@echo "[clean] Done."

## prune: Deep clean — stop containers, remove DemoClaw images, prune ALL dangling images/volumes/build cache, and remove the network
prune: _require-runtime
	@REMOVE_NETWORK=true bash "$(SCRIPTS_DIR)/stop.sh"
	@echo "[prune] Removing DemoClaw container images ..."
	@$(CONTAINER_RUNTIME) rmi -f $(LLAMACPP_IMAGE_TAG) 2>/dev/null || true
	@$(CONTAINER_RUNTIME) rmi -f $(OPENCLAW_IMAGE_TAG) 2>/dev/null || true
	@echo "[prune] Pruning ALL dangling images ..."
	@$(CONTAINER_RUNTIME) image prune -f 2>/dev/null || true
	@echo "[prune] Pruning ALL unused volumes ..."
	@$(CONTAINER_RUNTIME) volume prune -f 2>/dev/null || true
	@echo "[prune] Pruning build cache ..."
	@$(CONTAINER_RUNTIME) builder prune -f 2>/dev/null || true
	@echo "[prune] Note: HuggingFace model cache at $(HF_CACHE_DIR) is a host bind mount"
	@echo "[prune]       and is intentionally preserved.  To also purge downloaded weights:"
	@echo "[prune]         rm -rf $(HF_CACHE_DIR)"
	@echo "[prune] Done."

# =============================================================================
##@ Per-service
# =============================================================================

## build-llamacpp: Build the llama.cpp container image (set NO_CACHE=1 to skip layer cache)
build-llamacpp: _require-runtime
	@echo "[build] Building llama.cpp image '$(LLAMACPP_IMAGE_TAG)' with runtime '$(CONTAINER_RUNTIME)' ..."
	@echo "[build]   CUDA         : $(CUDA_VERSION)"
	@echo "[build]   llama.cpp    : $(LLAMA_CPP_TAG)"
	@echo "[build]   Model        : $(MODEL_NAME)"
	@echo "[build]   Version      : $(VERSION)  commit=$(GIT_COMMIT)"
	@$(if $(NO_CACHE),echo "[build] Cache disabled (NO_CACHE=1)",)
	@$(CONTAINER_RUNTIME) build $(_BUILD_NOCACHE_FLAG) \
		--build-arg CUDA_VERSION=$(CUDA_VERSION) \
		--build-arg LLAMA_CPP_TAG=$(LLAMA_CPP_TAG) \
		--build-arg CUDA_ARCHITECTURES=$(CUDA_ARCHITECTURES) \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--label "org.opencontainers.image.title=democlaw-llamacpp" \
		--label "org.opencontainers.image.description=llama.cpp OpenAI-compatible server for Qwen3.5-9B Q4_K_M GGUF" \
		--label "org.opencontainers.image.version=$(VERSION)" \
		--label "org.opencontainers.image.created=$(BUILD_DATE)" \
		--label "org.opencontainers.image.revision=$(GIT_COMMIT)" \
		--label "org.opencontainers.image.source=$(REPO_URL)" \
		--label "org.opencontainers.image.licenses=MIT" \
		--label "org.opencontainers.image.vendor=democlaw" \
		--label "democlaw.engine=llama.cpp" \
		--label "democlaw.model=$(MODEL_NAME)" \
		-t $(LLAMACPP_IMAGE_TAG) \
		"$(PROJECT_ROOT)llamacpp"
	@echo "[build] llama.cpp image '$(LLAMACPP_IMAGE_TAG)' ready."

## build-openclaw: Build the OpenClaw container image (set NO_CACHE=1 to skip layer cache)
build-openclaw: _require-runtime
	@echo "[build] Building OpenClaw image '$(OPENCLAW_IMAGE_TAG)' with runtime '$(CONTAINER_RUNTIME)' ..."
	@echo "[build]   Node.js major : $(NODE_MAJOR)"
	@echo "[build]   OpenClaw pkg  : $(OPENCLAW_NPM_VERSION)"
	@echo "[build]   Version       : $(VERSION)  commit=$(GIT_COMMIT)"
	@$(if $(NO_CACHE),echo "[build] Cache disabled (NO_CACHE=1)",)
	@$(CONTAINER_RUNTIME) build $(_BUILD_NOCACHE_FLAG) \
		--build-arg NODE_MAJOR=$(NODE_MAJOR) \
		--build-arg OPENCLAW_NPM_VERSION=$(OPENCLAW_NPM_VERSION) \
		--build-arg LLAMACPP_BASE_URL=$(LLAMACPP_BASE_URL) \
		--build-arg LLAMACPP_MODEL_NAME=$(LLAMACPP_MODEL_NAME) \
		--build-arg OPENCLAW_PORT=$(OPENCLAW_PORT) \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--label "org.opencontainers.image.title=democlaw-openclaw" \
		--label "org.opencontainers.image.description=OpenClaw AI assistant configured with llama.cpp backend" \
		--label "org.opencontainers.image.version=$(VERSION)" \
		--label "org.opencontainers.image.created=$(BUILD_DATE)" \
		--label "org.opencontainers.image.revision=$(GIT_COMMIT)" \
		--label "org.opencontainers.image.source=$(REPO_URL)" \
		--label "org.opencontainers.image.licenses=MIT" \
		--label "org.opencontainers.image.vendor=democlaw" \
		--label "democlaw.node-major=$(NODE_MAJOR)" \
		--label "democlaw.llamacpp-url=$(LLAMACPP_BASE_URL)" \
		-t $(OPENCLAW_IMAGE_TAG) \
		"$(PROJECT_ROOT)openclaw"
	@echo "[build] OpenClaw image '$(OPENCLAW_IMAGE_TAG)' ready."

# =============================================================================
##@ Explicit-runtime build targets
# Build both images (or individual images) pinned to a specific container
# runtime, regardless of what CONTAINER_RUNTIME auto-detects.
# Useful in CI pipelines where you want deterministic runtime selection.
# =============================================================================

## build-docker: Build both llama.cpp and OpenClaw images using docker
build-docker:
	@$(MAKE) build CONTAINER_RUNTIME=docker

## build-podman: Build both llama.cpp and OpenClaw images using podman
build-podman:
	@$(MAKE) build CONTAINER_RUNTIME=podman

## build-llamacpp-docker: Build the llama.cpp image using docker
build-llamacpp-docker:
	@$(MAKE) build-llamacpp CONTAINER_RUNTIME=docker

## build-llamacpp-podman: Build the llama.cpp image using podman
build-llamacpp-podman:
	@$(MAKE) build-llamacpp CONTAINER_RUNTIME=podman

## build-openclaw-docker: Build the OpenClaw image using docker
build-openclaw-docker:
	@$(MAKE) build-openclaw CONTAINER_RUNTIME=docker

## build-openclaw-podman: Build the OpenClaw image using podman
build-openclaw-podman:
	@$(MAKE) build-openclaw CONTAINER_RUNTIME=podman

# =============================================================================
##@ Explicit-runtime run/start targets
# Run or start individual services (or the full stack) pinned to a specific
# container runtime, regardless of what CONTAINER_RUNTIME auto-detects.
# These mirror the build-*-docker / build-*-podman pattern above.
#
# Equivalent to:   make <target> CONTAINER_RUNTIME=docker|podman
# =============================================================================

## run-llamacpp-docker: Run the llama.cpp container directly using docker (GPU + network + ports)
run-llamacpp-docker:
	@$(MAKE) run-llamacpp CONTAINER_RUNTIME=docker

## run-llamacpp-podman: Run the llama.cpp container directly using podman (GPU + network + ports)
run-llamacpp-podman:
	@$(MAKE) run-llamacpp CONTAINER_RUNTIME=podman

## run-openclaw-docker: Run the OpenClaw container directly using docker (network + ports)
run-openclaw-docker:
	@$(MAKE) run-openclaw CONTAINER_RUNTIME=docker

## run-openclaw-podman: Run the OpenClaw container directly using podman (network + ports)
run-openclaw-podman:
	@$(MAKE) run-openclaw CONTAINER_RUNTIME=podman

## start-llamacpp-docker: Start the llama.cpp container using docker (GPU validation + health wait)
start-llamacpp-docker:
	@$(MAKE) start-llamacpp CONTAINER_RUNTIME=docker

## start-llamacpp-podman: Start the llama.cpp container using podman (GPU validation + health wait)
start-llamacpp-podman:
	@$(MAKE) start-llamacpp CONTAINER_RUNTIME=podman

## start-openclaw-docker: Start the OpenClaw container using docker (health wait)
start-openclaw-docker:
	@$(MAKE) start-openclaw CONTAINER_RUNTIME=docker

## start-openclaw-podman: Start the OpenClaw container using podman (health wait)
start-openclaw-podman:
	@$(MAKE) start-openclaw CONTAINER_RUNTIME=podman

## start-docker: Start the full DemoClaw stack using docker
start-docker:
	@$(MAKE) start CONTAINER_RUNTIME=docker

## start-podman: Start the full DemoClaw stack using podman
start-podman:
	@$(MAKE) start CONTAINER_RUNTIME=podman

## start-llamacpp: Start the llama.cpp container (GPU validation + model pull + health wait)
start-llamacpp: _require-runtime
	@bash "$(SCRIPTS_DIR)/start-llamacpp.sh"

## start-openclaw: Start the OpenClaw container (with health wait)
start-openclaw: _require-runtime
	@bash "$(SCRIPTS_DIR)/start-openclaw.sh"

## run-llamacpp: Run the llama.cpp container directly (GPU + network + ports + env vars, no health wait)
run-llamacpp: _require-runtime
	@if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then \
		echo "[run-llamacpp] ERROR: NVIDIA GPU / nvidia-smi not available." >&2; \
		echo "[run-llamacpp] ERROR: A CUDA-capable NVIDIA GPU is required. There is no CPU fallback." >&2; \
		exit 1; \
	fi
	@echo "[run-llamacpp] Ensuring network '$(DEMOCLAW_NETWORK)' exists ..."
	@$(CONTAINER_RUNTIME) network inspect $(DEMOCLAW_NETWORK) >/dev/null 2>&1 \
		|| $(CONTAINER_RUNTIME) network create $(DEMOCLAW_NETWORK)
	@mkdir -p "$(HF_CACHE_DIR)"
	@echo "[run-llamacpp] Starting llama.cpp container '$(LLAMACPP_CONTAINER_NAME)' ..."
	@echo "[run-llamacpp]   Image       : $(LLAMACPP_IMAGE_TAG)"
	@echo "[run-llamacpp]   Model       : $(MODEL_NAME)"
	@echo "[run-llamacpp]   GPU flags   : $(GPU_FLAGS)"
	@echo "[run-llamacpp]   Host port   : $(LLAMACPP_HOST_PORT) -> container $(LLAMACPP_PORT)"
	$(CONTAINER_RUNTIME) run -d \
		--name $(LLAMACPP_CONTAINER_NAME) \
		--network $(DEMOCLAW_NETWORK) \
		--hostname llamacpp \
		--network-alias llamacpp \
		$(GPU_FLAGS) \
		--restart unless-stopped \
		--shm-size 1g \
		-p $(LLAMACPP_HOST_PORT):$(LLAMACPP_PORT) \
		-v "$(HF_CACHE_DIR):/root/.cache/huggingface:rw" \
		-e MODEL_NAME=$(MODEL_NAME) \
		-e LLAMACPP_PORT=$(LLAMACPP_PORT) \
		-e CTX_SIZE=$(CTX_SIZE) \
		-e N_GPU_LAYERS=$(N_GPU_LAYERS) \
		-e FLASH_ATTN=$(FLASH_ATTN) \
		-e CACHE_TYPE_K=$(CACHE_TYPE_K) \
		-e CACHE_TYPE_V=$(CACHE_TYPE_V) \
		-e HF_TOKEN=$(HF_TOKEN) \
		-e HUGGING_FACE_HUB_TOKEN=$(HF_TOKEN) \
		--cap-drop ALL \
		--security-opt no-new-privileges \
		$(LLAMACPP_IMAGE_TAG)
	@echo "[run-llamacpp] Container '$(LLAMACPP_CONTAINER_NAME)' started."
	@echo "[run-llamacpp] API endpoint : http://localhost:$(LLAMACPP_HOST_PORT)/v1"
	@echo "[run-llamacpp] Stream logs  : $(CONTAINER_RUNTIME) logs -f $(LLAMACPP_CONTAINER_NAME)"

## run-openclaw: Run the OpenClaw container directly (network + ports + env vars, no health wait)
run-openclaw: _require-runtime
	@echo "[run-openclaw] Ensuring network '$(DEMOCLAW_NETWORK)' exists ..."
	@$(CONTAINER_RUNTIME) network inspect $(DEMOCLAW_NETWORK) >/dev/null 2>&1 \
		|| $(CONTAINER_RUNTIME) network create $(DEMOCLAW_NETWORK)
	@echo "[run-openclaw] Starting OpenClaw container '$(OPENCLAW_CONTAINER_NAME)' ..."
	@echo "[run-openclaw]   Image       : $(OPENCLAW_IMAGE_TAG)"
	@echo "[run-openclaw]   llama.cpp URL : $(LLAMACPP_BASE_URL)"
	@echo "[run-openclaw]   Model       : $(LLAMACPP_MODEL_NAME)"
	@echo "[run-openclaw]   Host port   : $(OPENCLAW_HOST_PORT) -> container $(OPENCLAW_PORT)"
	$(CONTAINER_RUNTIME) run -d \
		--name $(OPENCLAW_CONTAINER_NAME) \
		--network $(DEMOCLAW_NETWORK) \
		--hostname openclaw \
		--network-alias openclaw \
		--restart unless-stopped \
		-p $(OPENCLAW_HOST_PORT):$(OPENCLAW_PORT) \
		-e LLAMACPP_BASE_URL=$(LLAMACPP_BASE_URL) \
		-e LLAMACPP_API_KEY=$(LLAMACPP_API_KEY) \
		-e LLAMACPP_MODEL_NAME=$(LLAMACPP_MODEL_NAME) \
		-e OPENCLAW_PORT=$(OPENCLAW_PORT) \
		-e OPENAI_API_BASE=$(LLAMACPP_BASE_URL) \
		-e OPENAI_BASE_URL=$(LLAMACPP_BASE_URL) \
		-e OPENAI_API_KEY=$(LLAMACPP_API_KEY) \
		-e OPENAI_MODEL=$(LLAMACPP_MODEL_NAME) \
		-e OPENCLAW_LLM_PROVIDER=openai-compatible \
		-e OPENCLAW_LLM_BASE_URL=$(LLAMACPP_BASE_URL) \
		-e OPENCLAW_LLM_API_KEY=$(LLAMACPP_API_KEY) \
		-e OPENCLAW_LLM_MODEL=$(LLAMACPP_MODEL_NAME) \
		--cap-drop ALL \
		--security-opt no-new-privileges \
		--read-only \
		--tmpfs /tmp:rw,noexec,nosuid \
		--tmpfs /app/config:rw,noexec,nosuid,uid=1000,gid=1000 \
		--tmpfs /home/openclaw:rw,noexec,nosuid,uid=1000,gid=1000 \
		$(OPENCLAW_IMAGE_TAG)
	@echo "[run-openclaw] Container '$(OPENCLAW_CONTAINER_NAME)' started."
	@echo "[run-openclaw] Dashboard   : http://localhost:$(OPENCLAW_HOST_PORT)"
	@echo "[run-openclaw] Stream logs : $(CONTAINER_RUNTIME) logs -f $(OPENCLAW_CONTAINER_NAME)"

## stop-llamacpp: Stop and remove the llama.cpp container
stop-llamacpp: _require-runtime
	@echo "[stop-llamacpp] Stopping and removing container '$(LLAMACPP_CONTAINER_NAME)' ..."
	@$(CONTAINER_RUNTIME) rm -f $(LLAMACPP_CONTAINER_NAME) 2>/dev/null \
		&& echo "[stop-llamacpp] Done." \
		|| echo "[stop-llamacpp] Container '$(LLAMACPP_CONTAINER_NAME)' not found — already removed."

## stop-openclaw: Stop and remove the OpenClaw container
stop-openclaw: _require-runtime
	@echo "[stop-openclaw] Stopping and removing container '$(OPENCLAW_CONTAINER_NAME)' ..."
	@$(CONTAINER_RUNTIME) rm -f $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
		&& echo "[stop-openclaw] Done." \
		|| echo "[stop-openclaw] Container '$(OPENCLAW_CONTAINER_NAME)' not found — already removed."

## restart-llamacpp: Stop then restart the llama.cpp container (GPU validation + model pull + health wait)
restart-llamacpp: stop-llamacpp start-llamacpp

## restart-openclaw: Stop then restart the OpenClaw container (with health wait)
restart-openclaw: stop-openclaw start-openclaw

# =============================================================================
##@ Base Images
# Pre-pull upstream base images from their registries so that subsequent
# 'make build' runs reuse the local cache rather than re-downloading layers.
# Useful when preparing an air-gapped environment or caching images in CI.
#
# Images pulled:
#   llama.cpp base : built from CUDA base image during 'make build-llamacpp'
#   OpenClaw base  : ubuntu:24.04                          (Docker Hub)
#
# =============================================================================

## pull: Pull both llama.cpp and OpenClaw base images from their registries
pull: pull-llamacpp pull-openclaw

## pull-llamacpp: Pull the llama.cpp base image (CUDA base used during build)
pull-llamacpp:
	@echo "[pull] The llama.cpp image is built from source — run 'make build-llamacpp' to build it."

## pull-openclaw: Pull the OpenClaw base image (ubuntu:24.04)
pull-openclaw:
	@echo "[pull] Pulling OpenClaw base image '$(OPENCLAW_BASE_IMAGE)' using $(CONTAINER_RUNTIME) ..."
	@$(CONTAINER_RUNTIME) pull $(OPENCLAW_BASE_IMAGE)
	@echo "[pull] OpenClaw base image '$(OPENCLAW_BASE_IMAGE)' is up to date."

# =============================================================================
##@ Monitoring & Logs
# =============================================================================

## status: Show running DemoClaw containers and their health state
status:
	@echo "DemoClaw — Container Status"
	@echo "==========================="
	@$(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(LLAMACPP_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" \
		--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null \
	|| $(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(LLAMACPP_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" 2>/dev/null \
	|| echo "(no containers found)"
	@echo ""
	@bash "$(SCRIPTS_DIR)/healthcheck.sh"

## health: Alias for 'status' — run all service healthchecks
health: status

## health-check: Alias for 'status' — run all service healthchecks
health-check: status

## validate-api: Validate llama.cpp OpenAI-compatible API endpoints (/health, /v1/models, /v1/chat/completions)
validate-api:
	@bash "$(SCRIPTS_DIR)/validate-api.sh"

## validate-tool-calling: Verify llama.cpp tool/function calling API (/v1/chat/completions with tools, tool_choice)
validate-tool-calling:
	@bash "$(SCRIPTS_DIR)/validate-tool-calling.sh"

## validate-korean: Validate Korean language response quality (comprehension, generation, reasoning)
validate-korean:
	@bash "$(SCRIPTS_DIR)/validate-korean-quality.sh"

## validate-connection: Confirm llama.cpp provider connection is live from within/alongside the OpenClaw container
validate-connection:
	@bash "$(SCRIPTS_DIR)/validate_connection.sh" --exec

## validate-connection-host: Confirm llama.cpp provider connection via the host-published port (localhost)
validate-connection-host:
	@bash "$(SCRIPTS_DIR)/validate_connection.sh" --host

## logs: Tail the last 50 lines from one or both containers; use SERVICE=llamacpp|openclaw to filter
logs:
	@case "$(SERVICE)" in \
		llamacpp) \
			echo "=== llama.cpp logs (last 50 lines) ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(LLAMACPP_CONTAINER_NAME) 2>/dev/null \
				|| echo "(no llama.cpp container)";; \
		openclaw) \
			echo "=== OpenClaw logs (last 50 lines) ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
				|| echo "(no OpenClaw container)";; \
		"") \
			echo "=== llama.cpp logs (last 50 lines) ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(LLAMACPP_CONTAINER_NAME) 2>/dev/null \
				|| echo "(no llama.cpp container)"; \
			echo ""; \
			echo "=== OpenClaw logs (last 50 lines) ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
				|| echo "(no OpenClaw container)"; \
			echo ""; \
			echo "Tip: use 'make logs SERVICE=llamacpp' or 'make logs SERVICE=openclaw' to filter."; \
			echo "     use 'make follow' to stream both containers in real time.";; \
		*) \
			echo "[logs] Unknown SERVICE='$(SERVICE)'. Use SERVICE=llamacpp or SERVICE=openclaw." >&2; \
			exit 1;; \
	esac

## logs-llamacpp: Show last 50 lines of llama.cpp container logs
logs-llamacpp:
	@$(CONTAINER_RUNTIME) logs --tail 50 $(LLAMACPP_CONTAINER_NAME)

## logs-openclaw: Show last 50 lines of OpenClaw container logs
logs-openclaw:
	@$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME)

## ps: Show DemoClaw container states
ps:
	@echo "DemoClaw containers:"
	@echo "--------------------"
	@$(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(LLAMACPP_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" \
		--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null \
	|| $(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(LLAMACPP_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" 2>/dev/null \
	|| echo "(no containers found)"

## follow: Follow live logs from both containers (Ctrl+C to stop)
follow:
	@echo "=== Following logs for $(LLAMACPP_CONTAINER_NAME) and $(OPENCLAW_CONTAINER_NAME) ===" && \
	echo "    (Ctrl+C to stop)" && echo "" && \
	$(CONTAINER_RUNTIME) logs -f --tail 10 $(LLAMACPP_CONTAINER_NAME) 2>/dev/null &\
	$(CONTAINER_RUNTIME) logs -f --tail 10 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null &\
	wait

## follow-llamacpp: Follow llama.cpp container logs in real time (Ctrl+C to stop)
follow-llamacpp:
	@$(CONTAINER_RUNTIME) logs -f $(LLAMACPP_CONTAINER_NAME)

## follow-openclaw: Follow OpenClaw container logs in real time (Ctrl+C to stop)
follow-openclaw:
	@$(CONTAINER_RUNTIME) logs -f $(OPENCLAW_CONTAINER_NAME)

# =============================================================================
##@ Debugging
# =============================================================================

## shell: Exec into a named container; use SERVICE=llamacpp|openclaw or CONTAINER=<name>
shell: _require-runtime
	@_svc="$(or $(SERVICE),$(CONTAINER))"; \
	if [ -z "$$_svc" ]; then \
		echo "[shell] Usage: make shell SERVICE=llamacpp|openclaw" >&2; \
		echo "[shell]        make shell CONTAINER=$(LLAMACPP_CONTAINER_NAME)" >&2; \
		echo "" >&2; \
		echo "[shell] Shortcuts:" >&2; \
		echo "[shell]   make shell-llamacpp  — exec into $(LLAMACPP_CONTAINER_NAME)" >&2; \
		echo "[shell]   make shell-openclaw  — exec into $(OPENCLAW_CONTAINER_NAME)" >&2; \
		exit 1; \
	fi; \
	case "$$_svc" in \
		llamacpp) _cname="$(LLAMACPP_CONTAINER_NAME)";; \
		openclaw) _cname="$(OPENCLAW_CONTAINER_NAME)";; \
		*)        _cname="$$_svc";; \
	esac; \
	echo "[shell] Attaching shell to '$$_cname' ..."; \
	$(CONTAINER_RUNTIME) exec -it "$$_cname" /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it "$$_cname" /bin/sh

## shell-llamacpp: Open an interactive shell inside the llama.cpp container
shell-llamacpp:
	@echo "Attaching shell to '$(LLAMACPP_CONTAINER_NAME)' ..."
	@$(CONTAINER_RUNTIME) exec -it $(LLAMACPP_CONTAINER_NAME) /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it $(LLAMACPP_CONTAINER_NAME) /bin/sh

## shell-openclaw: Open an interactive shell inside the OpenClaw container
shell-openclaw:
	@echo "Attaching shell to '$(OPENCLAW_CONTAINER_NAME)' ..."
	@$(CONTAINER_RUNTIME) exec -it $(OPENCLAW_CONTAINER_NAME) /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it $(OPENCLAW_CONTAINER_NAME) /bin/sh

## inspect-llamacpp: Show detailed llama.cpp container information (JSON)
inspect-llamacpp:
	@$(CONTAINER_RUNTIME) inspect $(LLAMACPP_CONTAINER_NAME) 2>/dev/null \
		|| echo "Container '$(LLAMACPP_CONTAINER_NAME)' not found."

## inspect-openclaw: Show detailed OpenClaw container information (JSON)
inspect-openclaw:
	@$(CONTAINER_RUNTIME) inspect $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
		|| echo "Container '$(OPENCLAW_CONTAINER_NAME)' not found."

## top-llamacpp: Show llama.cpp container resource usage (CPU, memory)
top-llamacpp:
	@$(CONTAINER_RUNTIME) stats --no-stream $(LLAMACPP_CONTAINER_NAME) 2>/dev/null \
		|| echo "Container '$(LLAMACPP_CONTAINER_NAME)' is not running."

## top-openclaw: Show OpenClaw container resource usage (CPU, memory)
top-openclaw:
	@$(CONTAINER_RUNTIME) stats --no-stream $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
		|| echo "Container '$(OPENCLAW_CONTAINER_NAME)' is not running."

## build-info: Show build configuration (versions, labels, build args) that will be used
build-info:
	@echo ""
	@echo "DemoClaw — Build Configuration"
	@echo "================================"
	@echo ""
	@echo "  Runtime         : $(or $(CONTAINER_RUNTIME),(not found — install docker or podman))"
	@echo "  Version         : $(VERSION)"
	@echo "  Build date      : $(BUILD_DATE)"
	@echo "  Git commit      : $(GIT_COMMIT)"
	@echo "  Repo URL        : $(REPO_URL)"
	@echo ""
	@echo "  llama.cpp image : $(LLAMACPP_IMAGE_TAG)"
	@echo "    llama.cpp tag : $(LLAMA_CPP_TAG)"
	@echo "    model         : $(MODEL_NAME)"
	@echo "    ctx size      : $(CTX_SIZE)"
	@echo "    n-gpu-layers  : $(N_GPU_LAYERS)"
	@echo ""
	@echo "  OpenClaw image  : $(OPENCLAW_IMAGE_TAG)"
	@echo "    node major    : $(NODE_MAJOR)"
	@echo "    openclaw pkg  : $(OPENCLAW_NPM_VERSION)"
	@echo "    port          : $(OPENCLAW_PORT)"
	@echo "    llama.cpp URL : $(LLAMACPP_BASE_URL)"
	@echo ""
	@echo "  NO_CACHE        : $(or $(NO_CACHE),(not set))"
	@echo ""

## check-gpu: Validate NVIDIA GPU, CUDA driver, VRAM, and container toolkit (exits with error if absent)
check-gpu:
	@bash "$(SCRIPTS_DIR)/check-gpu.sh"

## env-check: Validate environment prerequisites (runtime, GPU, nvidia-smi)
env-check:
	@echo "Environment Check"
	@echo "================="
	@echo ""
	@printf "  Container runtime: " && \
		(command -v $(CONTAINER_RUNTIME) >/dev/null 2>&1 \
			&& echo "$(CONTAINER_RUNTIME) ✓" \
			|| echo "NOT FOUND ✗")
	@printf "  nvidia-smi:        " && \
		(command -v nvidia-smi >/dev/null 2>&1 \
			&& echo "found ✓" \
			|| echo "NOT FOUND ✗")
	@printf "  NVIDIA GPU:        " && \
		(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
			| head -1 \
			|| echo "NOT DETECTED ✗")
	@printf "  NVIDIA runtime:    " && \
		($(CONTAINER_RUNTIME) info 2>/dev/null | grep -qi nvidia \
			&& echo "available ✓" \
			|| echo "not detected (may still work with --gpus flag) ⚠")
	@printf "  Network:           " && \
		($(CONTAINER_RUNTIME) network inspect $(DEMOCLAW_NETWORK) >/dev/null 2>&1 \
			&& echo "$(DEMOCLAW_NETWORK) exists ✓" \
			|| echo "$(DEMOCLAW_NETWORK) not created yet")
	@echo ""

# =============================================================================
##@ Help
# =============================================================================

## help: Show this help message (auto-generated from ## comments)
help:
	@printf "\n\033[1mDemoClaw — Container Lifecycle Targets\033[0m\n"
	@printf "=======================================\n"
	@printf "Runtime : \033[36m%s\033[0m\n" \
		"$(or $(CONTAINER_RUNTIME),(not found — install docker or podman))"
	@printf "Override: make <target> \033[36mCONTAINER_RUNTIME=podman\033[0m\n\n"
	@awk ' \
		/^##@ / { \
			gsub(/^##@ /, ""); \
			printf "\n\033[1m%s\033[0m\n", $$0; \
			next \
		} \
		/^## / { \
			line = substr($$0, 4); \
			colon = index(line, ":"); \
			if (colon > 0) { \
				tgt  = substr(line, 1, colon - 1); \
				desc = substr(line, colon + 2); \
				printf "  \033[36m%-22s\033[0m %s\n", tgt, desc \
			} \
			next \
		} \
	' $(MAKEFILE_LIST)
	@printf "\n\033[1mQuick examples:\033[0m\n"
	@printf "\n\033[1m  Lifecycle\033[0m\n"
	@printf "  make start                            # Start full stack (health wait)\n"
	@printf "  make start-all                        # Start both services in sequence\n"
	@printf "  make stop                             # Stop & remove all DemoClaw containers\n"
	@printf "  make stop-all                         # Graceful ordered teardown\n"
	@printf "  make restart                          # Stop then start full stack\n"
	@printf "  make restart-llamacpp                 # Restart just the llama.cpp container\n"
	@printf "  make restart-openclaw                 # Restart just the OpenClaw container\n"
	@printf "  make clean                            # Remove containers, images, volumes & network\n"
	@printf "  make prune                            # Deep clean: also prune ALL dangling images/volumes/build cache\n"
	@printf "\n\033[1m  Logs & monitoring\033[0m\n"
	@printf "  make logs                             # Tail last 50 lines from both containers\n"
	@printf "  make logs SERVICE=llamacpp            # Tail last 50 lines of llama.cpp logs only\n"
	@printf "  make logs SERVICE=openclaw            # Tail last 50 lines of OpenClaw logs only\n"
	@printf "  make logs-llamacpp                    # Tail last 50 lines of llama.cpp logs\n"
	@printf "  make logs-openclaw                    # Tail last 50 lines of OpenClaw logs\n"
	@printf "  make follow                           # Stream live logs from both containers\n"
	@printf "  make follow-llamacpp                  # Stream llama.cpp logs in real time\n"
	@printf "  make follow-openclaw                  # Stream OpenClaw logs in real time\n"
	@printf "  make status                           # Show running containers + healthchecks\n"
	@printf "  make validate-api                     # Validate llama.cpp API endpoints\n"
	@printf "  make validate-korean                  # Validate Korean language response quality\n"
	@printf "  make validate-connection              # Confirm llama.cpp provider connection via OpenClaw container\n"
	@printf "  make validate-connection-host         # Confirm llama.cpp provider connection via host port\n"
	@printf "  make ps                               # Show DemoClaw container states\n"
	@printf "\n\033[1m  Debug & diagnostics\033[0m\n"
	@printf "  make check-gpu                        # Full GPU/CUDA preflight validation\n"
	@printf "  make env-check                        # Verify GPU & runtime setup\n"
	@printf "  make shell SERVICE=llamacpp           # Exec into the llama.cpp container\n"
	@printf "  make shell SERVICE=openclaw           # Exec into the OpenClaw container\n"
	@printf "  make shell CONTAINER=<name>           # Exec into any container by full name\n"
	@printf "  make shell-llamacpp                   # Open shell inside llama.cpp container\n"
	@printf "  make shell-openclaw                   # Open shell inside OpenClaw container\n"
	@printf "  make inspect-llamacpp                 # Show llama.cpp container details (JSON)\n"
	@printf "  make top-llamacpp                     # Show llama.cpp resource usage\n"
	@printf "\n\033[1m  Base images\033[0m\n"
	@printf "  make pull                             # Pull both llama.cpp and OpenClaw base images\n"
	@printf "  make pull-llamacpp                    # Build llama.cpp image from source\n"
	@printf "  make pull-openclaw                    # Pull OpenClaw base image (ubuntu:24.04)\n"
	@printf "\n\033[1m  Build options\033[0m\n"
	@printf "  make build                            # Build both images (auto-detect runtime)\n"
	@printf "  make build NO_CACHE=1                 # Force clean image rebuild\n"
	@printf "  make build-llamacpp LLAMACPP_IMAGE_TAG=my/lc  # Custom llama.cpp image tag\n"
	@printf "  make build-docker                     # Build both images with docker\n"
	@printf "  make build-podman                     # Build both images with podman\n"
	@printf "  make build-llamacpp-docker            # Build llama.cpp image with docker\n"
	@printf "  make build-llamacpp-podman            # Build llama.cpp image with podman\n"
	@printf "  make build-openclaw-docker            # Build OpenClaw image with docker\n"
	@printf "  make build-openclaw-podman            # Build OpenClaw image with podman\n"
	@printf "  make build-info                       # Show build config, versions, and labels\n"
	@printf "  make build LLAMA_CPP_TAG=b5000        # Pin llama.cpp git tag\n"
	@printf "  make build NODE_MAJOR=22              # Build OpenClaw with Node.js 22\n"
	@printf "\n\033[1m  Runtime override (any target accepts CONTAINER_RUNTIME)\033[0m\n"
	@printf "  make start CONTAINER_RUNTIME=podman   # Force podman for any target\n"
	@printf "  make run-llamacpp-docker              # Run llama.cpp container with docker\n"
	@printf "  make run-llamacpp-podman              # Run llama.cpp container with podman\n"
	@printf "  make run-openclaw-docker              # Run OpenClaw container with docker\n"
	@printf "  make run-openclaw-podman              # Run OpenClaw container with podman\n"
	@printf "  make start-docker                     # Start full stack with docker\n"
	@printf "  make start-podman                     # Start full stack with podman\n"
	@printf "\n"
