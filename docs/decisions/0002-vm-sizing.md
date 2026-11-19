# 0002: VM sizing: start minimal (1 vCPU / 1 GiB per VM)

- Status: proposed (to confirm in Phase 1/2)
- Date: 2026-11-19

## Context

The host has 31.3 GiB usable RAM and 8 threads (see [host.md](../host.md)). At least 4 GiB and 2 threads stay
with the host, and the llama.cpp container keeps running alongside the lab.

The owner asked to start with **1 vCPU / 1 GiB for every VM** and scale up on demand.

Vendor minimums (checked 2026-11-19):

| Component | Documented minimum | Source |
|---|---|---|
| Talos control plane | 2 cores, 2 GiB, 10 GiB disk | docs.siderolabs.com, System requirements |
| Talos worker | 1 core, 1 GiB, 10 GiB disk | same |
| OPNsense | 2 cores, 3 GB ("reduced" feature set) | docs.opnsense.org, Hardware sizing |

## Decision

Sizes are **Terraform variables per role**. Defaults follow the owner's request:

| VM | vCPU | RAM | Disk |
|---|---|---|---|
| opnsense | 1 | 1 GiB | 16 GiB |
| talos-cp-1 | 1 | 1 GiB | 20 GiB |
| talos-worker-1 | 1 | 1 GiB | 20 GiB |
| talos-worker-2 | 1 | 1 GiB | 20 GiB |
| **Total** | **4** | **4 GiB** | 76 GiB |

## Risks (known going in)

- **Talos control plane at 1 GiB is half the documented minimum.** etcd + kube-apiserver + Cilium agent are
  likely to OOM or fail health checks. Expected first bump: `cp` to 2 vCPU / 2 GiB (still only 5 GiB total).
- **OPNsense below the documented minimum** usually still routes/NATs fine for a lab with no IDS or
  plugins. Bump it to 2 GiB if the web UI or updates misbehave.
- **Workers at 1 GiB** leave about 500 MiB for pods after Talos + Cilium. That's enough for Phase 2 smoke tests, but not for
  Argo CD + Phase 3 services. Expect workers to grow to 4–8 GiB by Phase 3.

## Log

| Date | Change | Why |
|---|---|---|
| 2026-11-19 | Phase 1: `opnsense` and `testvm` at 1 vCPU / 1 GiB | OPNsense routes, NATs and serves DHCP/DNS fine at 1 GiB with no plugins |
| 2026-11-19 | Phase 2: `talos-cp-1` memory 1 → **2 GiB** (still 1 vCPU); workers stay 1 vCPU / 1 GiB | Talos's cluster health gate rejects it: `node does not meet memory requirements: expected at least 1698 MiB, actual 944 MiB`. Workers pass at 1 GiB |

## Consequences

Resizing means changing a variable and running `terraform apply` (the VM restarts). Each bump is recorded here with its
reason, which shows how the footprint grows phase by phase.
