#!/usr/bin/env python3
"""End-to-end install test for pig entries.

Each entry is installed into its own isolated HOME via the real pig.py, so
this exercises download -> type detection -> extraction -> executable pick
-> launcher, exactly like a user run.
"""
import concurrent.futures as cf
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent
PIG = REPO / "pig.py"


def parse_dict(path):
    out = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "::" not in line:
            continue
        n, _, u = line.partition("::")
        out.append((n.strip(), u.strip()))
    return out


def test_entry(name, url, workroot, keep=False):
    home = Path(workroot) / name
    home.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["HOME"] = str(home)
    env.pop("SUDO_USER", None)
    env["XDG_CACHE_HOME"] = str(home / ".cache")
    env["PATH"] = f"{home}/.local/bin:" + env.get("PATH", "")
    dictf = home / "dict.txt"
    dictf.write_text(f"{name}::{url}\n", encoding="utf-8")
    cfgdir = home / ".config" / "pig"
    cfgdir.mkdir(parents=True, exist_ok=True)
    (cfgdir / "config.toml").write_text(
        f'[sources]\ntest = "{dictf}"\n', encoding="utf-8")
    t0 = time.time()
    # .sh entries are vendor installers that would touch the real system
    # (apt/dnf/systemd); only check that they download and carry a shebang.
    if url.lower().endswith(".sh") or "type=Linux" in url:
        return sh_probe(name, url, env, t0)
    try:
        r = subprocess.run([sys.executable, str(PIG), "install", "-y", name],
                           env=env, capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return {"name": name, "ok": False, "why": "timeout", "sec": time.time() - t0}
    dt = time.time() - t0
    rec = {"name": name, "url": url, "rc": r.returncode, "sec": round(dt, 1),
           "out": (r.stdout + r.stderr).strip().splitlines()}
    if r.returncode == 0:
        rec["ok"] = True
        rec["why"] = ""
        exe = home / ".local" / "opt" / name
        link = home / ".local" / "bin" / name
        rec["installed"] = exe.exists()
        rec["launcher"] = link.is_symlink()
        rec["exe"] = json.loads(
            (home / ".cache" / "pig" / "installed.json").read_text()
        ).get(name, {}).get("exe", "?")
    else:
        rec["ok"] = False
        lines = [l for l in rec["out"] if "error" in l]
        rec["why"] = lines[-1] if lines else (rec["out"][-1] if rec["out"] else "?")
    if not keep:
        shutil.rmtree(home, ignore_errors=True)
    return rec


def sh_probe(name, url, env, t0):
    """Download a .sh entry and verify it is a script with a shebang.

    It is not executed: these installers write to /opt, call apt/dnf or
    modify the shell, which has no place in a link test.
    """
    import urllib.error
    import urllib.request
    tmp = Path(tempfile.mkdtemp(prefix="shprobe-"))
    dst = tmp / (name + ".sh")
    req = urllib.request.Request(
        url, headers={"User-Agent": "pig/1.1.0"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            head = r.read(2)
            size = r.headers.get("Content-Length", "?")
            ctype = r.headers.get("Content-Type", "")
    except Exception as e:
        shutil.rmtree(tmp, ignore_errors=True)
        return {"name": name, "ok": False, "why": f"{type(e).__name__}: {e}",
                "sec": round(time.time() - t0, 1)}
    shutil.rmtree(tmp, ignore_errors=True)
    ok = head == b"#!"
    return {"name": name, "ok": ok,
            "why": "" if ok else "no shebang (not a script)",
            "sec": round(time.time() - t0, 1),
            "out": [f"downloaded {size} bytes, {ctype}"]}


def main():
    dicts = sys.argv[1:] or ["pig.txt"]
    jobs = []
    for d in dicts:
        jobs.extend(parse_dict(REPO / d if not Path(d).is_absolute() else d))
    workroot = tempfile.mkdtemp(prefix="pigtest-")
    print(f"testing {len(jobs)} entries from {dicts}\n")
    results = []
    with cf.ThreadPoolExecutor(max_workers=3) as ex:
        futs = {ex.submit(test_entry, n, u, workroot): n for n, u in jobs}
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            mark = "OK  " if r["ok"] else "FAIL"
            print(f"[{mark}] {r['name']:20} {r.get('sec',''):>6}s  "
                  f"{r.get('why','')}", flush=True)
            if not r["ok"]:
                for l in r.get("out", [])[-4:]:
                    print(f"          | {l}", flush=True)
    print("\n=== summary ===")
    ok = [r for r in results if r["ok"]]
    bad = [r for r in results if not r["ok"]]
    print(f"ok: {len(ok)}/{len(results)}")
    for r in sorted(bad, key=lambda x: x["name"]):
        print(f"  FAIL {r['name']:20} {r['why']}")
    shutil.rmtree(workroot, ignore_errors=True)
    Path("/tmp/opencode/results.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()