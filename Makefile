# =============================================================================
# DemoClaw — Makefile
#
# Container lifecycle targets for the vLLM + OpenClaw stack.
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
VLLM_CONTAINER_NAME    ?= democlaw-vllm
OPENCLAW_CONTAINER_NAME ?= democlaw-openclaw
VLLM_IMAGE_TAG         ?= democlaw/vllm:latest
OPENCLAW_IMAGE_TAG     ?= democlaw/openclaw:latest
DEMOCLAW_NETWORK       ?= democlaw-net

# ---------------------------------------------------------------------------
# Build options
# Set NO_CACHE=1 to force a clean rebuild (passes --no-cache to the runtime).
# BUILDKIT is enabled by default for Docker; podman uses BuildKit natively.
# Override image tags at the command line:
#   make build VLLM_IMAGE_TAG=my-org/vllm:dev OPENCLAW_IMAGE_TAG=my-org/openclaw:dev
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
#   make build VLLM_BASE_VERSION=v0.8.4 NODE_MAJOR=22
# ---------------------------------------------------------------------------
VLLM_BASE_VERSION    ?= v0.8.3
NODE_MAJOR           ?= 20
OPENCLAW_NPM_VERSION ?= latest

# Base image references used by the 'pull-*' targets.
# Kept in sync with the FROM directives in vllm/Dockerfile and openclaw/Dockerfile.
VLLM_BASE_IMAGE     ?= vllm/vllm-openai:$(VLLM_BASE_VERSION)
OPENCLAW_BASE_IMAGE ?= ubuntu:24.04

# ---------------------------------------------------------------------------
# Model and port configuration (mirrors .env.example defaults)
# ---------------------------------------------------------------------------
MODEL_NAME             ?= Qwen/Qwen2.5-7B-Instruct-AWQ
VLLM_PORT              ?= 8000
VLLM_HOST_PORT         ?= 8000
OPENCLAW_PORT          ?= 18789
OPENCLAW_HOST_PORT     ?= 18789
MAX_MODEL_LEN          ?= 8192
GPU_MEMORY_UTILIZATION ?= 0.90
QUANTIZATION           ?= awq
DTYPE                  ?= float16
VLLM_BASE_URL          ?= http://vllm:8000/v1
VLLM_API_KEY           ?= EMPTY
VLLM_MODEL_NAME        ?= Qwen/Qwen2.5-7B-Instruct-AWQ
HF_CACHE_DIR           ?= $(HOME)/.cache/huggingface
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
export VLLM_CONTAINER_NAME
export OPENCLAW_CONTAINER_NAME
export VLLM_IMAGE_TAG
export OPENCLAW_IMAGE_TAG
export DEMOCLAW_NETWORK
export MODEL_NAME
export VLLM_PORT
export VLLM_HOST_PORT
export OPENCLAW_PORT
export OPENCLAW_HOST_PORT
export MAX_MODEL_LEN
export GPU_MEMORY_UTILIZATION
export QUANTIZATION
export DTYPE
export VLLM_BASE_URL
export VLLM_API_KEY
export VLLM_MODEL_NAME
export HF_CACHE_DIR
export HF_TOKEN
export GPU_FLAGS
export VERSION
export BUILD_DATE
export GIT_COMMIT
export VLLM_BASE_VERSION
export NODE_MAJOR
export OPENCLAW_NPM_VERSION
export VLLM_BASE_IMAGE
export OPENCLAW_BASE_IMAGE

# =============================================================================
# .PHONY declarations
# =============================================================================

.PHONY: build build-all start stop restart restart-all clean prune status logs help \
       health health-check validate-api validate-connection validate-connection-host ps follow follow-vllm follow-openclaw \
       shell shell-vllm shell-openclaw inspect-vllm inspect-openclaw \
       top-vllm top-openclaw env-check check-gpu build-info \
       run-vllm run-openclaw start-all stop-vllm stop-openclaw stop-all \
       restart-vllm restart-openclaw \
       build-vllm build-openclaw start-vllm start-openclaw logs-vllm logs-openclaw \
       build-docker build-podman \
       build-vllm-docker build-vllm-podman \
       build-openclaw-docker build-openclaw-podman \
       run-vllm-docker run-vllm-podman \
       run-openclaw-docker run-openclaw-podman \
       start-vllm-docker start-vllm-podman \
       start-openclaw-docker start-openclaw-podman \
       start-docker start-podman \
       pull pull-vllm pull-openclaw \
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

