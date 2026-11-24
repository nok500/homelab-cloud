#!/usr/bin/env python3
"""Generate terraform/talos/seccomp/buildkit-rootless.json: the seccomp profile rootless BuildKit runs under (ADR 0015).

Docker's default profile (moby/profiles seccomp/v0.3.0, pinned by sha256 in UPSTREAM.sha256), plus one rule that allows the
namespace and mount calls rootlesskit and BuildKit's worker make inside their own user namespace. Docker's
profile allows those only to containers holding CAP_SYS_ADMIN, and containerd resolves that condition when it
loads the profile, from the container's own capabilities: a rootless pod never has it, so without this rule
`unshare(CLONE_NEWUSER)` fails and BuildKit can't start. A second rule turns the keyring calls' EPERM into
ENOSYS, which runc tolerates (they stay blocked). Everything else stays as Docker ships it.

Talos writes the profile to /var/lib/kubelet/seccomp/profiles/ on the workers; build pods use it as
`seccompProfile: {type: Localhost, localhostProfile: profiles/buildkit-rootless.json}`, which Pod Security
`baseline` allows (it forbids only Unconfined).

Usage: scripts/seccomp-buildkit.py   (re-run after changing the pin or the extra rule; commit the output)
"""
import hashlib
import json
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "terraform" / "talos" / "seccomp" / "buildkit-rootless.json"
UPSTREAM = "https://raw.githubusercontent.com/moby/profiles/seccomp/v0.3.0/seccomp/default.json"

# What rootlesskit (user + mount namespaces, the uid map) and BuildKit's OCI worker without a process sandbox
# (mount namespace, overlay/bind mounts, pivot_root into the rootfs) call. clone3 stays ENOSYS (Docker's
# choice): glibc falls back to clone, which this rule allows with namespace flags.
EXTRA = {
    "names": ["clone", "unshare", "setns", "mount", "umount2", "pivot_root",
              "fsopen", "fsconfig", "fsmount", "fspick", "move_mount", "open_tree", "mount_setattr",
              "sethostname", "setdomainname"],
    "action": "SCMP_ACT_ALLOW",
    "comment": "homelab-cloud: rootless BuildKit (ADR 0015), inside its own user namespace only",
}
# The kernel keyring stays off limits (it isn't namespaced), but as ENOSYS instead of Docker's EPERM: runc
# creates a session keyring for every build step and skips that only on ENOSYS ("unable to join session
# keyring: operation not permitted" otherwise, found on the first live test 2026-11-24).
NO_KEYRING = {
    "names": ["keyctl", "add_key", "request_key"],
    "action": "SCMP_ACT_ERRNO",
    "errnoRet": 38,
    "comment": "homelab-cloud: ENOSYS, so runc skips the session keyring (ADR 0015)",
}


def main() -> int:
    raw = urllib.request.urlopen(UPSTREAM, timeout=30).read()
    digest = hashlib.sha256(raw).hexdigest()
    pin = (ROOT / "terraform" / "talos" / "seccomp" / "UPSTREAM.sha256")
    if pin.exists() and pin.read_text().split()[0] != digest:
        print(f"upstream changed: {digest} != pinned {pin.read_text().split()[0]}", file=sys.stderr)
        return 1
    profile = json.loads(raw)
    profile["syscalls"] += [EXTRA, NO_KEYRING]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(profile, indent=1) + "\n")
    pin.write_text(f"{digest}  {UPSTREAM}\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(profile['syscalls'])} rules; upstream sha256 {digest[:16]}…)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
