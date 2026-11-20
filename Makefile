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
TF_TALOS := terraform -chdir=terraform/talos
# AUTO_APPROVE=1 make up|destroy skips the interactive confirmation
TF_APPROVE := $(if $(AUTO_APPROVE),-auto-approve,)
LAB_CIDR := 10.10.0.0/16
WAN_IP_FILE := .cache/host/opnsense-wan.ip
export KUBECONFIG := $(CURDIR)/.cache/cluster/kubeconfig
export TALOSCONFIG := $(CURDIR)/.cache/cluster/talosconfig

.PHONY: images
images: ## Download + verify VM base images into .cache/images
	scripts/fetch-images.sh

.PHONY: init
init:
	$(TF_HOST) init -input=false
	$(TF_TALOS) init -input=false

.PHONY: plan
plan: images init ## Terraform plan for the whole lab
	$(TF_HOST) plan -input=false
	$(TF_TALOS) plan -input=false

.PHONY: up
up: host cluster ## Build everything: VPC + OPNsense + Talos VMs, then the cluster (Cilium, Argo CD)

.PHONY: host
host: images init ## VPC networks, OPNsense, Talos VMs (terraform/host)
	$(TF_HOST) apply -input=false $(TF_APPROVE)
	@echo "OPNsense WAN: $$(cat $(WAN_IP_FILE))   (make route once per workstation boot)"

.PHONY: cluster
cluster: init ## Talos config + bootstrap (terraform/talos), then Cilium + Argo CD (scripts/bootstrap-cluster.sh)
	$(TF_TALOS) apply -input=false $(TF_APPROVE)
	scripts/bootstrap-cluster.sh

.PHONY: down destroy
down destroy: init ## Tear the lab down completely (cluster state first, then the VMs)
	$(TF_TALOS) destroy -input=false $(TF_APPROVE)
	$(TF_HOST) destroy -input=false $(TF_APPROVE)
	rm -f .cache/cluster/kubeconfig .cache/cluster/talosconfig

.PHONY: route
route: ## Route the lab CIDR via the OPNsense WAN on this workstation (sudo)
	@test -s $(WAN_IP_FILE) || { echo "no WAN IP yet, run make up" >&2; exit 1; }
	sudo ip route replace $(LAB_CIDR) via $$(cat $(WAN_IP_FILE))
	@ip route show $(LAB_CIDR)

.PHONY: unroute
unroute: ## Remove the lab route from this workstation (sudo)
	-sudo ip route del $(LAB_CIDR)

.PHONY: pki secrets trust-root
pki: tools ## ONE-TIME: lab root/intermediate CA + age key (refuses to overwrite; back up .cache/ca + .cache/age)
	scripts/pki-init.sh

secrets: ## Apply the SOPS-encrypted bootstrap secrets (the OpenBao seed) to the cluster
	scripts/apply-bootstrap-secrets.sh

.PHONY: openbao-seed bao-password
openbao-seed: ## Rebuild the SOPS OpenBao seed (keeps unseal key + admin password); commit + push after
	scripts/openbao-seed.sh

bao-password: ## Print the OpenBao `admin` password (https://bao.lab.macpro, method Username)
	@SOPS_AGE_KEY_FILE=.cache/age/key.txt .tools/bin/sops --decrypt --extract '["data"]["admin-password"]' k8s/platform/openbao/seed.enc.yaml | base64 -d; echo

trust-root: ## sudo: trust the lab root CA on this workstation (system store, p11-kit)
	sudo trust anchor --store k8s/platform/step-ca/config/root_ca.crt
	@trust list --filter=ca-anchors | grep -B2 -A2 "homelab-cloud Root CA"

.PHONY: verify verify-host
verify-host: ## Phase 1 checks (needs the test VM: TF_VAR_enable_test_vm=true make host)
	scripts/verify-host.sh

verify: ## Cluster checks: nodes, Cilium, Argo CD, Gateway + TLS, storage
	scripts/verify-cluster.sh

.PHONY: test
test: ## Run infra/app tests
	$(call todo,Phase 4/6)