## build: Build both vLLM and OpenClaw container images
build: _require-runtime build-vllm build-openclaw

## build-all: Alias for build — build both vLLM and OpenClaw container images
build-all: _require-runtime build-vllm build-openclaw

## start: Start the full DemoClaw stack (vLLM + OpenClaw, with health wait)
start: _require-runtime
	@bash "$(SCRIPTS_DIR)/start.sh"

## start-all: Start both services in sequence (vLLM then OpenClaw, with validation and health checks)
start-all: _require-runtime start-vllm start-openclaw

## stop: Stop and remove all DemoClaw containers
stop: _require-runtime
	@bash "$(SCRIPTS_DIR)/stop.sh"

## stop-all: Stop OpenClaw then vLLM (ordered teardown)
stop-all: _require-runtime stop-openclaw stop-vllm

## restart: Stop then start the full stack (ordered: stop all, then start all)
restart: stop start

## restart-all: Alias for restart — stop all then start all containers
restart-all: stop start

## clean: Stop containers, remove images, dangling volumes, and the shared network
clean: _require-runtime
	@REMOVE_NETWORK=true bash "$(SCRIPTS_DIR)/stop.sh"
	@echo "[clean] Removing container images ..."
	@$(CONTAINER_RUNTIME) rmi -f $(VLLM_IMAGE_TAG) 2>/dev/null || true
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
	@$(CONTAINER_RUNTIME) rmi -f $(VLLM_IMAGE_TAG) 2>/dev/null || true
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

## build-vllm: Build the vLLM container image (set NO_CACHE=1 to skip layer cache)
build-vllm: _require-runtime
	@echo "[build] Building vLLM image '$(VLLM_IMAGE_TAG)' with runtime '$(CONTAINER_RUNTIME)' ..."
	@echo "[build]   Base version : $(VLLM_BASE_VERSION)"
	@echo "[build]   Model        : $(MODEL_NAME)"
	@echo "[build]   Version      : $(VERSION)  commit=$(GIT_COMMIT)"
	@$(if $(NO_CACHE),echo "[build] Cache disabled (NO_CACHE=1)",)
	@$(CONTAINER_RUNTIME) build $(_BUILD_NOCACHE_FLAG) \
		--build-arg VLLM_BASE_VERSION=$(VLLM_BASE_VERSION) \
		--build-arg MODEL_NAME=$(MODEL_NAME) \
		--build-arg MAX_MODEL_LEN=$(MAX_MODEL_LEN) \
		--build-arg QUANTIZATION=$(QUANTIZATION) \
		--build-arg DTYPE=$(DTYPE) \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--label "org.opencontainers.image.title=democlaw-vllm" \
		--label "org.opencontainers.image.description=vLLM OpenAI-compatible server for Qwen3.5-9B AWQ 4-bit" \
		--label "org.opencontainers.image.version=$(VERSION)" \
		--label "org.opencontainers.image.created=$(BUILD_DATE)" \
		--label "org.opencontainers.image.revision=$(GIT_COMMIT)" \
		--label "org.opencontainers.image.source=$(REPO_URL)" \
		--label "org.opencontainers.image.licenses=MIT" \
		--label "org.opencontainers.image.vendor=democlaw" \
		--label "democlaw.model=$(MODEL_NAME)" \
		--label "democlaw.quantization=$(QUANTIZATION)" \
		-t $(VLLM_IMAGE_TAG) \
		"$(PROJECT_ROOT)vllm"
	@echo "[build] vLLM image '$(VLLM_IMAGE_TAG)' ready."

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
		--build-arg VLLM_BASE_URL=$(VLLM_BASE_URL) \
		--build-arg VLLM_MODEL_NAME=$(VLLM_MODEL_NAME) \
		--build-arg OPENCLAW_PORT=$(OPENCLAW_PORT) \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--label "org.opencontainers.image.title=democlaw-openclaw" \
		--label "org.opencontainers.image.description=OpenClaw AI assistant configured with vLLM backend" \
		--label "org.opencontainers.image.version=$(VERSION)" \
		--label "org.opencontainers.image.created=$(BUILD_DATE)" \
		--label "org.opencontainers.image.revision=$(GIT_COMMIT)" \
		--label "org.opencontainers.image.source=$(REPO_URL)" \
		--label "org.opencontainers.image.licenses=MIT" \
		--label "org.opencontainers.image.vendor=democlaw" \
		--label "democlaw.node-major=$(NODE_MAJOR)" \
		--label "democlaw.vllm-url=$(VLLM_BASE_URL)" \
		-t $(OPENCLAW_IMAGE_TAG) \
		"$(PROJECT_ROOT)openclaw"
	@echo "[build] OpenClaw image '$(OPENCLAW_IMAGE_TAG)' ready."

