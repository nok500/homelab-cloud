# 0002: VM sizing: start minimal (1 vCPU / 1 GiB per VM)

- Status: accepted (the defaults below were the starting point; the Log tracks every change since)
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
| 2026-11-19 | Phase 2: workers 1 → **2 vCPU**, 1 → **2 GiB**; `talos-cp-1` 2 → **4 GiB** (operator) | 1 vCPU: Cilium probes time out → crash loops. 1 GiB: memory thrashing (PSI `full avg60` 24.5 %) once Cilium + Argo CD run |
| 2026-11-20 | Before Phase 3: workers 2 → **4 GiB**, `opnsense` 1 → **4 GiB** (operator) | Headroom for the Phase 3 services; from here, bump only on measured pressure (PSI) |
| 2026-11-23 | Before milestone 7 (Harbor): workers 4 → **10 GiB**, `opnsense` 4 → **3 GiB** (operator: use the host's RAM, keep ~4 GiB for the host OS; llama.cpp runs only on demand) | Worker requests were ~45 % and limits 103–123 % of 4 GiB after Keycloak, with Harbor and Phases 4–5 still to come. OPNsense only routes, so it goes to its documented 3 GB minimum. Lab total 16 → **27 GiB** of 31.3. Applied offline: `make shutdown`, apply, `make start` (an in-place change power-cycles running nodes) |

## Consequences

Resizing means changing a variable and running `terraform apply` (the VM restarts; for Talos nodes that's a
reboot, see `docs/runbooks/cluster-access.md`). The clean way for memory: `make shutdown`, `scripts/tf.sh host
apply` (OPNsense first, started by hand; Terraform starts the Talos VMs), then `make start`. With llama.cpp
loaded on the host, the workers have to shrink again. Each bump is recorded here with its
reason, which shows how the footprint grows phase by phase.
