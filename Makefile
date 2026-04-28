# =============================================================================
# DemoClaw — Makefile
#
# Container lifecycle targets for the llama.cpp + OpenClaw stack.
# All targets invoke the shell scripts in scripts/ which auto-detect
# the container runtime (docker or podman).
#
# Run  make help  to list all targets.
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
# Container runtime detection
# ---------------------------------------------------------------------------
CONTAINER_RUNTIME ?= $(shell \
	if command -v docker >/dev/null 2>&1; then echo docker; \
	elif command -v podman >/dev/null 2>&1; then echo podman; \
	else echo ""; \
	fi)

# Container and image names
LLAMACPP_CONTAINER_NAME ?= democlaw-llamacpp
OPENCLAW_CONTAINER_NAME ?= democlaw-openclaw
LLAMACPP_IMAGE_TAG      ?= democlaw/llamacpp:latest
OPENCLAW_IMAGE_TAG      ?= democlaw/openclaw:latest
DEMOCLAW_NETWORK        ?= democlaw-net

# ---------------------------------------------------------------------------
# Build options
# ---------------------------------------------------------------------------
NO_CACHE              ?=
DOCKER_BUILDKIT       ?= 1
_BUILD_NOCACHE_FLAG    = $(if $(NO_CACHE),--no-cache,)

export DOCKER_BUILDKIT