# =============================================================================
##@ Explicit-runtime build targets
# Build both images (or individual images) pinned to a specific container
# runtime, regardless of what CONTAINER_RUNTIME auto-detects.
# Useful in CI pipelines where you want deterministic runtime selection.
# =============================================================================

## build-docker: Build both vLLM and OpenClaw images using docker
build-docker:
	@$(MAKE) build CONTAINER_RUNTIME=docker

## build-podman: Build both vLLM and OpenClaw images using podman
build-podman:
	@$(MAKE) build CONTAINER_RUNTIME=podman

## build-vllm-docker: Build the vLLM image using docker
build-vllm-docker:
	@$(MAKE) build-vllm CONTAINER_RUNTIME=docker

## build-vllm-podman: Build the vLLM image using podman
build-vllm-podman:
	@$(MAKE) build-vllm CONTAINER_RUNTIME=podman

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

## run-vllm-docker: Run the vLLM container directly using docker (GPU + network + ports)
run-vllm-docker:
	@$(MAKE) run-vllm CONTAINER_RUNTIME=docker

## run-vllm-podman: Run the vLLM container directly using podman (GPU + network + ports)
run-vllm-podman:
	@$(MAKE) run-vllm CONTAINER_RUNTIME=podman

## run-openclaw-docker: Run the OpenClaw container directly using docker (network + ports)
run-openclaw-docker:
	@$(MAKE) run-openclaw CONTAINER_RUNTIME=docker

## run-openclaw-podman: Run the OpenClaw container directly using podman (network + ports)
run-openclaw-podman:
	@$(MAKE) run-openclaw CONTAINER_RUNTIME=podman

## start-vllm-docker: Start the vLLM container using docker (GPU validation + health wait)
start-vllm-docker:
	@$(MAKE) start-vllm CONTAINER_RUNTIME=docker

## start-vllm-podman: Start the vLLM container using podman (GPU validation + health wait)
start-vllm-podman:
	@$(MAKE) start-vllm CONTAINER_RUNTIME=podman

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

## start-vllm: Start the vLLM container (GPU validation + model pull + health wait)
start-vllm: _require-runtime
	@bash "$(SCRIPTS_DIR)/start-vllm.sh"

## start-openclaw: Start the OpenClaw container (with health wait)
start-openclaw: _require-runtime
	@bash "$(SCRIPTS_DIR)/start-openclaw.sh"

