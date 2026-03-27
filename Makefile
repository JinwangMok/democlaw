# =============================================================================
# DemoClaw — Makefile
#
# Container lifecycle targets for the vLLM + OpenClaw stack.
# All targets invoke the shell scripts in scripts/ which auto-detect
# the container runtime (docker or podman).
#
# Usage:
#   make build          # Build both container images
#   make start          # Start the full stack (vLLM + OpenClaw)
#   make stop           # Stop and remove all containers
#   make restart        # Stop then start the full stack
#   make clean          # Stop containers, remove images and network
#   make status         # Run healthcheck on all services
#   make logs           # Tail logs from both containers
#
# Individual service targets:
#   make build-vllm     # Build the vLLM image only
#   make build-openclaw # Build the OpenClaw image only
#   make start-vllm     # Start the vLLM container only
#   make start-openclaw # Start the OpenClaw container only
#   make logs-vllm      # Tail vLLM container logs
#   make logs-openclaw  # Tail OpenClaw container logs
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
# Container runtime detection (mirrors scripts/lib/runtime.sh logic)
# Prefer CONTAINER_RUNTIME env var, then docker, then podman.
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

# Export so shell scripts inherit these values
export CONTAINER_RUNTIME
export VLLM_CONTAINER_NAME
export OPENCLAW_CONTAINER_NAME
export VLLM_IMAGE_TAG
export OPENCLAW_IMAGE_TAG
export DEMOCLAW_NETWORK

# =============================================================================
# Composite targets
# =============================================================================

.PHONY: build start stop restart clean status logs help \
       health-check ps follow follow-vllm follow-openclaw \
       shell-vllm shell-openclaw inspect-vllm inspect-openclaw \
       top-vllm top-openclaw env-check

## build: Build both vLLM and OpenClaw container images
build: build-vllm build-openclaw

## start: Start the full DemoClaw stack (vLLM + OpenClaw)
start:
	@bash "$(SCRIPTS_DIR)/start.sh"

## stop: Stop and remove all DemoClaw containers
stop:
	@bash "$(SCRIPTS_DIR)/stop.sh"

## restart: Stop then start the full stack
restart: stop start

## clean: Stop containers, remove images, and remove the network
clean:
	@REMOVE_NETWORK=true bash "$(SCRIPTS_DIR)/stop.sh"
	@echo "[clean] Removing container images ..."
	@$(CONTAINER_RUNTIME) rmi -f $(VLLM_IMAGE_TAG) 2>/dev/null || true
	@$(CONTAINER_RUNTIME) rmi -f $(OPENCLAW_IMAGE_TAG) 2>/dev/null || true
	@echo "[clean] Done."

## status: Run healthcheck on all services
status:
	@bash "$(SCRIPTS_DIR)/healthcheck.sh"

## logs: Tail logs from both containers (Ctrl+C to stop)
logs:
	@echo "=== vLLM logs ===" && \
	$(CONTAINER_RUNTIME) logs --tail 20 $(VLLM_CONTAINER_NAME) 2>/dev/null || echo "(no vLLM container)"; \
	echo ""; \
	echo "=== OpenClaw logs ===" && \
	$(CONTAINER_RUNTIME) logs --tail 20 $(OPENCLAW_CONTAINER_NAME) 2>/dev/null || echo "(no OpenClaw container)"

# =============================================================================
# Individual service targets
# =============================================================================

.PHONY: build-vllm build-openclaw start-vllm start-openclaw logs-vllm logs-openclaw

## build-vllm: Build the vLLM container image
build-vllm:
	@echo "[build] Building vLLM image '$(VLLM_IMAGE_TAG)' ..."
	@$(CONTAINER_RUNTIME) build -t $(VLLM_IMAGE_TAG) "$(PROJECT_ROOT)vllm"

## build-openclaw: Build the OpenClaw container image
build-openclaw:
	@echo "[build] Building OpenClaw image '$(OPENCLAW_IMAGE_TAG)' ..."
	@$(CONTAINER_RUNTIME) build -t $(OPENCLAW_IMAGE_TAG) "$(PROJECT_ROOT)openclaw"

## start-vllm: Start the vLLM container only
start-vllm:
	@bash "$(SCRIPTS_DIR)/start-vllm.sh"

## start-openclaw: Start the OpenClaw container only
start-openclaw:
	@bash "$(SCRIPTS_DIR)/start-openclaw.sh"

## logs-vllm: Tail last 50 lines of vLLM container logs
logs-vllm:
	@$(CONTAINER_RUNTIME) logs --tail 50 $(VLLM_CONTAINER_NAME)

