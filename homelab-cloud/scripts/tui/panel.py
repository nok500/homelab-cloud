#!/usr/bin/env python3
"""One box of the lab TUI (scripts/tui.sh). Redraws in place until killed.

    panel.py status|host|vms|pods|nodes

Standard library only. Every data source can be missing (lab not built, half-built, host down): a box then
says what it's waiting for instead of crashing, so the TUI can run through a whole `make up`.
"""
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = os.environ.get("LAB_SSH_HOST", "macpro")
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
       "-o", "ControlMaster=auto", "-o", f"ControlPath={ROOT}/.cache/ssh/%C", "-o", "ControlPersist=120", HOST]

R, G, Y, B, D, BOLD, X = "\033[31m", "\033[32m", "\033[33m", "\033[34m", "\033[2m", "\033[1m", "\033[0m"
ANSI = re.compile(r"\033\[[0-9;]*m")


# ---------------------------------------------------------------- helpers
def run(cmd, timeout=8):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return 1, "", str(e)


def kget(*args, timeout=6):
    """kubectl get ... -o json -> dict, or None (no kubeconfig, API down, CRD not there yet)."""
    if not os.path.exists(os.environ.get("KUBECONFIG", "")):
        return None
    rc, out, _ = run(["kubectl", "get", *args, "-o", "json", "--request-timeout=4s"], timeout)
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def cond(obj, ctype):
    for c in obj.get("status", {}).get("conditions", []) or []:
        if c.get("type") == ctype:
            return c.get("status")
    return None


def vlen(s):
    return len(ANSI.sub("", s))


def clip(s, width):
    """Cut a string with ANSI codes to `width` visible characters."""
    if vlen(s) <= width:
        return s
    out, n, i = [], 0, 0
    while i < len(s) and n < width - 1:
        m = ANSI.match(s, i)
        if m:
            out.append(m.group())
            i = m.end()
            continue
        out.append(s[i])
        n += 1
        i += 1
    return "".join(out) + "…" + X


def bar(frac, width=20):
    frac = max(0.0, min(1.0, frac))
    n = round(frac * width)
    col = R if frac >= 0.9 else Y if frac >= 0.75 else G
    return f"{col}{'■' * n}{D}{'·' * (width - n)}{X}"


def pct_col(p, warn=75, crit=90):
    return R if p >= crit else Y if p >= warn else G


def gib(b):
    return f"{b / 2**30:.1f}"


def age(ts):
    if not ts:
        return "?"
    s = (datetime.now(timezone.utc) - datetime.fromisoformat(ts.replace("Z", "+00:00"))).total_seconds()
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if s >= n:
            return f"{int(s // n)}{unit}"
    return f"{int(s)}s"


def cpu_m(q):
    q = str(q)
    return float(q[:-1]) if q.endswith("m") else float(q) * 1000


def mem_b(q):
    q = str(q)
    units = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "k": 1e3, "M": 1e6, "G": 1e9}
    for u, f in units.items():
        if q.endswith(u):
            return float(q[: -len(u)]) * f
    return float(q)


def talos_nodes():
    """{name: {ip, role}} from terraform/host outputs, or {}."""
    rc, out, _ = run(["terraform", f"-chdir={ROOT}/terraform/host", "output", "-json", "talos_nodes"], 20)
    try:
        return json.loads(out) if rc == 0 else {}
    except ValueError:
        return {}


def draw(lines):
    cols, rows = shutil.get_terminal_size((80, 24))
    lines = lines[:rows]
    buf = "\033[H" + "".join(clip(line, cols) + X + "\033[K\n" for line in lines[:-1])
    if lines:
        buf += clip(lines[-1], cols) + X + "\033[K"
    sys.stdout.write(buf + "\033[J")
    sys.stdout.flush()


def stamp():
    return f"{D}{time.strftime('%H:%M:%S')}{X}"


# ---------------------------------------------------------------- status dots
def dot(state):
    return {"ok": f"{G}●{X}", "warn": f"{Y}●{X}", "bad": f"{R}●{X}"}.get(state, f"{D}○{X}")