# ---------------------------------------------------------------------------
# Version and build metadata
# ---------------------------------------------------------------------------
VERSION    ?= $(shell git -C "$(PROJECT_ROOT)" describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_DATE ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT ?= $(shell git -C "$(PROJECT_ROOT)" rev-parse --short HEAD 2>/dev/null || echo "unknown")
REPO_URL   ?= https://github.com/JinwangMok/democlaw

# ---------------------------------------------------------------------------
# Component versions
# ---------------------------------------------------------------------------
NODE_MAJOR           ?= 22
OPENCLAW_NPM_VERSION ?= 2026.4.26

# ---------------------------------------------------------------------------
# Model and port configuration
# ---------------------------------------------------------------------------
MODEL_NAME             ?= gemma-4-E4B-it
LLAMACPP_PORT          ?= 8000
OPENCLAW_PORT          ?= 18789
LLAMACPP_BASE_URL      ?= http://llamacpp:8000/v1
LLAMACPP_API_KEY       ?= EMPTY
LLAMACPP_MODEL_NAME    ?= gemma-4-E4B-it
MODEL_DIR              ?= $(HOME)/.cache/democlaw/models

# ---------------------------------------------------------------------------
# GPU passthrough flags
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

export CONTAINER_RUNTIME

# ---------------------------------------------------------------------------
# Runtime guard
# ---------------------------------------------------------------------------
define _runtime_missing_msg
[error] No container runtime found in PATH.
[error] Install docker  : https://docs.docker.com/engine/install/
[error] Install podman  : https://podman.io/getting-started/installation
endef
export _runtime_missing_msg

.PHONY: build start stop restart clean prune \
       status logs help \
       ps follow follow-llamacpp follow-openclaw \
       shell shell-llamacpp shell-openclaw \
       build-llamacpp build-openclaw \
       logs-llamacpp logs-openclaw \
       build-info env-check benchmark validate validate-running validate-chat \
       test-e2e test-e2e-json _require-runtime

_require-runtime:
	@if [ -z "$(CONTAINER_RUNTIME)" ]; then \
		echo "$$_runtime_missing_msg" >&2; \
		exit 1; \
	fi

# =============================================================================
##@ Lifecycle
# =============================================================================

## build: Build all container images (llama.cpp + OpenClaw)
build: _require-runtime build-llamacpp build-openclaw

## start: Start the full DemoClaw stack (with health checks)
start: _require-runtime
	@bash "$(SCRIPTS_DIR)/start.sh"

## stop: Stop and remove all DemoClaw containers
stop: _require-runtime
	@bash "$(SCRIPTS_DIR)/stop.sh"

## restart: Stop then start the full stack
restart: stop start

## clean: Stop containers, remove images, dangling volumes, and the shared network
clean: _require-runtime
	@REMOVE_NETWORK=true bash "$(SCRIPTS_DIR)/stop.sh"
	@echo "[clean] Removing container images ..."
	@$(CONTAINER_RUNTIME) rmi -f $(LLAMACPP_IMAGE_TAG) 2>/dev/null || true
	@$(CONTAINER_RUNTIME) rmi -f $(OPENCLAW_IMAGE_TAG) 2>/dev/null || true
	@echo "[clean] Pruning dangling volumes ..."
	@$(CONTAINER_RUNTIME) volume prune -f 2>/dev/null || true
	@echo "[clean] Done. Model cache at $(MODEL_DIR) is preserved."

## prune: Deep clean — remove everything including dangling images/volumes/build cache
prune: _require-runtime
	@REMOVE_NETWORK=true bash "$(SCRIPTS_DIR)/stop.sh"
	@echo "[prune] Removing DemoClaw container images ..."
	@$(CONTAINER_RUNTIME) rmi -f $(LLAMACPP_IMAGE_TAG) 2>/dev/null || true
	@$(CONTAINER_RUNTIME) rmi -f $(OPENCLAW_IMAGE_TAG) 2>/dev/null || true
	@$(CONTAINER_RUNTIME) image prune -f 2>/dev/null || true
	@$(CONTAINER_RUNTIME) volume prune -f 2>/dev/null || true
	@$(CONTAINER_RUNTIME) builder prune -f 2>/dev/null || true
	@echo "[prune] Done. Model cache at $(MODEL_DIR) is preserved."

# =============================================================================
##@ Build
# =============================================================================

## build-llamacpp: Build the llama.cpp container image
build-llamacpp: _require-runtime
	@echo "[build] Building llama.cpp image '$(LLAMACPP_IMAGE_TAG)' ..."
	@$(CONTAINER_RUNTIME) build $(_BUILD_NOCACHE_FLAG) \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		-t $(LLAMACPP_IMAGE_TAG) \
		"$(PROJECT_ROOT)llamacpp"

## build-openclaw: Build the OpenClaw container image
build-openclaw: _require-runtime
	@echo "[build] Building OpenClaw image '$(OPENCLAW_IMAGE_TAG)' ..."
	@$(CONTAINER_RUNTIME) build $(_BUILD_NOCACHE_FLAG) \
		--build-arg NODE_MAJOR=$(NODE_MAJOR) \
		--build-arg OPENCLAW_NPM_VERSION=$(OPENCLAW_NPM_VERSION) \
		--build-arg LLAMACPP_BASE_URL=$(LLAMACPP_BASE_URL) \
		--build-arg LLAMACPP_MODEL_NAME=$(LLAMACPP_MODEL_NAME) \
		--build-arg OPENCLAW_PORT=$(OPENCLAW_PORT) \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		-t $(OPENCLAW_IMAGE_TAG) \
		"$(PROJECT_ROOT)openclaw"

## build-info: Show build configuration
build-info:
	@echo ""
	@echo "DemoClaw — Build Configuration"
	@echo "================================"
	@echo "  Runtime     : $(or $(CONTAINER_RUNTIME),(not found))"
	@echo "  Version     : $(VERSION)"
	@echo "  Git commit  : $(GIT_COMMIT)"
	@echo ""
	@echo "  llama.cpp   : $(LLAMACPP_IMAGE_TAG)"
	@echo "  OpenClaw    : $(OPENCLAW_IMAGE_TAG)"
	@echo "  Model       : $(MODEL_NAME)"
	@echo ""

# =============================================================================
##@ Monitoring
# =============================================================================

## status: Show running DemoClaw containers
status:
	@echo "DemoClaw — Container Status"
	@echo "==========================="
	@$(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(LLAMACPP_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" \
		--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null \
	|| echo "(no containers found)"

## logs: Tail last 50 lines from containers; use SERVICE=llamacpp|openclaw
logs:
	@case "$(SERVICE)" in \
		llamacpp) $(CONTAINER_RUNTIME) logs --tail 50 $(LLAMACPP_CONTAINER_NAME) 2>/dev/null || echo "(not found)";; \
		openclaw) $(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null || echo "(not found)";; \
		"") \
			echo "=== llama.cpp ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(LLAMACPP_CONTAINER_NAME) 2>/dev/null || echo "(not found)"; \
			echo ""; \
			echo "=== OpenClaw ==="; \
			$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null || echo "(not found)";; \
		*) echo "[logs] Unknown SERVICE='$(SERVICE)'. Use: llamacpp, openclaw" >&2; exit 1;; \
	esac

## logs-llamacpp: Show last 50 lines of llama.cpp logs
logs-llamacpp:
	@$(CONTAINER_RUNTIME) logs --tail 50 $(LLAMACPP_CONTAINER_NAME)

## logs-openclaw: Show last 50 lines of OpenClaw logs
logs-openclaw:
	@$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME)

## ps: Show DemoClaw container states
ps:
	@$(CONTAINER_RUNTIME) ps -a \
		--filter "name=$(LLAMACPP_CONTAINER_NAME)" \
		--filter "name=$(OPENCLAW_CONTAINER_NAME)" \
		--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null \
	|| echo "(no containers found)"

## follow: Follow live logs from all containers (Ctrl+C to stop)
follow:
	@$(CONTAINER_RUNTIME) logs -f --tail 10 $(LLAMACPP_CONTAINER_NAME) 2>/dev/null &\
	$(CONTAINER_RUNTIME) logs -f --tail 10 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null &\
	wait

