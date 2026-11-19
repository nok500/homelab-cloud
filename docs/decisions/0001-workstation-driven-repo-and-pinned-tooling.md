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
- Tool upgrades are explicit commits (bump the version variable in the script).
- Linux/amd64 only for now; CI runners match.