def st_talos(nodes):
    if not nodes or not os.path.exists(os.environ.get("TALOSCONFIG", "")):
        return "none", "not built"
    ips = ",".join(v["ip"] for v in nodes.values())
    rc, out, _ = run(["talosctl", "-n", ips, "get", "machinestatus", "-o", "json"], 8)
    ready = len(re.findall(r'"ready":\s*true', out))
    if rc != 0 and ready == 0:
        return "bad", "API down"
    return ("ok" if ready == len(nodes) else "warn"), f"{ready}/{len(nodes)}"


def st_kube(_):
    n = kget("nodes")
    if n is None:
        return "bad" if os.path.exists(os.environ.get("KUBECONFIG", "")) else "none", "API down"
    ready = sum(cond(i, "Ready") == "True" for i in n["items"])
    total = len(n["items"])
    return ("ok" if total and ready == total else "warn"), f"{ready}/{total}"


def st_cilium(_):
    d = kget("-n", "kube-system", "ds/cilium", "deploy/cilium-operator")
    if d is None:
        return "none", "-"
    ok = True
    for i in d["items"]:
        s = i.get("status", {})
        if i["kind"] == "DaemonSet":
            ok &= s.get("numberReady", 0) == s.get("desiredNumberScheduled", -1)
        else:
            ok &= s.get("availableReplicas", 0) >= 1
    return ("ok" if ok and len(d["items"]) == 2 else "warn"), ""


def st_argocd(_):
    a = kget("-n", "argocd", "applications.argoproj.io")
    if a is None:
        return "none", "-"
    good = sum(i.get("status", {}).get("sync", {}).get("status") == "Synced"
               and i.get("status", {}).get("health", {}).get("status") == "Healthy" for i in a["items"])
    degraded = any(i.get("status", {}).get("health", {}).get("status") == "Degraded" for i in a["items"])
    total = len(a["items"])
    state = "ok" if total and good == total else "bad" if degraded else "warn"
    return state, f"{good}/{total}"


def st_gateway(_):
    g = kget("-n", "gateway", "gateway/lab")
    c = kget("-n", "gateway", "certificate/lab-wildcard")
    if g is None:
        return "none", "-"
    gw = cond(g, "Programmed") == "True"
    tls = c is not None and cond(c, "Ready") == "True"
    return ("ok" if gw and tls else "warn"), ("" if gw and tls else "no TLS" if gw else "not programmed")


def st_storage(_):
    d = kget("-n", "local-path-storage", "deploy/local-path-provisioner")
    s = kget("sc/local-path")
    if d is None:
        return "none", "-"
    up = d.get("status", {}).get("availableReplicas", 0) >= 1
    default = s is not None and s["metadata"].get("annotations", {}).get(
        "storageclass.kubernetes.io/is-default-class") == "true"
    return ("ok" if up and default else "warn"), ""


def st_secrets(_):
    p = kget("-n", "openbao", "pod/openbao-0")
    s = kget("clustersecretstore/openbao")
    e = kget("externalsecrets.external-secrets.io", "-A")
    if p is None:
        return "none", "-"
    bao = cond(p, "Ready") == "True"
    store = s is not None and cond(s, "Ready") == "True"
    es = e["items"] if e else []
    synced = sum(cond(i, "Ready") == "True" for i in es)
    ok = bao and store and synced == len(es)
    return ("ok" if ok else "warn"), (f"{synced}/{len(es)}" if es else "")


def st_databases(_):
    c = kget("-n", "databases", "clusters.postgresql.cnpg.io")
    if c is None or not c["items"]:
        return "none", "-"
    healthy = sum(i.get("status", {}).get("phase") == "Cluster in healthy state" for i in c["items"])
    archiving = all(cond(i, "ContinuousArchiving") == "True" for i in c["items"])
    total = len(c["items"])
    return ("ok" if healthy == total and archiving else "warn"), f"{healthy}/{total}" + ("" if archiving else " no WAL archive")


CHECKS = [("talos", st_talos), ("kubernetes", st_kube), ("cilium", st_cilium), ("argocd", st_argocd),
          ("gateway", st_gateway), ("storage", st_storage), ("secrets", st_secrets),
          ("databases", st_databases)]


def panel_status():
    nodes, nodes_at = {}, 0
    with cf.ThreadPoolExecutor(len(CHECKS)) as ex:
        while True:
            if not nodes or time.time() - nodes_at > 60:
                nodes, nodes_at = talos_nodes(), time.time()
            res = list(ex.map(lambda c: c[1](nodes), CHECKS))
            parts = [f"{dot(s)} {name}{(' ' + D + d + X) if d else ''}" for (name, _), (s, d) in zip(CHECKS, res)]
            draw(["  ".join(parts) + f"   {stamp()}"])
            time.sleep(10)


