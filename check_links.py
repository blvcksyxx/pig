#!/usr/bin/env python3
"""Check dictionary entries: aliveness, redirect target and real file type.

Usage: python3 check_links.py [dict.txt ...]   (default: pig.txt)
Reports what pig would detect, so a dead or mistyped url shows up here
rather than during an install.
"""
import concurrent.futures as cf
import sys
import urllib.error
import urllib.parse
import urllib.request

VERSION = "1.1.0"
TIMEOUT = 25


def parse_dict(path):
    out = []
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#") or "::" not in line:
            continue
        n, _, u = line.partition("::")
        out.append((n.strip(), u.strip()))
    return out


def detect_type(url):
    p = urllib.parse.urlsplit(url).path.lower()
    for ext, t in ((".deb", "deb"), (".tar.gz", "tar.gz"), (".tgz", "tar.gz"),
                   (".tar.xz", "tar.xz"), (".txz", "tar.xz"), (".sh", "sh")):
        if p.endswith(ext):
            return t
    return "unknown"


def sniff(head, ctype, cd):
    if head[:2] == b"\x1f\x8b":
        return "tar.gz"
    if head[:6] == b"\xfd7zXZ\x00":
        return "tar.xz"
    if head == b"!<arch>\n":
        return "deb"
    if head[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    if head[:2] == b"#!":
        return "sh"
    if head[:4] == b"\x7fELF":
        return "elf"
    c = (ctype or "").lower()
    if "zip" in c:
        return "zip"
    if "gzip" in c:
        return "gzip"
    if "x-zstd" in c or "zstd" in c:
        return "zstd"
    if "html" in c:
        return "html"
    if "x-sh" in c or "javascript" in c or "plain" in c:
        return "text"
    if "executable" in c:
        return "binary"
    return "?"


def check(item):
    name, url = item
    guess = detect_type(url)
    rec = {"name": name, "url": url, "guess": guess, "ok": False}
    req = urllib.request.Request(url, headers={
        "User-Agent": f"pig/{VERSION}", "Range": "bytes=0-65535"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            head = r.read(65536)
            rec["ok"] = 200 <= r.status < 400
            rec["status"] = r.status
            rec["final"] = r.geturl()
            rec["ctype"] = r.headers.get("Content-Type", "")
            rec["cd"] = r.headers.get("Content-Disposition", "") or ""
            rec["clen"] = r.headers.get("Content-Length", "")
            rec["real"] = sniff(head, rec["ctype"], rec["cd"])
            rec["size"] = len(head)
    except urllib.error.HTTPError as e:
        rec["status"] = e.code
        rec["err"] = f"HTTP {e.code} {e.reason}"
    except urllib.error.URLError as e:
        rec["err"] = f"{type(e.reason).__name__}: {e.reason}"
    except Exception as e:
        rec["err"] = f"{type(e).__name__}: {e}"
    # what would pig finally decide?
    if rec.get("ok"):
        t = guess
        if t == "unknown":
            t = detect_type(rec.get("final", ""))
            if t == "unknown" and rec.get("cd"):
                m = rec["cd"]
                t = detect_type(m)
            if t == "unknown":
                t = rec.get("real", "?")
        rec["pig_type"] = t
    return rec


def main():
    entries = parse_dict(sys.argv[1] if len(sys.argv) > 1 else "pig.txt")
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        recs = list(ex.map(check, entries))
    bad = []
    mism = []
    print(f"{'name':22} {'pig-type':9} {'real':8} {'http':5} url")
    print("-" * 100)
    for r in recs:
        pt = r.get("pig_type", "-")
        rl = r.get("real", "-")
        st = str(r.get("status", "-"))
        if not r["ok"]:
            bad.append(r)
            print(f"{r['name']:22} {'FAIL':9} {'-':8} {st:5} {r.get('err','')}")
            print(f"{'':22} {r['url']}")
            continue
        flag = ""
        if pt != rl and rl not in ("?", "text", "html"):
            flag = "  <-- MISMATCH"
            mism.append(r)
        if pt not in ("deb", "tar.gz", "tar.xz", "sh"):
            flag += "  <-- UNSUPPORTED BY PIG"
        print(f"{r['name']:22} {pt:9} {rl:8} {st:5} {r['final'][:58]}{flag}")
    print()
    print(f"total: {len(recs)}   dead: {len(bad)}   type-mismatch: {len(mism)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())