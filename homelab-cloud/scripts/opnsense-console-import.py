#!/usr/bin/env python3
"""Drive the OPNsense first-boot config importer over a serial console.

OPNsense has no cloud-init. On every boot `opnsense-importer -b` runs; when no
/conf/config.xml exists yet (fresh image) it shows a ~7 s "Press any key"
countdown, then asks for a device to import /conf/config.xml from. This script
spawns a command that is attached to the VM's serial console *before* the VM
boots (e.g. `virsh start --console`), answers both prompts, waits for the
login banner and prints the WAN IPv4 address that OPNsense reports.

Stdlib only (no pexpect), so it runs anywhere Terraform runs.

  opnsense-console-import.py --device cd0 --log boot.log --wan-ip-file wan.ip -- \
      virsh -c qemu+sshcmd://macpro/system start opnsense --console
"""

import argparse
import os
import pty
import re
import select
import signal
import sys
import time


class Console:
    def __init__(self, cmd, log):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # child
            os.execvp(cmd[0], cmd)
        self.buf = ""
        self.log = log

    def expect(self, patterns, timeout):
        """Wait until one of the regexes matches; return (index, match). Consumes the buffer up to the match."""
        deadline = time.monotonic() + timeout
        compiled = [re.compile(p) for p in patterns]
        while True:
            for i, rx in enumerate(compiled):
                m = rx.search(self.buf)
                if m:
                    self.buf = self.buf[m.end():]
                    return i, m
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"timed out after {timeout}s waiting for {patterns!r}")
            r, _, _ = select.select([self.fd], [], [], min(left, 1.0))
            if r:
                try:
                    data = os.read(self.fd, 4096)
                except OSError:
                    data = b""
                if not data:
                    raise EOFError("console closed (did the VM fail to start, or was it already running?)")
                text = data.decode("utf-8", "replace")
                self.log.write(text)
                self.log.flush()
                # strip ANSI escapes so patterns stay simple
                self.buf += re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)

    def send(self, s):
        os.write(self.fd, s.encode())

    def close(self):
        try:
            self.send("\x1d")  # Ctrl-] detaches `virsh console`
            time.sleep(1)
            os.kill(self.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", default="cd0", help="FreeBSD device holding /conf/config.xml (default: cd0)")
    ap.add_argument("--log", required=True, help="file to write the full console transcript to")
    ap.add_argument("--wan-ip-file", help="write the WAN IPv4 address reported on the login banner here")
    ap.add_argument("--boot-timeout", type=int, default=300)
    ap.add_argument("--ready-timeout", type=int, default=600)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        ap.error("missing console command after --")

    with open(a.log, "w") as log:
        con = Console(cmd, log)
        try:
            step = lambda msg: print(f"[opnsense-import] {msg}", file=sys.stderr, flush=True)  # noqa: E731

            step("waiting for the importer prompt")
            con.expect([r"Press any key to start the configuration importer"], a.boot_timeout)
            con.send(" ")

            # The importer runs very early in boot; CAM may not have attached the CD yet (camcontrol shows
            # "()" instead of "(cd0,pass1)"). On failure the importer re-prompts, so wait and retry.
            for attempt in range(1, 21):
                con.expect([r"Select device to import from"], 60)
                if attempt > 1:
                    time.sleep(3)
                step(f"selecting {a.device} (attempt {attempt})")
                con.send(a.device + "\r")
                i, _ = con.expect(
                    [r"Restoring config\.xml\.\.\.done",
                     r"No known partition layout|could not be mounted|could not be found|could not be decrypted"],
                    120,
                )
                if i == 0:
                    break
            else:
                raise RuntimeError(f"import from {a.device} failed after retries, see {a.log}")
            step("config.xml imported, waiting for boot to finish")

            # The banner printed at the end of boot lists every interface with its address, then the
            # SSH host key fingerprints (RSA last), then the login prompt.
            _, m = con.expect([r"\*\*\* .+ \*\*\*([\s\S]*?)(?:\(RSA\)|login:)"], a.ready_timeout)
            banner = m.group(1)
            wan = re.search(r"WAN \([^)]*\)\s*->\s*v4(?:/DHCP4)?:\s*(\d+\.\d+\.\d+\.\d+)/", banner)
            if wan:
                step(f"ready, WAN = {wan.group(1)}")
                if a.wan_ip_file:
                    with open(a.wan_ip_file, "w") as f:
                        f.write(wan.group(1) + "\n")
            else:
                step("ready, but no WAN IPv4 on the banner yet (DHCP still pending?)")
                if a.wan_ip_file:
                    open(a.wan_ip_file, "w").close()
        except Exception as e:  # noqa: BLE001
            print(f"[opnsense-import] FAILED: {e}", file=sys.stderr)
            con.close()
            return 1
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