## follow-llamacpp: Follow llama.cpp logs in real time
follow-llamacpp:
	@$(CONTAINER_RUNTIME) logs -f $(LLAMACPP_CONTAINER_NAME)

## follow-openclaw: Follow OpenClaw logs in real time
follow-openclaw:
	@$(CONTAINER_RUNTIME) logs -f $(OPENCLAW_CONTAINER_NAME)

# =============================================================================
##@ Benchmarking
# =============================================================================

## benchmark: Run LLM throughput benchmark (tokens/sec) against the running stack
benchmark: _require-runtime
	@bash "$(SCRIPTS_DIR)/benchmark-tps.sh"

## validate: Run full E2E validation pipeline (preflight, health, memory, throughput, API)
validate: _require-runtime
	@bash "$(SCRIPTS_DIR)/validate-e2e.sh"

## validate-running: Validate an already-running stack (skip container startup)
validate-running: _require-runtime
	@SKIP_STARTUP=1 bash "$(SCRIPTS_DIR)/validate-e2e.sh"

## validate-chat: Validate chat completion format compatibility with OpenClaw
validate-chat: _require-runtime
	@bash "$(SCRIPTS_DIR)/validate-chat-completion.sh"

## test-e2e: Run Gemma 4 E2E dashboard integration tests (both variants)
test-e2e:
	@bash "$(SCRIPTS_DIR)/test-e2e-gemma4.sh"

## test-e2e-json: Run Gemma 4 E2E tests with JSON output (for CI)
test-e2e-json:
	@TEST_OUTPUT_FORMAT=json bash "$(SCRIPTS_DIR)/test-e2e-gemma4.sh"

# =============================================================================
##@ Debugging
# =============================================================================

## shell: Exec into a container; use SERVICE=llamacpp|openclaw
shell: _require-runtime
	@_svc="$(or $(SERVICE),$(CONTAINER))"; \
	if [ -z "$$_svc" ]; then \
		echo "Usage: make shell SERVICE=llamacpp|openclaw" >&2; \
		exit 1; \
	fi; \
	case "$$_svc" in \
		llamacpp)   _cname="$(LLAMACPP_CONTAINER_NAME)";; \
		openclaw)   _cname="$(OPENCLAW_CONTAINER_NAME)";; \
		*)          _cname="$$_svc";; \
	esac; \
	$(CONTAINER_RUNTIME) exec -it "$$_cname" /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it "$$_cname" /bin/sh

## shell-llamacpp: Open shell inside llama.cpp container
shell-llamacpp:
	@$(CONTAINER_RUNTIME) exec -it $(LLAMACPP_CONTAINER_NAME) /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it $(LLAMACPP_CONTAINER_NAME) /bin/sh

## shell-openclaw: Open shell inside OpenClaw container
shell-openclaw:
	@$(CONTAINER_RUNTIME) exec -it $(OPENCLAW_CONTAINER_NAME) /bin/bash \
		|| $(CONTAINER_RUNTIME) exec -it $(OPENCLAW_CONTAINER_NAME) /bin/sh

## env-check: Validate environment prerequisites
env-check:
	@echo "Environment Check"
	@echo "================="
	@printf "  Container runtime: " && \
		(command -v $(CONTAINER_RUNTIME) >/dev/null 2>&1 \
			&& echo "$(CONTAINER_RUNTIME) OK" \
			|| echo "NOT FOUND")
	@printf "  nvidia-smi:        " && \
		(command -v nvidia-smi >/dev/null 2>&1 \
			&& echo "found" \
			|| echo "NOT FOUND")
	@printf "  NVIDIA GPU:        " && \
		(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
			| head -1 \
			|| echo "NOT DETECTED")
	@echo ""

# =============================================================================
##@ Help
# =============================================================================

## help: Show this help message
help:
	@printf "\n\033[1mDemoClaw — Container Lifecycle\033[0m\n\n"
	@awk ' \
		/^##@ / { gsub(/^##@ /, ""); printf "\n\033[1m%s\033[0m\n", $$0; next } \
		/^## / { \
			line = substr($$0, 4); colon = index(line, ":"); \
			if (colon > 0) printf "  \033[36m%-22s\033[0m %s\n", substr(line, 1, colon-1), substr(line, colon+2); \
			next \
		} \
	' $(MAKEFILE_LIST)
	@printf "\n\033[1mExamples:\033[0m\n"
	@printf "  make start                  Start full stack\n"
	@printf "  make stop                   Stop all containers\n"
	@printf "  make restart                Restart full stack\n"
	@printf "  make logs SERVICE=llamacpp  Tail llama.cpp logs\n"
	@printf "  make shell SERVICE=openclaw Exec into OpenClaw\n"
	@printf "  make build NO_CACHE=1       Force clean rebuild\n"
	@printf "  make start CONTAINER_RUNTIME=podman  Force podman\n"
	@printf "\n"