# ---------------------------------------------------------------- host: CPU | RAM | TEMP
HOST_CMD = ("head -1 /proc/stat; sleep 1; head -1 /proc/stat; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo;"
            " cat /proc/loadavg; nproc; echo @@SENSORS@@; sensors -j 2>/dev/null")


def panel_host():
    while True:
        rc, out, err = run(SSH + [HOST_CMD], 15)
        if rc != 0:
            draw([f"{R}● {HOST} unreachable{X} {D}{(err.strip().splitlines() or [''])[-1][:60]}{X}", "",
                  f"{D}check: ping 192.168.8.207 (docs/runbooks/opnsense.md § Connectivity loss){X}"])
            time.sleep(5)
            continue
        head, _, sens = out.partition("@@SENSORS@@\n")
        L = head.splitlines()
        a, b = [list(map(int, x.split()[1:])) for x in L[0:2]]
        idle = (b[3] + b[4]) - (a[3] + a[4])
        tot = sum(b) - sum(a)
        cpu = 1 - idle / tot if tot else 0
        mem = {k.rstrip(":"): int(v) * 1024 for k, v, *_ in (x.split() for x in L[2:4])}
        used = mem["MemTotal"] - mem["MemAvailable"]
        load = " ".join(L[4].split()[:3])
        threads = L[5].strip()
        pkg, cores, fan = None, [], None
        try:
            s = json.loads(sens)
            for chip, feats in s.items():
                for fname, f in feats.items():
                    if not isinstance(f, dict):
                        continue
                    val = next((v for k, v in f.items() if k.endswith("_input")), None)
                    if chip.startswith("coretemp") and fname.startswith("Package"):
                        pkg = val
                    elif chip.startswith("coretemp") and fname.startswith("Core"):
                        cores.append(val)
                    elif chip.startswith("applesmc") and fname.strip() == "Main" and val is not None:
                        fan = val
        except ValueError:
            pass
        hot = max([t for t in [pkg, *cores] if t is not None], default=None)
        tcol = R if hot and hot >= 80 else Y if hot and hot >= 70 else G
        temp = (f"pkg {tcol}{pkg:.0f}°C{X}  hottest core {tcol}{hot:.0f}°C{X}" if pkg is not None
                else f"{D}no sensors{X}")
        fan_s = f"  fan {fan:.0f} rpm" if fan else ""
        draw([
            f"{BOLD}CPU {X} {bar(cpu)} {pct_col(cpu * 100)}{cpu * 100:3.0f}%{X}  load {load}  {D}({threads} threads){X}",
            f"{BOLD}RAM {X} {bar(used / mem['MemTotal'])} {gib(used)}/{gib(mem['MemTotal'])} GiB"
            f"  {D}free for VMs ≈ {gib(mem['MemAvailable'] - 4 * 2**30)} GiB above the 4 GiB host reserve{X}",
            f"{BOLD}TEMP{X} {temp}{fan_s}",
            f"{D}{HOST}  {stamp()}{X}",
        ])
        time.sleep(2)


# ---------------------------------------------------------------- QEMU VMs
VM_CMD = ("nproc; grep MemTotal /proc/meminfo; virsh -c qemu:///system domstats --state --cpu-total --balloon "
          "--vcpu 2>/dev/null | grep -E \"^Domain|state.state=|cpu.time=|balloon.(maximum|rss)=|vcpu.current=\"")
STATES = {"0": ("no state", D), "1": ("running", G), "2": ("blocked", Y), "3": ("paused", Y),
          "4": ("stopping", Y), "5": ("shut off", D), "6": ("crashed", R), "7": ("suspended", Y)}