## run-vllm: Run the vLLM container directly (GPU + network + ports + env vars, no health wait)
run-vllm: _require-runtime
	@if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then \
		echo "[run-vllm] ERROR: NVIDIA GPU / nvidia-smi not available." >&2; \
		echo "[run-vllm] ERROR: A CUDA-capable NVIDIA GPU is required. There is no CPU fallback." >&2; \
		exit 1; \
	fi
	@echo "[run-vllm] Ensuring network '$(DEMOCLAW_NETWORK)' exists ..."
	@$(CONTAINER_RUNTIME) network inspect $(DEMOCLAW_NETWORK) >/dev/null 2>&1 \
		|| $(CONTAINER_RUNTIME) network create $(DEMOCLAW_NETWORK)
	@mkdir -p "$(HF_CACHE_DIR)"
	@echo "[run-vllm] Starting vLLM container '$(VLLM_CONTAINER_NAME)' ..."
	@echo "[run-vllm]   Image       : $(VLLM_IMAGE_TAG)"
	@echo "[run-vllm]   Model       : $(MODEL_NAME)"
	@echo "[run-vllm]   Quantize    : $(QUANTIZATION)  dtype=$(DTYPE)"
	@echo "[run-vllm]   GPU flags   : $(GPU_FLAGS)"
	@echo "[run-vllm]   Host port   : $(VLLM_HOST_PORT) -> container $(VLLM_PORT)"
	$(CONTAINER_RUNTIME) run -d \
		--name $(VLLM_CONTAINER_NAME) \
		--network $(DEMOCLAW_NETWORK) \
		--hostname vllm \
		--network-alias vllm \
		$(GPU_FLAGS) \
		--restart unless-stopped \
		--shm-size 1g \
		-p $(VLLM_HOST_PORT):$(VLLM_PORT) \
		-v "$(HF_CACHE_DIR):/root/.cache/huggingface:rw" \
		-e MODEL_NAME=$(MODEL_NAME) \
		-e VLLM_PORT=$(VLLM_PORT) \
		-e MAX_MODEL_LEN=$(MAX_MODEL_LEN) \
		-e GPU_MEMORY_UTILIZATION=$(GPU_MEMORY_UTILIZATION) \
		-e QUANTIZATION=$(QUANTIZATION) \
		-e DTYPE=$(DTYPE) \
		-e HF_TOKEN=$(HF_TOKEN) \
		-e HUGGING_FACE_HUB_TOKEN=$(HF_TOKEN) \
		--cap-drop ALL \
		--security-opt no-new-privileges \
		$(VLLM_IMAGE_TAG)
	@echo "[run-vllm] Container '$(VLLM_CONTAINER_NAME)' started."
	@echo "[run-vllm] API endpoint : http://localhost:$(VLLM_HOST_PORT)/v1"
	@echo "[run-vllm] Stream logs  : $(CONTAINER_RUNTIME) logs -f $(VLLM_CONTAINER_NAME)"

