SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

export PATH := $(CURDIR)/.tools/bin:$(PATH)
LAB_HOST ?= 192.168.8.207
export LAB_HOST

define todo
	@echo "not implemented yet: $(1)" >&2; exit 1
endef

.PHONY: help
help: ## Show targets
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: tools
tools: ## Install pinned dev tools into ./.tools
	scripts/bootstrap-tools.sh

.PHONY: hooks
hooks: tools ## Install git pre-commit hooks (with ./.tools/bin on their PATH)
	pre-commit install
	sed -i '1a export PATH="$$(git rev-parse --show-toplevel)/.tools/bin:$$PATH"' .git/hooks/pre-commit

.PHONY: lint
lint: tools ## Run all pre-commit checks on every file
	pre-commit run --all-files

.PHONY: temps
temps: ## Show lab host CPU temperatures and fan speed
	scripts/host-temps.sh

.PHONY: plan
plan: ## Terraform plan for the whole lab
	$(call todo,Phase 1 - terraform/host)

.PHONY: up
up: ## Build the lab (hypervisor networks -> VMs -> cluster -> Argo CD)
	$(call todo,Phase 1/2)

.PHONY: down destroy
down destroy: ## Tear the lab down completely
	$(call todo,Phase 1/2)

.PHONY: test
test: ## Run infra/app tests
	$(call todo,Phase 4/6)
