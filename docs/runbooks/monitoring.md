# Runbook: lab monitor (TUI)

Design: [ADR 0009](../decisions/0009-lab-tui.md). Layout: [docs/img/tui-layout.png](../img/tui-layout.png).

## Open and close

| Goal | Command (from the repo on voodoo) |
|---|---|
| Open the monitor, or reattach | `make tui` |
| Build the lab and watch it | `make up` (from a terminal it opens the TUI and builds in the bottom box) |
| Plain build, no TUI | `NO_TUI=1 make up`, or `make build` |
| Leave it running in the background | tmux prefix (default `Ctrl-b`), then `d` |
| Close it | `make tui-kill` |

Use a terminal of at least 160×45. In the TUI, click a box to focus it, prefix `z` zooms the focused box
(again to unzoom), and the Talos dashboard takes its own keys when focused (F2 Monitor, F3 Resources, ←/→ switch
node). Inside an existing tmux, `make tui` switches your client to the `homelab` session instead of nesting.

## Reading it

| Box | Shows | Look for |
|---|---|---|
| Status (top line) | talos, kubernetes, cilium, argocd, gateway, storage, secrets. ● green: healthy, ● yellow: converging or partly ready, ● red: down or Degraded, ○ grey: not built yet | All green a few minutes after `make up` / `make start`. Yellow for longer than ~15 min after a rebuild: see the matching runbook |
| CPU / RAM / TEMP | Mac Pro CPU %, load, memory, package and hottest core temperature, fan | Temperatures ≥ 70 °C are yellow, ≥ 80 °C red: the shared heatsink is the lab's weak point (`make temps`) |
| QEMU VMs | each VM's state, vCPU, CPU %, RSS and RAM; the host headroom | The headroom line turns red when the host keeps fewer than 2 threads or 4 GiB |
| Pods | every pod, problems first (red: failing, yellow: starting) | Restarts in yellow; `CrashLoopBackOff`, `ImagePullBackOff`, `Pending` |
| Nodes | Ready, role, IP, pod count, CPU and memory **requests** against allocatable | Requests near 100 % means new pods stay Pending even when real usage is low |
| Talos dashboard | `talosctl dashboard` for every node: stage, READY, services, logs | `READY × False` long after boot, failing services. `SECUREBOOT × False` is expected (SeaBIOS) |

During `make up` the boxes start grey or "waiting…" and fill in layer by layer. The log of each run is
`.cache/logs/make-up-<time>.log`; the last result is in `.cache/tui/up.status`.

## When a box says…

| Message | Meaning |
|---|---|
| `macpro unreachable` | SSH to the host fails: [opnsense.md](opnsense.md) § Connectivity loss, step 1 |
| `waiting for the Kubernetes API…` | No kubeconfig yet (mid-build or destroyed), or the API is down: `talosctl -n 10.10.1.20 health` |
| `Talos dashboard: waiting for the Talos API…` | The nodes are off or unreachable: `make start`, or check `make route` after a voodoo reboot |
| `make up failed (exit N)` | The build stopped. Read the log path shown, fix it, run `make up` again: it reuses the open TUI |