## run-openclaw: Run the OpenClaw container directly (network + ports + env vars, no health wait)
run-openclaw: _require-runtime
	@echo "[run-openclaw] Ensuring network '$(DEMOCLAW_NETWORK)' exists ..."
	@$(CONTAINER_RUNTIME) network inspect $(DEMOCLAW_NETWORK) >/dev/null 2>&1 \
		|| $(CONTAINER_RUNTIME) network create $(DEMOCLAW_NETWORK)
	@echo "[run-openclaw] Starting OpenClaw container '$(OPENCLAW_CONTAINER_NAME)' ..."
	@echo "[run-openclaw]   Image       : $(OPENCLAW_IMAGE_TAG)"
	@echo "[run-openclaw]   vLLM URL    : $(VLLM_BASE_URL)"
	@echo "[run-openclaw]   Model       : $(VLLM_MODEL_NAME)"
	@echo "[run-openclaw]   Host port   : $(OPENCLAW_HOST_PORT) -> container $(OPENCLAW_PORT)"
	$(CONTAINER_RUNTIME) run -d \
		--name $(OPENCLAW_CONTAINER_NAME) \
		--network $(DEMOCLAW_NETWORK) \
		--hostname openclaw \
		--network-alias openclaw \
		--restart unless-stopped \
		-p $(OPENCLAW_HOST_PORT):$(OPENCLAW_PORT) \
		-e VLLM_BASE_URL=$(VLLM_BASE_URL) \
		-e VLLM_API_KEY=$(VLLM_API_KEY) \
		-e VLLM_MODEL_NAME=$(VLLM_MODEL_NAME) \
		-e OPENCLAW_PORT=$(OPENCLAW_PORT) \
		-e OPENAI_API_BASE=$(VLLM_BASE_URL) \
		-e OPENAI_BASE_URL=$(VLLM_BASE_URL) \
		-e OPENAI_API_KEY=$(VLLM_API_KEY) \
		-e OPENAI_MODEL=$(VLLM_MODEL_NAME) \
		-e OPENCLAW_LLM_PROVIDER=openai-compatible \
		-e OPENCLAW_LLM_BASE_URL=$(VLLM_BASE_URL) \
		-e OPENCLAW_LLM_API_KEY=$(VLLM_API_KEY) \
		-e OPENCLAW_LLM_MODEL=$(VLLM_MODEL_NAME) \
		--cap-drop ALL \
		--security-opt no-new-privileges \
		--read-only \
		--tmpfs /tmp:rw,noexec,nosuid \
		--tmpfs /app/config:rw,noexec,nosuid,uid=1000,gid=1000 \
		$(OPENCLAW_IMAGE_TAG)
	@echo "[run-openclaw] Container '$(OPENCLAW_CONTAINER_NAME)' started."
	@echo "[run-openclaw] Dashboard   : http://localhost:$(OPENCLAW_HOST_PORT)"
	@echo "[run-openclaw] Stream logs : $(CONTAINER_RUNTIME) logs -f $(OPENCLAW_CONTAINER_NAME)"

## stop-vllm: Stop and remove the vLLM container
stop-vllm: _require-runtime
	@echo "[stop-vllm] Stopping and removing container '$(VLLM_CONTAINER_NAME)' ..."
	@$(CONTAINER_RUNTIME) rm -f $(VLLM_CONTAINER_NAME) 2>/dev/null \
		&& echo "[stop-vllm] Done." \
		|| echo "[stop-vllm] Container '$(VLLM_CONTAINER_NAME)' not found — already removed."

## stop-openclaw: Stop and remove the OpenClaw container
stop-openclaw: _require-runtime
	@echo "[stop-openclaw] Stopping and removing container '$(OPENCLAW_CONTAINER_NAME)' ..."
	@$(CONTAINER_RUNTIME) rm -f $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
		&& echo "[stop-openclaw] Done." \
		|| echo "[stop-openclaw] Container '$(OPENCLAW_CONTAINER_NAME)' not found — already removed."

## restart-vllm: Stop then restart the vLLM container (GPU validation + model pull + health wait)
restart-vllm: stop-vllm start-vllm

## restart-openclaw: Stop then restart the OpenClaw container (with health wait)
restart-openclaw: stop-openclaw start-openclaw

# =============================================================================
##@ Base Images
# Pre-pull upstream base images from their registries so that subsequent
# 'make build' runs reuse the local cache rather than re-downloading layers.
# Useful when preparing an air-gapped environment or caching images in CI.
#
# Images pulled:
#   vLLM base  : vllm/vllm-openai:<VLLM_BASE_VERSION>   (Docker Hub / ghcr.io)
#   OpenClaw base: ubuntu:24.04                          (Docker Hub)
#
# Override the version at call time:
#   make pull-vllm VLLM_BASE_VERSION=v0.8.4
# =============================================================================

## pull: Pull both vLLM and OpenClaw base images from their registries
pull: pull-vllm pull-openclaw