## logs-openclaw: Tail last 50 lines of OpenClaw container logs
logs-openclaw:
	@$(CONTAINER_RUNTIME) logs --tail 50 $(OPENCLAW_CONTAINER_NAME)

# =============================================================================
# Development & Debugging targets
# =============================================================================

.PHONY: health-check ps follow follow-vllm follow-openclaw \
        shell-vllm shell-openclaw inspect-vllm inspect-openclaw \
        top-vllm top-openclaw env-check

## health-check: Alias for 'status' — run all service healthchecks
health-check: status

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

## inspect-vllm: Show detailed vLLM container information
inspect-vllm:
	@$(CONTAINER_RUNTIME) inspect $(VLLM_CONTAINER_NAME) 2>/dev/null \
		|| echo "Container '$(VLLM_CONTAINER_NAME)' not found."

## inspect-openclaw: Show detailed OpenClaw container information
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
# Help
# =============================================================================

## help: Show this help message
help:
	@echo ""
	@echo "DemoClaw — Container Lifecycle Targets"
	@echo "======================================="
	@echo ""
	@echo "Runtime: $(or $(CONTAINER_RUNTIME),(not found — install docker or podman))"
	@echo ""
	@echo "\033[1mLifecycle:\033[0m"
	@echo "  \033[36mbuild\033[0m              Build both container images"
	@echo "  \033[36mstart\033[0m              Start the full DemoClaw stack (vLLM + OpenClaw)"
	@echo "  \033[36mstop\033[0m               Stop and remove all DemoClaw containers"
	@echo "  \033[36mrestart\033[0m            Stop then start the full stack"
	@echo "  \033[36mclean\033[0m              Stop containers, remove images, and remove the network"
	@echo ""
	@echo "\033[1mPer-service:\033[0m"
	@echo "  \033[36mbuild-vllm\033[0m         Build the vLLM container image"
	@echo "  \033[36mbuild-openclaw\033[0m     Build the OpenClaw container image"
	@echo "  \033[36mstart-vllm\033[0m         Start the vLLM container only"
	@echo "  \033[36mstart-openclaw\033[0m     Start the OpenClaw container only"
	@echo ""
	@echo "\033[1mMonitoring & Logs:\033[0m"
	@echo "  \033[36mstatus\033[0m             Run healthchecks on all services"
	@echo "  \033[36mhealth-check\033[0m       Alias for 'status'"
	@echo "  \033[36mps\033[0m                 Show DemoClaw container states"
	@echo "  \033[36mlogs\033[0m               Show last 20 lines from both containers"
	@echo "  \033[36mlogs-vllm\033[0m          Show last 50 lines of vLLM logs"
	@echo "  \033[36mlogs-openclaw\033[0m      Show last 50 lines of OpenClaw logs"
	@echo "  \033[36mfollow\033[0m             Follow live logs from both containers"
	@echo "  \033[36mfollow-vllm\033[0m        Follow vLLM logs in real time"
	@echo "  \033[36mfollow-openclaw\033[0m    Follow OpenClaw logs in real time"
	@echo ""
	@echo "\033[1mDebugging:\033[0m"
	@echo "  \033[36mshell-vllm\033[0m         Open interactive shell in vLLM container"
	@echo "  \033[36mshell-openclaw\033[0m     Open interactive shell in OpenClaw container"
	@echo "  \033[36minspect-vllm\033[0m       Show detailed vLLM container info (JSON)"
	@echo "  \033[36minspect-openclaw\033[0m   Show detailed OpenClaw container info (JSON)"
	@echo "  \033[36mtop-vllm\033[0m           Show vLLM container resource usage"
	@echo "  \033[36mtop-openclaw\033[0m       Show OpenClaw container resource usage"
	@echo "  \033[36menv-check\033[0m          Validate environment prerequisites"
	@echo ""
	@echo "\033[1mExamples:\033[0m"
	@echo "  make start                          # Start full stack"
	@echo "  make start CONTAINER_RUNTIME=podman  # Force podman"
	@echo "  make logs-vllm                      # Quick look at vLLM logs"
	@echo "  make follow-vllm                    # Stream vLLM logs in real time"
	@echo "  make shell-openclaw                 # Debug inside OpenClaw container"
	@echo "  make env-check                      # Verify GPU & runtime setup"
	@echo "  make restart                        # Restart everything"
	@echo "  make clean                          # Remove everything"
	@echo ""
