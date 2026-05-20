# Pixal3D-T convenience targets. Thin wrappers over docker compose; no logic.
# Usage:
#   make help
#   make build [CUDA_ARCH=12.0]   # default 8.6 (Ampere); 12.0 for Blackwell
#   make fetch-models             # uses HF_TOKEN from .env
#   make up | down | logs | ps | health

CUDA_ARCH ?= 8.6
.DEFAULT_GOAL := help
.PHONY: help build fetch-models up down restart logs ps health

help: ## Show this help
	@awk 'BEGIN{FS=":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-14s %s\n",$$1,$$2}' $(MAKEFILE_LIST)

build: ## Build the image  (override: make build CUDA_ARCH=12.0)
	CUDA_ARCH=$(CUDA_ARCH) docker compose build comfyui-trellis2

fetch-models: ## One-time weight provisioning (needs HF_TOKEN in .env)
	docker compose --profile setup run --rm model-fetch

up: ## Start in API mode (:8487 API public, :8488 ComfyUI UI loopback)
	docker compose up -d

down: ## Stop and remove the container
	docker compose down

restart: down up ## Recreate the container on the current image

logs: ## Tail container logs
	docker compose logs -f --no-color comfyui-trellis2

ps: ## Show service status
	docker compose ps

health: ## Hit /healthz on the API
	@curl -fsS http://localhost:8487/healthz | python3 -m json.tool