## pull-vllm: Pull the vLLM base image (vllm/vllm-openai:<VLLM_BASE_VERSION>)
pull-vllm:
	@echo "[pull] Pulling vLLM base image '$(VLLM_BASE_IMAGE)' using $(CONTAINER_RUNTIME) ..."
	@$(CONTAINER_RUNTIME) pull $(VLLM_BASE_IMAGE)
	@echo "[pull] vLLM base image '$(VLLM_BASE_IMAGE)' is up to date."

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
		--filter "name=$(VLLM_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" \
		--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null \
	|| $(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(VLLM_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" 2>/dev/null \
	|| echo "(no containers found)"
	@echo ""
	@bash "$(SCRIPTS_DIR)/healthcheck.sh"

## health: Alias for 'status' — run all service healthchecks
health: status

## health-check: Alias for 'status' — run all service healthchecks
health-check: status

## validate-api: Validate vLLM OpenAI-compatible API endpoints (/health, /v1/models, /v1/chat/completions)
validate-api:
	@bash "$(SCRIPTS_DIR)/validate-api.sh"

## validate-connection: Confirm vLLM provider connection is live from within/alongside the OpenClaw container
validate-connection:
	@bash "$(SCRIPTS_DIR)/validate_connection.sh" --exec

## validate-connection-host: Confirm vLLM provider connection via the host-published port (localhost)
validate-connection-host:
	@bash "$(SCRIPTS_DIR)/validate_connection.sh" --host

## logs: Tail the last 50 lines from one or both containers; use SERVICE=vllm|openclaw to filter
logs:
	@case "$(SERVICE)" in \
		vllm) \
			echo "=== vLLM logs (last 50 lines) ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(VLLM_CONTAINER_NAME) 2>/dev/null \
				|| echo "(no vLLM container)";; \
		openclaw) \
			echo "=== OpenClaw logs (last 50 lines) ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
				|| echo "(no OpenClaw container)";; \
		"") \
			echo "=== vLLM logs (last 50 lines) ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(VLLM_CONTAINER_NAME) 2>/dev/null \
				|| echo "(no vLLM container)"; \
			echo ""; \
			echo "=== OpenClaw logs (last 50 lines) ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
				|| echo "(no OpenClaw container)"; \
			echo ""; \
			echo "Tip: use 'make logs SERVICE=vllm' or 'make logs SERVICE=openclaw' to filter."; \
			echo "     use 'make follow' to stream both containers in real time.";; \
		*) \
			echo "[logs] Unknown SERVICE='$(SERVICE)'. Use SERVICE=vllm or SERVICE=openclaw." >&2; \
			exit 1;; \
	esac

## logs-vllm: Show last 50 lines of vLLM container logs
logs-vllm:
	@$(CONTAINER_RUNTIME) logs --tail 50 $(VLLM_CONTAINER_NAME)

## logs-openclaw: Show last 50 lines of OpenClaw container logs
logs-openclaw:
	@$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME)

## ps: Show DemoClaw container states
ps:
	@echo "DemoClaw containers:"
	@echo "--------------------"
	@$(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(VLLM_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" \
		--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null \
	|| $(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(VLLM_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" 2>/dev/null \
	|| echo "(no containers found)"

## follow: Follow live logs from both containers (Ctrl+C to stop)
follow:
	@echo "=== Following logs for $(VLLM_CONTAINER_NAME) and $(OPENCLAW_CONTAINER_NAME) ===" && \
	echo "    (Ctrl+C to stop)" && echo "" && \
	$(CONTAINER_RUNTIME) logs -f --tail 10 $(VLLM_CONTAINER_NAME) 2>/dev/null &\
	$(CONTAINER_RUNTIME) logs -f --tail 10 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null &\
	wait

## follow-vllm: Follow vLLM container logs in real time (Ctrl+C to stop)
follow-vllm:
	@$(CONTAINER_RUNTIME) logs -f $(VLLM_CONTAINER_NAME)

## follow-openclaw: Follow OpenClaw container logs in real time (Ctrl+C to stop)
follow-openclaw:
	@$(CONTAINER_RUNTIME) logs -f $(OPENCLAW_CONTAINER_NAME)

# =============================================================================
##@ Debugging
# =============================================================================

## shell: Exec into a named container; use SERVICE=vllm|openclaw or CONTAINER=<name>
shell: _require-runtime
	@_svc="$(or $(SERVICE),$(CONTAINER))"; \
	if [ -z "$$_svc" ]; then \
		echo "[shell] Usage: make shell SERVICE=vllm|openclaw" >&2; \
		echo "[shell]        make shell CONTAINER=$(VLLM_CONTAINER_NAME)" >&2; \
		echo "" >&2; \
		echo "[shell] Shortcuts:" >&2; \
		echo "[shell]   make shell-vllm     — exec into $(VLLM_CONTAINER_NAME)" >&2; \
		echo "[shell]   make shell-openclaw — exec into $(OPENCLAW_CONTAINER_NAME)" >&2; \
		exit 1; \
	fi; \
	case "$$_svc" in \
		vllm)     _cname="$(VLLM_CONTAINER_NAME)";; \
		openclaw) _cname="$(OPENCLAW_CONTAINER_NAME)";; \
		*)        _cname="$$_svc";; \
	esac; \
	echo "[shell] Attaching shell to '$$_cname' ..."; \
	$(CONTAINER_RUNTIME) exec -it "$$_cname" /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it "$$_cname" /bin/sh

