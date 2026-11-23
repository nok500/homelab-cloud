SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

export PATH := $(CURDIR)/.tools/bin:$(PATH)
# This lab is one folder of the lab monorepo; git hooks and the pre-commit config live at the repo root.
REPO_ROOT := $(shell git rev-parse --show-toplevel)
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
	cd "$(REPO_ROOT)" && pre-commit install
	sed -i '1a export PATH="$$(git rev-parse --show-toplevel)/homelab-cloud/.tools/bin:$$PATH"' "$$(git rev-parse --git-path hooks)/pre-commit"

.PHONY: lint
lint: tools ## Run all pre-commit checks on every file of this lab
	pre-commit run --config "$(REPO_ROOT)/.pre-commit-config.yaml" --files $$(git ls-files)

.PHONY: temps
temps: ## Show lab host CPU temperatures and fan speed
	scripts/host-temps.sh

# scripts/tf.sh: local lock + encrypted state history around terraform (state lives in Garage, ADR 0010)
TF_HOST := scripts/tf.sh host
TF_TALOS := scripts/tf.sh talos
# scripts/identity.sh: tf.sh plus the seeded Keycloak credentials as TF_VAR_* (ADR 0012)
TF_IDENTITY := scripts/identity.sh
# AUTO_APPROVE=1 make up|destroy skips the interactive confirmation
TF_APPROVE := $(if $(AUTO_APPROVE),-auto-approve,)
LAB_CIDR := 10.10.0.0/16
WAN_IP_FILE := .cache/host/opnsense-wan.ip
export KUBECONFIG := $(CURDIR)/.cache/cluster/kubeconfig
export TALOSCONFIG := $(CURDIR)/.cache/cluster/talosconfig

.PHONY: garage garage-ui-password state-migrate state-history
garage: ## Deploy/converge Garage S3 (Terraform state, CNPG backups) on the Mac Pro host; no sudo, idempotent
	scripts/garage-deploy.sh

garage-ui-password: ## Garage UI login (https://s3.lab.macpro:3909, user admin): print the password
	@SOPS_AGE_KEY_FILE=.cache/age/key.txt sops --decrypt host/garage/secrets.enc.yaml \
	  | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["stringData"]["garage_ui_admin_password"])'

state-migrate: ## One-time: move local Terraform state into Garage (keeps an encrypted copy)
	scripts/state-migrate.sh

state-history: ## List the encrypted Terraform state snapshots (.cache/state-history; restore: docs/runbooks/terraform-state.md)
	@for s in host talos; do echo "$$s:"; ls -1 .cache/state-history/$$s 2>/dev/null | tail -5 | sed 's/^/  /'; done

.PHONY: images
images: ## Download + verify VM base images into .cache/images
	scripts/fetch-images.sh

.PHONY: init
init:
	$(TF_HOST) init -input=false
	$(TF_TALOS) init -input=false
	$(TF_IDENTITY) init -input=false

.PHONY: plan
plan: images init ## Terraform plan for the whole lab
	$(TF_HOST) plan -input=false
	$(TF_TALOS) plan -input=false

.PHONY: up build
# From a terminal, make up runs the build inside the lab TUI (bottom box) and leaves you in the TUI.
# NO_TUI=1, or no terminal (CI, pipes), runs the plain build.
up: ## Build everything (VPC, OPNsense, Talos VMs, cluster) and watch it in the TUI, then show the logins; NO_TUI=1 for plain output
	@if [[ -t 0 && -t 1 && -z "$${NO_TUI:-}" ]] && command -v tmux >/dev/null; then scripts/tui.sh --up; \
	else $(MAKE) --no-print-directory build && scripts/logins.sh --if-tty; fi

build: host route-ensure cluster identity ## The build behind make up, without the TUI

.PHONY: route-ensure
route-ensure: # make up/start: add the VPC route only if it's missing (sudo asks for the password then)
	scripts/route-ensure.sh

