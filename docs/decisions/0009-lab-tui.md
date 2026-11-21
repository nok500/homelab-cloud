# 0009: Lab monitor ("console at a glance"): a tmux TUI, and `make up` runs inside it

- Status: accepted
- Date: 2026-11-21

## Context

There was no single screen showing whether the lab is healthy. That meant `make verify` (37 checks, about a
minute), `kubectl` and `talosctl dashboard` in separate terminals, and `make temps` for the Mac Pro, whose shared
heatsink is the lab's weakest part. A build (`make up`, 15–25 min) only showed Terraform and bootstrap logs, with
no view of the VMs, nodes and pods coming up. The layout to follow is [docs/img/tui-layout.png](../img/tui-layout.png).

## Decision

| Option | Verdict |
|---|---|
| **tmux session: six boxes, each a small loop** (`scripts/tui.sh`, `scripts/tui/`) | **Chosen.** The Talos box is the real `talosctl dashboard`, which is itself a full-screen TUI and only embeds cleanly in a real terminal, i.e. a tmux pane. The other boxes are one stdlib-only Python script (`panel.py`), so there's nothing new to pin. tmux is a distro package on the workstation, like `make` and `python3`. Detach and reattach for free; a build survives closing the terminal |
| Python Textual / Go Bubble Tea app | One process looks nicer, but can't host `talosctl dashboard` without a terminal emulator widget, and adds a pinned toolchain |
| k9s plus a terminal split | Great for drilling into pods, but no host, VM or Talos view, and the layout isn't repeatable |
| Grafana | Arrives with kube-prometheus-stack (Phase 4) for history and alerts. It's a browser and needs the cluster to be up, so it can't show a build from zero or a broken host |

**`make up` from a terminal opens the TUI first** and runs the build in the bottom box (`script(1)` keeps a TTY
for Terraform's prompt and writes `.cache/logs/make-up-<time>.log`). The boxes above fill in as each layer comes
up: VMs, then Talos, then nodes and pods. On success the box switches to the Talos dashboard; on failure it stops
with the exit code and the log path. Without a terminal (CI, pipes) or with `NO_TUI=1`, `make up` is the plain
build (`make build`), so `make destroy && make up` keeps working everywhere.

## What each box reads

| Box | Source | Refresh |
|---|---|---|
| Status dots | `talosctl get machinestatus`; `kubectl get` on nodes, Cilium, Argo CD Applications, Gateway + certificate, local-path, OpenBao + ClusterSecretStore + ExternalSecrets | 10 s |
| CPU, RAM, TEMP | one SSH call to the Mac Pro: `/proc/stat` (over 1 s), `/proc/meminfo`, `sensors -j` | 2 s |
| QEMU VMs | `virsh domstats` over SSH: state, vCPU, CPU % (from `cpu.time`), RSS against configured RAM, and the host headroom against the 2-thread / 4 GiB reserve | 3 s |
| Pods | `kubectl get pods -A`, problems first | 3 s |
| Nodes | `kubectl get nodes`, plus resource requests summed per node against allocatable (no metrics-server needed) | 5 s |
| Talos | `talosctl dashboard -n <all nodes>`, restarted when it exits or the lab comes back | live |

## Consequences

- It's read-only: the TUI never changes anything, so running it is always safe.
- The SSH calls share one multiplexed connection (`.cache/ssh/`), so polling doesn't open a new session every
  2–3 s.
- The boxes always use the repo's kubeconfig and talosconfig, never an inherited `KUBECONFIG`. That was caught in
  testing: the tmux server had `KUBECONFIG=~/.kube/config:…` from the shell.
- The point-in-time view complements `make verify`; it doesn't replace it. Use verify after changes, the TUI
  while things run.