def panel_vms():
    prev = {}
    while True:
        rc, out, err = run(SSH + [VM_CMD], 10)
        if rc != 0:
            draw([f"{R}● {HOST} unreachable{X}", f"{D}{(err.strip().splitlines() or [''])[-1][:70]}{X}"])
            time.sleep(5)
            continue
        L = out.splitlines()
        threads, host_mem = int(L[0]), int(L[1].split()[1]) * 1024
        doms, cur = {}, None
        for line in L[2:]:
            m = re.match(r"Domain: '(.+)'", line)
            if m:
                cur = doms.setdefault(m.group(1), {})
            elif cur is not None and "=" in line:
                k, v = line.strip().split("=", 1)
                cur[k] = v
        now = time.time()
        rows = [f"{BOLD}{'VM':<16}{'STATE':<10}{'vCPU':>5}{'CPU':>6}  {'RSS / RAM':<16}{X}"]
        tot_cpu = tot_mem = 0
        for name in sorted(doms, key=lambda n: (n != "opnsense", n)):
            d = doms[name]
            st, col = STATES.get(d.get("state.state", "0"), ("?", D))
            vcpu = int(d.get("vcpu.current", 0) or 0)
            mx = int(d.get("balloon.maximum", 0) or 0) * 1024
            rss = int(d.get("balloon.rss", 0) or 0) * 1024
            t = int(d.get("cpu.time", 0) or 0)
            pt, pts = prev.get(name, (None, None))
            cpu = f"{(t - pt) / ((now - pts) * 1e9) / max(vcpu, 1) * 100:4.0f}%" if pt is not None and st == "running" else "    -"
            prev[name] = (t, now)
            if st == "running":
                tot_cpu += vcpu
                tot_mem += mx
            mem = f"{gib(rss)} / {gib(mx)} GiB" if st == "running" else f"    - / {gib(mx)} GiB"
            rows.append(f"{name:<16}{col}{st:<10}{X}{vcpu:>5}{cpu:>6}  {mem}")
        if not doms:
            rows.append(f"{D}no VMs defined (make up){X}")
        free_t, free_m = threads - tot_cpu, host_mem - tot_mem
        col = G if free_t >= 2 and free_m >= 4 * 2**30 else R
        rows.append(f"{D}allocated {tot_cpu}/{threads} vCPU, {gib(tot_mem)}/{gib(host_mem)} GiB → host keeps "
                    f"{X}{col}{free_t} threads, {gib(free_m)} GiB{X}{D} (min 2 / 4){X}")
        draw(rows)
        time.sleep(3)


# ---------------------------------------------------------------- PODS
def pod_status(p):
    if p["metadata"].get("deletionTimestamp"):
        return "Terminating"
    st = p.get("status", {})
    for cs in (st.get("initContainerStatuses") or []):
        w = cs.get("state", {}).get("waiting")
        if w:
            return f"Init:{w.get('reason', 'Waiting')}"
    for cs in (st.get("containerStatuses") or []):
        w = cs.get("state", {}).get("waiting")
        if w:
            return w.get("reason", "Waiting")
        t = cs.get("state", {}).get("terminated")
        if t and st.get("phase") != "Succeeded":
            return t.get("reason", "Terminated")
    return st.get("phase", "Unknown")


def panel_pods():
    while True:
        p = kget("pods", "-A")
        if p is None:
            draw([f"{D}waiting for the Kubernetes API…{X}", f"{D}{stamp()}{X}"])
            time.sleep(5)
            continue
        rows = []
        for i in p["items"]:
            cs = i.get("status", {}).get("containerStatuses") or []
            ready = sum(c.get("ready", False) for c in cs)
            restarts = sum(c.get("restartCount", 0) for c in cs)
            status = pod_status(i)
            done = status in ("Succeeded", "Completed")
            healthy = done or (status == "Running" and ready == len(cs) and cs)
            rows.append((0 if not healthy else 2 if done else 1, i["metadata"]["namespace"], i["metadata"]["name"],
                         f"{ready}/{len(cs)}", status, restarts, age(i["metadata"].get("creationTimestamp")),
                         (i.get("spec", {}).get("nodeName") or "-").replace("talos-", "")))
        rows.sort()
        bad = sum(r[0] == 0 for r in rows)
        nsw = min(max((len(r[1]) for r in rows), default=9), 18) + 1
        _, height = shutil.get_terminal_size((80, 24))
        head = (f"{BOLD}{len(rows)} pods{X}  {G}{sum(r[0] == 1 for r in rows)} running{X}  "
                f"{(R if bad else D)}{bad} not ready{X}  {D}{sum(r[0] == 2 for r in rows)} completed   {stamp()}{X}")
        lines = [head, f"{BOLD}{'NAMESPACE':<{nsw}}{'NAME':<44}{'READY':<6}{'STATUS':<22}{'RST':>4} {'AGE':>5}  NODE{X}"]
        room = height - len(lines)
        shown = rows if len(rows) <= room else rows[: room - 1]
        for kind, ns, name, ready, status, rst, ag, node in shown:
            col = R if kind == 0 and status not in ("Pending", "ContainerCreating", "PodInitializing") else \
                Y if kind == 0 else D if kind == 2 else ""
            rcol = Y if rst else D
            lines.append(f"{ns[:nsw - 1]:<{nsw}}{name[:43]:<44}{ready:<6}{col}{status[:21]:<22}{X}{rcol}{rst:>4}{X} "
                         f"{ag:>5}  {D}{node}{X}")
        if len(shown) < len(rows):
            lines.append(f"{D}… {len(rows) - len(shown)} more (healthy ones are listed last){X}")
        draw(lines)
        time.sleep(3)


