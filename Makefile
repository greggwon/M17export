# =============================================================================
# M17 reflector container - top-level wrapper
# `make help` for the full menu.
# =============================================================================

SHELL := /bin/bash

# Load .env if present, so IMAGE_* and BUILD_PLATFORMS reach the recipes.
ifneq (,$(wildcard .env))
include .env
export
endif

IMAGE_MREFD     ?= m17export/mrefd:latest
IMAGE_DASHBOARD ?= m17export/mrefd-dashboard:latest
BUILD_PLATFORMS ?= linux/arm64,linux/arm/v7,linux/amd64
BUILDER          = m17-builder

COMPOSE = docker compose

.PHONY: help init submodules build build-local build-mrefd build-dashboard \
        up up-dashboard down restart logs logs-mrefd logs-dashboard \
        shell shell-dashboard status ps clean prune buildx-setup verify-env

help:                          ## Show this help
	@awk 'BEGIN {FS=":.*##"; printf "\nUsage: make \033[1m<target>\033[0m\n\nTargets:\n"} \
	     /^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo

# ---- one-time bootstrap -----------------------------------------------------

init: submodules               ## Interactive wizard: write .env + populate ./config
	@bash scripts/init.sh

submodules:                    ## Ensure mrefd/ submodule is checked out
	@if [ ! -f mrefd/Makefile ]; then \
	    echo "==> initializing mrefd submodule"; \
	    git submodule update --init --recursive; \
	 fi

verify-env:
	@if [ ! -f .env ]; then \
	    echo "ERROR: .env not found. Run 'make init' first."; exit 1; \
	 fi

# ---- builds -----------------------------------------------------------------

buildx-setup:                  ## One-time: create the multi-arch buildx builder
	@if ! docker buildx inspect $(BUILDER) >/dev/null 2>&1; then \
	    echo "==> creating buildx builder '$(BUILDER)'"; \
	    docker buildx create --name $(BUILDER) --driver docker-container --use; \
	    docker buildx inspect --bootstrap; \
	 else \
	    docker buildx use $(BUILDER); \
	 fi

build: buildx-setup submodules ## Multi-arch build for BUILD_PLATFORMS (loads local only for single arch)
	@echo "==> building mrefd for $(BUILD_PLATFORMS)"
	docker buildx build \
	    --platform $(BUILD_PLATFORMS) \
	    --file docker/mrefd/Dockerfile \
	    --build-arg MREFD_BUILD_DEBUG=$(MREFD_BUILD_DEBUG) \
	    --build-arg MREFD_BUILD_DHT=$(MREFD_BUILD_DHT) \
	    --tag $(IMAGE_MREFD) \
	    .
	@echo "==> building dashboard for $(BUILD_PLATFORMS)"
	docker buildx build \
	    --platform $(BUILD_PLATFORMS) \
	    --file docker/dashboard/Dockerfile \
	    --tag $(IMAGE_DASHBOARD) \
	    .
	@echo "NOTE: multi-arch buildx builds stay in the buildx cache. Add"
	@echo "      '--push' (with a registry-qualified IMAGE_*) or run"
	@echo "      'make build-local' if you need the image loaded into your"
	@echo "      local docker for immediate 'make up'."

build-local: submodules build-mrefd build-dashboard   ## Native arch, loaded into local docker
	@echo "==> local images ready"

build-mrefd:
	docker build \
	    --file docker/mrefd/Dockerfile \
	    --build-arg MREFD_BUILD_DEBUG=$(MREFD_BUILD_DEBUG) \
	    --build-arg MREFD_BUILD_DHT=$(MREFD_BUILD_DHT) \
	    --tag $(IMAGE_MREFD) \
	    .

build-dashboard:
	docker build \
	    --file docker/dashboard/Dockerfile \
	    --tag $(IMAGE_DASHBOARD) \
	    .

# ---- lifecycle --------------------------------------------------------------

up: verify-env                 ## Start the reflector (no dashboard)
	$(COMPOSE) up -d mrefd

up-dashboard: verify-env       ## Start the reflector AND the dashboard
	$(COMPOSE) --profile dashboard up -d

down:                          ## Stop and remove containers (volumes preserved)
	$(COMPOSE) --profile dashboard down

restart:                       ## Restart mrefd (picks up .env changes)
	$(COMPOSE) --profile dashboard restart

logs:                          ## Follow logs for all services
	$(COMPOSE) --profile dashboard logs -f --tail=200

logs-mrefd:
	$(COMPOSE) logs -f --tail=200 mrefd

logs-dashboard:
	$(COMPOSE) logs -f --tail=200 dashboard

shell:                         ## Shell inside the mrefd container
	$(COMPOSE) exec mrefd bash || $(COMPOSE) run --rm --entrypoint bash mrefd

shell-dashboard:
	$(COMPOSE) exec dashboard bash

status ps:                     ## Show container status
	$(COMPOSE) --profile dashboard ps

# ---- cleanup ----------------------------------------------------------------

clean:                         ## Remove containers AND named volumes (DHT state, logs)
	$(COMPOSE) --profile dashboard down -v

prune: clean                   ## clean + remove local images
	-docker image rm $(IMAGE_MREFD) $(IMAGE_DASHBOARD)

buildall:
	make build-local && make up-dashboard

first:
	[ "$$(uname -s)" = Darwin ] && brew install libnlohmann-json3
	[ "$$(uname -s)" = Darwin ] && brew trust --formula nlohmann/json/nlohmann_json
	git submodule update --init --recursive
	make init && make build-local && make up-dashboard
