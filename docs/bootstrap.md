# Bootstrap (manual, one-time steps)

Everything after these steps is code. Keep this list as short as possible.

## 0. Workstation (where you run `make`)

Requirements: `git`, `make`, `python3`, `curl`, `terraform` ≥ 1.15, `tmux` ≥ 3.4 (the lab monitor, `make tui`), SSH key access to the lab host.

```sh
make hooks   # installs pinned tflint, gitleaks and pre-commit into ./.tools, then installs the git hooks
make lint
```

## 1. Lab host: hypervisor (Phase 1)

Run on the Mac Pro as a sudo-capable user:

```sh
sudo pacman -S --needed qemu-base libvirt dnsmasq edk2-ovmf openbsd-netcat
sudo usermod -aG libvirt "$USER"           # lets Terraform use qemu:///system over SSH without sudo
sudo systemctl enable --now libvirtd.socket
```

Then log out and back in (for the group), and check:

```sh
virsh -c qemu:///system list --all
virt-host-validate qemu
```

Notes:

- `openbsd-netcat` is required by the Terraform libvirt provider's `qemu+ssh://` transport.
- If libvirt defines the `default` NAT network (`virbr0`, 192.168.122.0/24), leave it **stopped**. The lab
  uses its own networks with OPNsense doing NAT:
  `sudo virsh net-autostart default --disable; sudo virsh net-destroy default`
- Installing libvirt does not touch UFW or the LAN interface, so the SSH session is safe.

## 2. Lab host: dedicated WAN uplink for OPNsense

Before cabling the second NIC, stop the stock networkd config from giving it a host IP, which would add a second
default route on the same subnet. Use the NIC's permanent MAC (`ip link show enp11s0`):

```sh
sudo tee /etc/systemd/network/10-lab-uplink.network >/dev/null <<'NET'
# enp11s0 = dedicated OPNsense WAN uplink (macvtap). No host IP on purpose.
[Match]
PermanentMACAddress=00:3e:e1:bf:f8:82

[Link]
RequiredForOnline=no

[Network]
DHCP=no
LinkLocalAddressing=no
IPv6AcceptRA=no
MulticastDNS=no
NET
sudo networkctl reload && sudo networkctl reconfigure enp11s0
ip -br a show enp11s0        # UP, no address
ip -4 route show default     # one route, via enp12s0
```

Then plug the cable into the LAN switch/router. Without a second NIC, set `wan_parent_interface` to the host's
LAN NIC instead (the host then can't reach OPNsense; see ADR 0003).

## 3. Workstation: Phase 1 extras

- `genisoimage` (packs the OPNsense `config.xml` ISO), `qemu-img` (image conversion), `virsh` (libvirt client).
- `terraform/host/lab.auto.tfvars` (git-ignored), from `lab.auto.tfvars.example`: at least `admin_cidrs`.

```sh
make up       # images -> pool, networks, OPNsense (scripted first boot), test VM   (~2 min)
make route    # sudo: 10.10.0.0/16 via OPNsense WAN on this workstation (not persistent)
make verify   # Phase 1 acceptance checks
make destroy  # removes everything libvirt-side; the host is back to its pre-lab state
```

## 4. Phase 2: cluster prerequisites (once)

1. **Argo CD deploy key.** `scripts/bootstrap-cluster.sh` expects `.cache/cluster/argocd-deploy-key`:
   ```sh
   ssh-keygen -t ed25519 -N '' -C 'argocd@homelab-cloud (read-only deploy key)' -f .cache/cluster/argocd-deploy-key
   ```
   Add the `.pub` half on the GitHub repo: Settings → Deploy keys → Add deploy key, **write access off**.
   (Repo-scoped and read-only; never add it as an account SSH key.)
2. **AdGuard DNS rewrite** (Filters → DNS rewrites): `*.lab.macpro` → `10.10.1.200` (the Cilium Gateway).
3. `make up` (VPC + VMs + Talos + Cilium + Argo CD, ~15 min), then see `docs/runbooks/cluster-access.md`.

## 5. Phase 3: private PKI and SOPS key (once)

1. `make pki` creates the root and intermediate CA, the step-issuer provisioner and the age key
   (`scripts/pki-init.sh`, which refuses to run twice). Commit what it writes (`.sops.yaml`,
   `k8s/platform/step-ca/config/`, `k8s/platform/certificates/step-cluster-issuer.yaml`, and the OpenBao seed
   `k8s/platform/openbao/seed.enc.yaml`).
2. **Back up** `.cache/ca/` and `.cache/age/key.txt` with `make pki-backup` (age-encrypted, passphrase in your
   password manager, file off voodoo). They're git-ignored, and without the age key nothing in `*.enc.yaml` can
   be decrypted. Details and restore: `docs/runbooks/pki.md` § Backup & restore.
3. `make trust-root` (sudo) on every machine that browses `*.lab.macpro`; other OSes in `docs/runbooks/pki.md`.

After a rebuild nothing here repeats: `bootstrap-cluster.sh` re-applies the OpenBao seed (`make secrets`),
OpenBao seeds itself from it, External Secrets fills in the rest, and the root stays the same.
OpenBao admin: `make bao-password`, see `docs/runbooks/secrets.md`.

## 6. Phase 3: Terraform state in Garage (once)

1. `make garage` deploys Garage S3 and its TLS proxy on the Mac Pro host (Docker Compose, no sudo), and writes
   `host/garage/secrets.enc.yaml` the first time: commit it.
2. AdGuard Home (192.168.8.1) → *Filters → DNS rewrites*: `s3.lab.macpro` → `192.168.8.207`. The exact name wins
   over the `*.lab.macpro` wildcard. Check: `getent hosts s3.lab.macpro`.
3. `make state-migrate` moves existing local state into Garage (skip on a fresh clone: there's nothing local).

Details, restore and rebuild: `docs/runbooks/terraform-state.md`. After a lab rebuild nothing here repeats:
Garage lives outside the lab.
