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

TF_HOST := terraform -chdir=terraform/host
# AUTO_APPROVE=1 make up|destroy skips the interactive confirmation
TF_APPROVE := $(if $(AUTO_APPROVE),-auto-approve,)
LAB_CIDR := 10.10.0.0/16
WAN_IP_FILE := .cache/host/opnsense-wan.ip

.PHONY: images
images: ## Download + verify VM base images into .cache/images
	scripts/fetch-images.sh

.PHONY: init
init:
	$(TF_HOST) init -input=false

.PHONY: plan
plan: images init ## Terraform plan for the whole lab
	$(TF_HOST) plan -input=false

.PHONY: up
up: images init ## Build the lab: VPC networks, OPNsense, test VM (Phase 2+ adds the cluster)
	$(TF_HOST) apply -input=false $(TF_APPROVE)
	@echo "OPNsense WAN: $$(cat $(WAN_IP_FILE))   next: make route && make verify"

.PHONY: down destroy
down destroy: init ## Tear the lab down completely
	$(TF_HOST) destroy -input=false $(TF_APPROVE)

.PHONY: route
route: ## Route the lab CIDR via the OPNsense WAN on this workstation (sudo)
	@test -s $(WAN_IP_FILE) || { echo "no WAN IP yet, run make up" >&2; exit 1; }
	sudo ip route replace $(LAB_CIDR) via $$(cat $(WAN_IP_FILE))
	@ip route show $(LAB_CIDR)

.PHONY: unroute
unroute: ## Remove the lab route from this workstation (sudo)
	-sudo ip route del $(LAB_CIDR)

.PHONY: verify
verify: ## Check the Phase 1 acceptance criteria against the running lab
	scripts/verify-host.sh

.PHONY: test
test: ## Run infra/app tests
	$(call todo,Phase 4/6)