# ---------------------------------------------------------------- NODES
def panel_nodes():
    while True:
        n = kget("nodes")
        p = kget("pods", "-A", "--field-selector=status.phase!=Succeeded,status.phase!=Failed")
        if n is None:
            draw([f"{D}waiting for the Kubernetes API…{X}"])
            time.sleep(5)
            continue
        req = {}
        for i in (p or {}).get("items", []):
            node = i.get("spec", {}).get("nodeName")
            if not node:
                continue
            r = req.setdefault(node, [0, 0.0, 0.0])
            r[0] += 1
            for c in i["spec"].get("containers", []):
                rq = c.get("resources", {}).get("requests", {})
                r[1] += cpu_m(rq.get("cpu", 0))
                r[2] += mem_b(rq.get("memory", 0))
        lines = []
        for i in sorted(n["items"], key=lambda x: x["metadata"]["name"]):
            name = i["metadata"]["name"]
            ready = cond(i, "Ready") == "True"
            role = "cp" if "node-role.kubernetes.io/control-plane" in i["metadata"].get("labels", {}) else "worker"
            ip = next((a["address"] for a in i["status"].get("addresses", []) if a["type"] == "InternalIP"), "?")
            cordon = f" {Y}cordoned{X}" if i["spec"].get("unschedulable") else ""
            alloc = i["status"].get("allocatable", {})
            pods, c, m = req.get(name, [0, 0, 0])
            cp = c / cpu_m(alloc.get("cpu", "1")) * 100
            mp = m / mem_b(alloc.get("memory", "1")) * 100
            pressure = [x["type"].replace("Pressure", "") for x in i["status"].get("conditions", [])
                        if x["type"].endswith("Pressure") and x["status"] == "True"]
            press = f" {R}{','.join(pressure)} pressure{X}" if pressure else ""
            lines += [f"{G + '●' if ready else R + '●'}{X} {BOLD}{name}{X} {D}{role} {ip}{X}{cordon}{press}",
                      f"  {D}pods{X} {pods:<3} {D}req cpu{X} {pct_col(cp)}{cp:3.0f}%{X} {D}mem{X} {pct_col(mp)}{mp:3.0f}%{X}"
                      f"  {D}{i['status'].get('nodeInfo', {}).get('kubeletVersion', '')} {age(i['metadata'].get('creationTimestamp'))}{X}",
                      ""]
        if not lines:
            lines = [f"{D}no nodes registered yet{X}"]
        lines.append(f"{D}req = resource requests / allocatable{X}")
        draw(lines)
        time.sleep(5)


PANELS = {"status": panel_status, "host": panel_host, "vms": panel_vms, "pods": panel_pods, "nodes": panel_nodes}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in PANELS:
        sys.exit(f"usage: {sys.argv[0]} {'|'.join(PANELS)}")
    os.makedirs(f"{ROOT}/.cache/ssh", mode=0o700, exist_ok=True)
    # always the lab's own configs, never an inherited ~/.kube/config or ~/.talos/config
    os.environ["KUBECONFIG"] = f"{ROOT}/.cache/cluster/kubeconfig"
    os.environ["TALOSCONFIG"] = f"{ROOT}/.cache/cluster/talosconfig"
    os.environ["PATH"] = f"{ROOT}/.tools/bin:" + os.environ["PATH"]
    sys.stdout.write("\033[?25l\033[2J")  # hide cursor, clear
    try:
        PANELS[sys.argv[1]]()
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write("\033[?25h")
