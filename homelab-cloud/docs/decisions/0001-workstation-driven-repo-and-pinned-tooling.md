# 0001: Drive the lab from a workstation, with repo-local pinned tooling

- Status: accepted
- Date: 2026-11-19

## Context

The lab host (Mac Pro) is the "AWS region". The repo could live on the host itself or on a separate
workstation. Dev tools (pre-commit, tflint, gitleaks) could come from the distro or be pinned per repo.

## Decision

1. The repo lives on a **workstation** and targets the host remotely: Terraform's libvirt provider over
   `qemu+ssh://`, `talosctl`/`kubectl` over the network. The host stays plain, like a cloud account we don't SSH into.
2. Dev tools are installed by `scripts/bootstrap-tools.sh` into `./.tools`, with **pinned versions verified
   against published SHA-256 checksums**. No sudo, no global state, and the same versions on every clone and in CI.

## Consequences

- `make destroy && make up` can't accidentally depend on files that only exist on the host.
- The host only needs libvirt/QEMU and SSH (documented in `bootstrap.md`).
- Tool upgrades are explicit commits (bump the version variable in the script). Pinned now: tflint 0.66.0,
  gitleaks 8.30.1, pre-commit 4.7.0, talosctl 1.14.6, sops 3.13.3, age 1.3.2 (hash pinned: age publishes Sigsum
  proofs, no checksum file), step 0.31.0.
- Linux/amd64 only for now; CI runners match.