.PHONY: tui tui-kill
tui: ## Lab monitor: status, host CPU/RAM/temp, VMs, pods, nodes, Talos dashboard (tmux; prefix d detaches)
	scripts/tui.sh

tui-kill: ## Close the lab monitor session
	scripts/tui.sh --kill

.PHONY: host
host: images init ## VPC networks, OPNsense, Talos VMs (terraform/host)
	$(TF_HOST) apply -input=false $(TF_APPROVE)
	@echo "OPNsense WAN: $$(cat $(WAN_IP_FILE))"

.PHONY: cluster
cluster: init ## Talos config + bootstrap (terraform/talos), then Cilium + Argo CD (scripts/bootstrap-cluster.sh)
	$(TF_TALOS) apply -input=false $(TF_APPROVE)
	scripts/bootstrap-cluster.sh

.PHONY: logins
logins: ## Every lab login: URL, user and password (prints secrets; Argo CD local admin needs the cluster up)
	@scripts/logins.sh

.PHONY: identity sso-password
identity: ## Keycloak realm, users, groups, OIDC clients (terraform/identity; Keycloak must be up)
	$(TF_IDENTITY) init -input=false
	$(TF_IDENTITY) apply -input=false $(TF_APPROVE)

sso-password: ## Print the password of `labadmin`, the lab's SSO user (https://sso.lab.macpro, Argo CD)
	@SOPS_AGE_KEY_FILE=.cache/age/key.txt .tools/bin/sops --decrypt --extract '["data"]["keycloak-labadmin-password"]' k8s/platform/openbao/seed.enc.yaml | base64 -d; echo

.PHONY: down destroy
down destroy: init ## Tear the lab down completely (cluster state first, then the VMs)
	$(TF_IDENTITY) forget   # the realm dies with the cluster: nothing to destroy, just forget it
	$(TF_TALOS) destroy -input=false $(TF_APPROVE)
	$(TF_HOST) destroy -input=false $(TF_APPROVE)
	rm -f .cache/cluster/kubeconfig .cache/cluster/talosconfig
	scripts/garage-wipe.sh cnpg-backups lab/   # fresh databases next time: empty WAL archive (ADR 0011)

.PHONY: db-restore-test
db-restore-test: ## Point-in-time restore of pg-demo from Garage into a new cluster, checked row by row
	scripts/db-restore-test.sh

.PHONY: shutdown poweroff start
shutdown: ## Safe stop of all lab VMs: drain + stop workers, control plane, then OPNsense (host stays up)
	scripts/lab-shutdown.sh

poweroff: ## shutdown, then power off the Mac Pro (asks for the sudo password on macpro)
	POWEROFF=1 scripts/lab-shutdown.sh

start: ## Start the lab after `make shutdown` or a host power-on: VMs (OPNsense first), then wake the databases
	scripts/lab-start.sh

.PHONY: route
route: ## Route the lab CIDR via the OPNsense WAN on this workstation (sudo; make up/start do it when missing)
	FORCE=1 scripts/route-ensure.sh

.PHONY: unroute
unroute: ## Remove the lab route from this workstation (sudo)
	-sudo ip route del $(LAB_CIDR)

.PHONY: pki pki-backup secrets trust-root
pki: tools ## ONE-TIME: lab root/intermediate CA + age key (refuses to overwrite; back up .cache/ca + .cache/age)
	scripts/pki-init.sh

pki-backup: ## Encrypted backup of .cache/ca + .cache/age (asks for a passphrase); BACKUP_DIR=~ by default
	@out="$${BACKUP_DIR:-$$HOME}/homelab-pki-$$(date +%F).tar.gz.age"; \
	tar -C .cache -czf - ca age | .tools/bin/age -p > "$$out" && chmod 600 "$$out" && \
	echo "wrote $$out" && .tools/bin/age -d "$$out" | tar -tzf - | sed 's/^/  /'

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