## shell-vllm: Open an interactive shell inside the vLLM container
shell-vllm:
	@echo "Attaching shell to '$(VLLM_CONTAINER_NAME)' ..."
	@$(CONTAINER_RUNTIME) exec -it $(VLLM_CONTAINER_NAME) /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it $(VLLM_CONTAINER_NAME) /bin/sh

## shell-openclaw: Open an interactive shell inside the OpenClaw container
shell-openclaw:
	@echo "Attaching shell to '$(OPENCLAW_CONTAINER_NAME)' ..."
	@$(CONTAINER_RUNTIME) exec -it $(OPENCLAW_CONTAINER_NAME) /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it $(OPENCLAW_CONTAINER_NAME) /bin/sh

## inspect-vllm: Show detailed vLLM container information (JSON)
inspect-vllm:
	@$(CONTAINER_RUNTIME) inspect $(VLLM_CONTAINER_NAME) 2>/dev/null \
		|| echo "Container '$(VLLM_CONTAINER_NAME)' not found."

## inspect-openclaw: Show detailed OpenClaw container information (JSON)
inspect-openclaw:
	@$(CONTAINER_RUNTIME) inspect $(OPENCLAW_CONTAINER_NAME) 2>/dev/null \
		|| echo "Container '$(OPENCLAW_CONTAINER_NAME)' not found."

