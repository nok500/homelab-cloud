# 0006: Storage: local-path PVs on worker data disks; Terraform state in a host-level Garage

- Status: accepted (state part lands with Phase 3 milestone 4)
- Date: 2026-11-20

## Persistent volumes: local-path-provisioner

| Option | Verdict |
|---|---|
| **local-path-provisioner v0.0.37** on a dedicated worker disk | **Chosen.** About 50 MB of RAM. Each PV is a directory on one node: the lab's "instance store" |
| Longhorn | Replicated, closer to EBS, but needs a new Talos schematic (iscsi-tools, util-linux) and about 1–1.5 GB of RAM across nodes, on 4 GiB workers |

- Each worker gets a second qcow2 disk (`vdb`, `worker_data_disk_gb`, default 40, thin-provisioned). Talos formats
  it as the `local-path-provisioner` **UserVolumeConfig** (XFS), mounted at `/var/mnt/local-path-provisioner`.
  Keeping PVs off the system disk means a full volume can't fill EPHEMERAL (containerd, logs) and evict pods.
- Upstream manifest pinned by tag, plus three Kustomize patches: the PV path, a pinned helper image
  (`busybox:1.37.0`, unpinned upstream), and `privileged` Pod Security on its namespace (the helper pods use hostPath).
- `volumeBindingMode: WaitForFirstConsumer`: a PV is created on whichever node the pod is scheduled to, and
  the pod is pinned to that node from then on.

**Consequence:** node-local data doesn't survive losing its node. Anything that matters gets its durability one
level up: CNPG replicates and backs up to S3, Harbor stores blobs in S3, and OpenBao is rebuilt and re-seeded
([ADR 0008](0008-secrets-openbao.md)). Same rule as instance store on AWS.

## Terraform state: Garage on the Mac Pro host, outside the lab

`terraform/host` creates the VPC and the cluster. If its state lived in a bucket *inside* the cluster,
`make destroy` would delete the bucket holding the state it's working from. So the state bucket lives one
level out, in a small Garage on the host (Docker, systemd), which `make destroy` never touches. That's the
equivalent of a state bucket in a separate management account. The same Garage also serves the in-cluster
S3 needs (CNPG backups, later Harbor) through separate buckets and keys, so the lab runs a single S3 service.
