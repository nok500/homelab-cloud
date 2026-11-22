# Runbook: power (safe shutdown, start, host reboot)

Never power off or reboot the Mac Pro with the lab running and nothing else in place. Talos ignores the ACPI
power button, so the nodes get killed mid-write, and an unclean stop has already left OPNsense unbootable once
(2026-11-20, [opnsense.md](opnsense.md) § OPNsense doesn't boot after a host reboot).

## Shut down

| Goal | Command (from voodoo) | What happens |
|---|---|---|
| Stop the lab, keep the host up | `make shutdown` | workers: `talosctl shutdown` (cordon + drain, clean OS stop) → control plane (etcd last) → OPNsense (ACPI). Each step waits until libvirt reports `shut off`, and forces a VM off only after `SHUTDOWN_TIMEOUT` (300 s), saying so |
| Stop the lab **and** power off the Mac Pro | `make poweroff` | the same, then `ssh -t macpro sudo systemctl poweroff` (asks for the sudo password) |

Measured 2026-11-20: `make shutdown` takes about 1.5 min, with no VM forced off.

## Start

| After | Do |
|---|---|
| `make poweroff` / any host boot | Power on the Mac Pro. libvirt autostarts all four VMs (Terraform sets `autostart`). Then `make start` (it waits until every Talos API and node is up), then `make verify` |
| `make shutdown` (host still up) | `make start`: OPNsense first (DHCP/DNS/NAT for everything), then the control plane, then the workers, and it waits until all nodes are Ready |

voodoo also needs `make route` again if *it* rebooted. Without it, `make up`/`make start` wait on the API forever
(the bootstrap now prints a hint after 30 s).

`make up` on a lab that already exists is safe too (it starts the VMs, then the bootstrap sees the root app and
leaves Cilium and Argo CD to Argo CD), but `make start` is the quick path after `make shutdown`.

Nodes come back schedulable on their own (Talos uncordons after a clean boot). Workloads are back a few
minutes after the nodes; `make verify` checks everything.

## Safety net: libvirt-guests

If the host goes down some other way (`sudo reboot`, a package update, the power button), `libvirt-guests`
shuts the VMs down first, once it is configured:

```sh
# on the Mac Pro, once (Arch ships no config file; without one the default is suspend)
sudo tee /etc/conf.d/libvirt-guests >/dev/null <<'CONF'
URIS=qemu:///system
ON_BOOT=ignore            # VMs come back via libvirt autostart (set by Terraform)
ON_SHUTDOWN=shutdown      # graceful shutdown, not suspend/kill
PARALLEL_SHUTDOWN=4       # all VMs at once
SHUTDOWN_TIMEOUT=120      # then force off whatever is left
CONF
sudo systemctl enable --now libvirt-guests   # shows "active (exited)": it only acts at shutdown
```

It's only a net: the Talos nodes have the QEMU guest agent (ADR 0005), so libvirt's shutdown should go through
it rather than ACPI, but that hasn't been tested on a real host shutdown. `make poweroff` is the path that's been
tested. In both cases the order isn't guaranteed (all VMs at once), which is why `make shutdown` exists.

## Check

```sh
ssh macpro virsh -c qemu:///system list --all      # all "shut off" after shutdown, "running" after start
make verify                                        # everything green after start
```