## top-vllm: Show vLLM container resource usage (CPU, memory)
top-vllm:
	@$(CONTAINER_RUNTIME) stats --no-stream $(VLLM_CONTAINER_NAME) 2>/dev/null \
		|| echo "Container '$(VLLM_CONTAINER_NAME)' is not running."

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
	@echo "  vLLM image      : $(VLLM_IMAGE_TAG)"
	@echo "    base version  : $(VLLM_BASE_VERSION)"
	@echo "    model         : $(MODEL_NAME)"
	@echo "    quantization  : $(QUANTIZATION)"
	@echo "    dtype         : $(DTYPE)"
	@echo "    max-model-len : $(MAX_MODEL_LEN)"
	@echo ""
	@echo "  OpenClaw image  : $(OPENCLAW_IMAGE_TAG)"
	@echo "    node major    : $(NODE_MAJOR)"
	@echo "    openclaw pkg  : $(OPENCLAW_NPM_VERSION)"
	@echo "    port          : $(OPENCLAW_PORT)"
	@echo "    vLLM URL      : $(VLLM_BASE_URL)"
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
	@printf "  make restart-vllm                     # Restart just the vLLM container\n"
	@printf "  make restart-openclaw                 # Restart just the OpenClaw container\n"
	@printf "  make clean                            # Remove containers, images, volumes & network\n"
	@printf "  make prune                            # Deep clean: also prune ALL dangling images/volumes/build cache\n"
	@printf "\n\033[1m  Logs & monitoring\033[0m\n"
	@printf "  make logs                             # Tail last 50 lines from both containers\n"
	@printf "  make logs SERVICE=vllm                # Tail last 50 lines of vLLM logs only\n"
	@printf "  make logs SERVICE=openclaw            # Tail last 50 lines of OpenClaw logs only\n"
	@printf "  make logs-vllm                        # Tail last 50 lines of vLLM logs\n"
	@printf "  make logs-openclaw                    # Tail last 50 lines of OpenClaw logs\n"
	@printf "  make follow                           # Stream live logs from both containers\n"
	@printf "  make follow-vllm                      # Stream vLLM logs in real time\n"
	@printf "  make follow-openclaw                  # Stream OpenClaw logs in real time\n"
	@printf "  make status                           # Show running containers + healthchecks\n"
	@printf "  make validate-api                     # Validate vLLM API endpoints\n"
	@printf "  make validate-connection              # Confirm vLLM provider connection via OpenClaw container\n"
	@printf "  make validate-connection-host         # Confirm vLLM provider connection via host port\n"
	@printf "  make ps                               # Show DemoClaw container states\n"
	@printf "\n\033[1m  Debug & diagnostics\033[0m\n"
	@printf "  make check-gpu                        # Full GPU/CUDA preflight validation\n"
	@printf "  make env-check                        # Verify GPU & runtime setup\n"
	@printf "  make shell SERVICE=vllm               # Exec into the vLLM container\n"
	@printf "  make shell SERVICE=openclaw           # Exec into the OpenClaw container\n"
	@printf "  make shell CONTAINER=<name>           # Exec into any container by full name\n"
	@printf "  make shell-vllm                       # Open shell inside vLLM container\n"
	@printf "  make shell-openclaw                   # Open shell inside OpenClaw container\n"
	@printf "  make inspect-vllm                     # Show vLLM container details (JSON)\n"
	@printf "  make top-vllm                         # Show vLLM resource usage\n"
	@printf "\n\033[1m  Base images\033[0m\n"
	@printf "  make pull                             # Pull both vLLM and OpenClaw base images\n"
	@printf "  make pull-vllm                        # Pull vLLM base image (vllm/vllm-openai:<ver>)\n"
	@printf "  make pull-openclaw                    # Pull OpenClaw base image (ubuntu:24.04)\n"
	@printf "  make pull VLLM_BASE_VERSION=v0.8.4    # Pull a specific vLLM base image version\n"
	@printf "\n\033[1m  Build options\033[0m\n"
	@printf "  make build                            # Build both images (auto-detect runtime)\n"
	@printf "  make build NO_CACHE=1                 # Force clean image rebuild\n"
	@printf "  make build-vllm VLLM_IMAGE_TAG=my/v   # Custom vLLM image tag\n"
	@printf "  make build-docker                     # Build both images with docker\n"
	@printf "  make build-podman                     # Build both images with podman\n"
	@printf "  make build-vllm-docker                # Build vLLM image with docker\n"
	@printf "  make build-vllm-podman                # Build vLLM image with podman\n"
	@printf "  make build-openclaw-docker            # Build OpenClaw image with docker\n"
	@printf "  make build-openclaw-podman            # Build OpenClaw image with podman\n"
	@printf "  make build-info                       # Show build config, versions, and labels\n"
	@printf "  make build VLLM_BASE_VERSION=v0.8.4   # Pin vLLM base image version\n"
	@printf "  make build NODE_MAJOR=22              # Build OpenClaw with Node.js 22\n"
	@printf "\n\033[1m  Runtime override (any target accepts CONTAINER_RUNTIME)\033[0m\n"
	@printf "  make start CONTAINER_RUNTIME=podman   # Force podman for any target\n"
	@printf "  make run-vllm-docker                  # Run vLLM container with docker\n"
	@printf "  make run-vllm-podman                  # Run vLLM container with podman\n"
	@printf "  make run-openclaw-docker              # Run OpenClaw container with docker\n"
	@printf "  make run-openclaw-podman              # Run OpenClaw container with podman\n"
	@printf "  make start-docker                     # Start full stack with docker\n"
	@printf "  make start-podman                     # Start full stack with podman\n"
	@printf "\n"
