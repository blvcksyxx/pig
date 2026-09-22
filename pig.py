#!/usr/bin/env python3
"""pig - minimal package manager for linux (stdlib only).

Copyright (c) 2026 @blvcksyxx (https://github.com/blvcksyxx/pig)
Licensed under PolyForm Noncommercial 1.0.0 (see LICENSE).

Usage:
    pig install [-y] <name>
    pig remove [-y] <name>
    pig search <query>
    pig list
    pig installed
    pig info <name>
    pig update
    pig upgrade [-y]
    pig clean
    pig config
    pig doctor
"""
import argparse
import errno
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "1.1.0"
OFFICIAL_DICT_URL = "https://github.com/blvcksyxx/pig/raw/refs/heads/main/pig.txt"
OFFICIAL_PIG_URL = "https://github.com/blvcksyxx/pig/raw/refs/heads/main/pig.py"
TIMEOUT = 20


class PigError(Exception):
    pass


# ---------- paths ----------

def real_home() -> Path:
    """User home, predictable even under sudo (use SUDO_USER env)."""
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        try:
            import pwd
            return Path(pwd.getpwnam(sudo_user).pw_dir)
        except Exception:
            p = Path("/home") / sudo_user
            if p.exists():
                return p
    return Path.home()


def config_path() -> Path:
    return real_home() / ".config" / "pig" / "config.toml"


def cache_dir() -> Path:
    return real_home() / ".cache" / "pig"


def dicts_cache_dir() -> Path:
    return cache_dir() / "dicts"


def installed_path() -> Path:
    return cache_dir() / "installed.json"


def opt_base() -> Path:
    return real_home() / ".local" / "opt"


def bin_dir() -> Path:
    return real_home() / ".local" / "bin"


def _fix_owner(path: Path):
    """Best effort: when running under sudo, keep files owned by the user."""
    sudo_user = os.environ.get("SUDO_USER")
    if not sudo_user or os.geteuid() != 0:
        return
    try:
        import pwd
        pw = pwd.getpwnam(sudo_user)
        for p in [path] + list(path.rglob("*")) if path.is_dir() else [path]:
            try:
                os.chown(p, pw.pw_uid, pw.pw_gid)
            except OSError:
                pass
    except Exception:
        pass


def ensure_dirs():
    cache_dir().mkdir(parents=True, exist_ok=True)
    dicts_cache_dir().mkdir(parents=True, exist_ok=True)
    config_path().parent.mkdir(parents=True, exist_ok=True)
    _fix_owner(cache_dir())
    _fix_owner(config_path().parent)


# ---------- output ----------

def info(msg: str):
    print(f"[pig] {msg}")


def err(msg: str):
    sys.stdout.flush()
    print(f"[pig] error: {msg}", file=sys.stderr, flush=True)


# ---------- distro ----------

# Full support: .deb via dpkg plus archives and shell installers.
_FULL_DISTROS = frozenset({
    "debian", "ubuntu", "linuxmint", "kali", "pop", "zorin", "mx",
    "raspbian", "elementary", "parrot", "pureos", "devuan", "deepin",
})
_FULL_LIKES = frozenset({"debian", "ubuntu"})
# Partial support: archives and shell installers only (no dpkg).
_PARTIAL_DISTROS = frozenset({
    "arch", "manjaro", "endeavouros", "garuda", "fedora", "rhel",
    "centos", "almalinux", "rocky", "ol", "opensuse-leap",
    "opensuse-tumbleweed", "opensuse", "gentoo", "alpine", "void",
    "nixos", "slackware",
})
_PARTIAL_LIKES = frozenset({"arch", "fedora", "rhel", "centos", "suse",
                            "gentoo", "alpine"})


def _os_release_path() -> Path:
    # PIG_OS_RELEASE override exists for tests.
    return Path(os.environ.get("PIG_OS_RELEASE", "/etc/os-release"))


def detect_distro() -> dict:
    """Parse /etc/os-release. Unknown fields become 'unknown'."""
    out = {"id": "unknown", "name": "unknown", "version": "unknown",
           "like": "", "pretty": "unknown"}
    try:
        text = _os_release_path().read_text(encoding="utf-8")
    except OSError:
        return out
    for raw in text.splitlines():
        if "=" not in raw:
            continue
        k, _, v = raw.partition("=")
        v = v.strip().strip('"').strip("'")
        if k == "ID":
            out["id"] = v.lower() or "unknown"
        elif k == "NAME":
            out["name"] = v or "unknown"
        elif k == "VERSION_ID":
            out["version"] = v or "unknown"
        elif k == "ID_LIKE":
            out["like"] = v.lower()
        elif k == "PRETTY_NAME":
            out["pretty"] = v or "unknown"
    return out


def distro_tier(distro: dict) -> str:
    """full | partial | unknown (see DISTROS.md)."""
    did = distro.get("id", "unknown")
    likes = set(distro.get("like", "").split())
    if did in _FULL_DISTROS or likes & _FULL_LIKES:
        return "full"
    if did in _PARTIAL_DISTROS or likes & _PARTIAL_LIKES:
        return "partial"
    return "unknown"


def cmd_doctor():
    d = detect_distro()
    tier = distro_tier(d)
    has_dpkg = shutil.which("dpkg") is not None
    print(f"distro: {d['pretty']} ({d['id']})")
    if tier == "full" and not has_dpkg:
        print("support: full (.deb unavailable: no dpkg)")
    elif tier == "full":
        print("support: full (.deb, archives, shell)")
    elif tier == "partial":
        print("support: partial (archives, shell; no dpkg)")
    else:
        print("support: unknown (see DISTROS.md; install with --force at your own risk)")
    print(f"python: {sys.version.split()[0]}")
    tools = []
    for t in ("dpkg", "dpkg-deb", "sudo"):
        tools.append(f"{t} {'ok' if shutil.which(t) else 'missing'}")
    print("tools: " + ", ".join(tools))
    cp = config_path()
    print(f"config: {cp} ({'present' if cp.exists() else 'missing'})")
    bd = bin_dir()
    in_path = str(bd) in os.environ.get("PATH", "").split(os.pathsep)
    print(f"bin: {bd} ({'in PATH' if in_path else 'NOT in PATH'})")
    return 0 if tier != "unknown" else 1


# ---------- config ----------

DEFAULT_CONFIG = '[sources]\nofficial = "%s"\n' % OFFICIAL_DICT_URL


def _toml_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def ensure_config() -> Path:
    ensure_dirs()
    cp = config_path()
    if not cp.exists():
        cp.write_text(DEFAULT_CONFIG, encoding="utf-8")
        _fix_owner(cp)
        info(f"created default config at {cp}")
    return cp


def _parse_sources_manual(text: str):
    """Minimal fallback TOML parser for our config shape.

    Supports:
        [sources]
        name = "url"
    and:
        [[sources]]
        name = "official"
        url = "..."   (or path = "...")
    """
    sources = []
    mode = None  # 'table' | 'list' | None
    current = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line == "[sources]":
            if current:
                sources.append(current)
                current = {}
            mode = "table"
            continue
        if line == "[[sources]]":
            if current:
                sources.append(current)
            current = {}
            mode = "list"
            continue
        if line.startswith("["):
            if current:
                sources.append(current)
                current = {}
            mode = None
            continue
        if "=" not in line or mode is None:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        v = v.strip()
        if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            v = v[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        elif len(v) >= 2 and v[0] == "'" and v[-1] == "'":
            v = v[1:-1]
        else:
            # unquoted (local path without quotes) - accept as is
            v = v.strip().strip('"').strip("'")
        if not v:
            continue
        if mode == "table":
            if k:
                sources.append({"name": k, "url": v})
        elif mode == "list":
            current[k] = v
    if current:
        sources.append(current)
    # normalize [[sources]] entries: {name, url|path}
    norm = []
    for s in sources:
        if "name" in s and ("url" in s or "path" in s):
            norm.append({"name": s["name"], "url": s.get("url") or s.get("path")})
        elif "name" in s and "url" in s:
            norm.append(s)
        elif "name" in s and len(s) == 2:
            # generic: name + single value already handled above; keep table entries as is
            norm.append(s)
        else:
            # [sources] table entries arrive as single-key dicts? handled below
            norm.append(s)
    # [sources] table entries were appended as {"name":..., "url":...} already
    return norm


def load_sources():
    """Return ordered list of {'name':..., 'url':...}. Creates default config if missing."""
    ensure_config()
    cp = config_path()
    try:
        text = cp.read_text(encoding="utf-8")
    except OSError as e:
        raise PigError(f"cannot read config {cp}: {e}")
    sources = []
    try:
        import tomllib  # python 3.11+
        try:
            data = tomllib.loads(text)
        except Exception as e:
            raise PigError(f"bad config {cp}: {e}")
        raw = data.get("sources", None)
        if raw is None:
            raise PigError(f"bad config {cp}: missing [sources]")
        if isinstance(raw, dict):
            for k, v in raw.items():
                if isinstance(v, str) and v.strip():
                    sources.append({"name": str(k), "url": v.strip()})
        elif isinstance(raw, list):
            for item in raw:
                if not isinstance(item, dict):
                    continue
                name = item.get("name")
                url = item.get("url", item.get("path"))
                if name and url:
                    sources.append({"name": str(name), "url": str(url).strip()})
        else:
            raise PigError(f"bad config {cp}: invalid [sources]")
    except ImportError:
        # old python without tomllib: manual parse
        for s in _parse_sources_manual(text):
            if "name" in s and "url" in s and s["name"] and s["url"]:
                sources.append({"name": str(s["name"]), "url": str(s["url"]).strip()})
    # dedupe by name, keep first
    seen = set()
    uniq = []
    for s in sources:
        if s["name"] in seen:
            continue
        seen.add(s["name"])
        uniq.append(s)
    if not uniq:
        raise PigError(f"bad config {cp}: no sources defined")
    return uniq


def save_sources(sources) -> None:
    ensure_dirs()
    lines = ["[sources]"]
    for s in sources:
        lines.append(f'{s["name"]} = "{_toml_escape(s["url"])}"')
    config_path().write_text("\n".join(lines) + "\n", encoding="utf-8")
    _fix_owner(config_path())


# ---------- dictionaries ----------

def parse_dict_text(text: str) -> dict:
    """Parse 'name::url' dictionary. Skips blanks, comments, bad lines, dupes (first wins)."""
    entries = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            continue
        if "::" not in line:
            continue
        name, _, url = line.partition("::")
        name = name.strip()
        url = url.strip()
        if not name or not url:
            continue
        if " " in name or "\t" in name:
            continue
        if name in entries:
            continue
        entries[name] = url
    return entries


def is_remote(url: str) -> bool:
    u = url.strip().lower()
    return u.startswith("http://") or u.startswith("https://")


def strip_file_scheme(url: str) -> str:
    if url.startswith("file://"):
        return urllib.parse.unquote(url[7:])
    return url


def _cache_file_for(source_name: str) -> Path:
    safe = "".join(c if (c.isalnum() or c in "-_") else "_" for c in source_name).strip("_") or "dict"
    return dicts_cache_dir() / (safe + ".txt")


def fetch_text(url: str, timeout: int = TIMEOUT) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": f"pig/{VERSION}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raise PigError(f"download failed ({e.code} {e.reason}) for {url}")
    except urllib.error.URLError as e:
        raise PigError(f"network error for {url}: {e.reason}")
    except TimeoutError:
        raise PigError(f"timeout for {url}")
    except OSError as e:
        raise PigError(f"network error for {url}: {e}")
    try:
        return raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise PigError(f"bad dictionary encoding for {url} (expected utf-8)")


def load_dict_text(source: dict, use_cache_fallback: bool = True) -> str:
    url = source["url"]
    if not is_remote(url):
        path = Path(os.path.expanduser(strip_file_scheme(url)))
        if not path.is_absolute():
            path = (Path.cwd() / path).resolve()
        try:
            return path.read_text(encoding="utf-8")
        except FileNotFoundError:
            raise PigError(f"source '{source['name']}': file not found: {path}")
        except OSError as e:
            raise PigError(f"source '{source['name']}': cannot read {path}: {e}")
    # remote
    try:
        text = fetch_text(url)
    except PigError as e:
        if use_cache_fallback:
            cf = _cache_file_for(source["name"])
            if cf.exists():
                info(f"warning: {e}; using cached '{source['name']}'")
                try:
                    return cf.read_text(encoding="utf-8")
                except OSError:
                    pass
        raise
    # refresh cache best effort
    try:
        ensure_dirs()
        _cache_file_for(source["name"]).write_text(text, encoding="utf-8")
    except OSError:
        pass
    return text


def load_all_dicts():
    """Return (by_source, errors). by_source: {name: (url, entries)}."""
    sources = load_sources()
    by_source = {}
    errors = []
    for s in sources:
        try:
            text = load_dict_text(s, use_cache_fallback=True)
            by_source[s["name"]] = (s["url"], parse_dict_text(text))
        except PigError as e:
            errors.append(str(e))
    return by_source, errors


def find_package(name: str, by_source: dict):
    """Return list of (source_name, url) where exact key matches."""
    out = []
    for src, (_, entries) in by_source.items():
        if name in entries:
            out.append((src, entries[name]))
    return out


def choose_source(name: str, candidates) -> tuple:
    print(f"found {name} in:")
    for i, (src, _) in enumerate(candidates, 1):
        print(f"  {i}. {src}")
    try:
        raw = input(f"choose source [1-{len(candidates)}]: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        raise PigError("cancelled")
    if not raw.isdigit():
        raise PigError("invalid choice")
    n = int(raw)
    if n < 1 or n > len(candidates):
        raise PigError("invalid choice")
    return candidates[n - 1]


# ---------- installed db ----------

def load_installed() -> dict:
    p = installed_path()
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        raise PigError(f"bad {p}: {e}")
    if isinstance(data, dict) and "packages" in data and isinstance(data["packages"], dict):
        return data["packages"]
    if isinstance(data, dict):
        return data
    raise PigError(f"bad {p}: unexpected format")


def save_installed(pkgs: dict) -> None:
    ensure_dirs()
    installed_path().write_text(json.dumps(pkgs, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _fix_owner(installed_path())


# ---------- download / types ----------

def detect_type(url: str) -> str:
    path = urllib.parse.urlsplit(strip_file_scheme(url)).path.lower()
    if path.endswith(".deb"):
        return "deb"
    if path.endswith(".tar.gz") or path.endswith(".tgz"):
        return "tar.gz"
    if path.endswith(".tar.xz") or path.endswith(".txz"):
        return "tar.xz"
    if path.endswith(".sh"):
        return "sh"
    return "unknown"


def filename_from_url(url: str, fallback: str) -> str:
    if not is_remote(url):
        p = Path(strip_file_scheme(url))
        if p.name:
            return p.name
        return fallback
    path = urllib.parse.urlsplit(url).path
    base = os.path.basename(path.rstrip("/"))
    base = urllib.parse.unquote(base)
    if not base:
        return fallback
    return base


def _cd_filename(resp):
    """filename=... from Content-Disposition, or None."""
    cd = resp.headers.get("Content-Disposition", "") or ""
    m = re.search(r"filename\*?=(?:UTF-8''|\")?([^\";\r\n]+)", cd, re.IGNORECASE)
    if not m:
        return None
    name = urllib.parse.unquote(m.group(1).strip().strip('"').strip())
    name = os.path.basename(name)
    if name and name not in (".", ".."):
        return name
    return None


def _filename_from_response(resp, fallback: str) -> str:
    """Best filename for a download: Content-Disposition, then final url path."""
    name = _cd_filename(resp)
    if name:
        return name
    path = urllib.parse.urlsplit(resp.geturl()).path
    base = os.path.basename(path.rstrip("/"))
    base = urllib.parse.unquote(base)
    if base and base not in (".", ".."):
        return base
    return fallback


def sniff_type(path: Path) -> str:
    """Last-resort type detection by magic bytes. Unknown if unclear."""
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return "unknown"
    if head[:2] == b"\x1f\x8b":
        return "tar.gz"  # pig has no bare-.gz support; extractor rejects non-tars cleanly
    if head[:6] == b"\xfd7zXZ\x00":
        return "tar.xz"
    if head == b"!<arch>\n":
        return "deb"
    if head[:2] == b"#!":
        return "sh"
    return "unknown"


def download_file(url: str, dest_dir: Path, fallback_name: str) -> tuple:
    """Save url to dest_dir. Returns (path, final_url, cd_filename).

    For http(s) final_url is the url after redirects; cd_filename is the
    Content-Disposition filename (or None). Both feed type detection.
    For local paths final_url is the url itself and cd_filename is None.
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    if not is_remote(url):
        src = Path(os.path.expanduser(strip_file_scheme(url)))
        if not src.is_absolute():
            src = (Path.cwd() / src).resolve()
        if not src.exists():
            raise PigError(f"file not found: {src}")
        if src.is_dir():
            raise PigError(f"unsupported url (is a directory): {url}")
        dst = dest_dir / (src.name or fallback_name)
        try:
            shutil.copyfile(src, dst)
        except OSError as e:
            raise PigError(f"cannot copy {src}: {e}")
        return dst, url, None
    fname = filename_from_url(url, fallback_name)
    # make filename safe
    fname = fname.replace("/", "_").replace("\x00", "_") or fallback_name
    dst = dest_dir / fname
    req = urllib.request.Request(url, headers={"User-Agent": f"pig/{VERSION}"})
    cd_name = None
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            final = r.geturl()
            cd_name = _cd_filename(r)
            better = _filename_from_response(r, fname)
            better = better.replace("/", "_").replace("\x00", "_")
            if better and better != fname:
                dst = dest_dir / better
            with open(dst, "wb") as f:
                shutil.copyfileobj(r, f, length=1024 * 64)
    except urllib.error.HTTPError as e:
        try:
            dst.unlink(missing_ok=True)
        except OSError:
            pass
        raise PigError(f"download failed ({e.code} {e.reason}): {url}")
    except urllib.error.URLError as e:
        try:
            dst.unlink(missing_ok=True)
        except OSError:
            pass
        raise PigError(f"network error: {e.reason} ({url})")
    except TimeoutError:
        try:
            dst.unlink(missing_ok=True)
        except OSError:
            pass
        raise PigError(f"timeout downloading {url}")
    except OSError as e:
        try:
            dst.unlink(missing_ok=True)
        except OSError:
            pass
        raise PigError(f"cannot write {dst}: {e}")
    return dst, final, cd_name


def require_cmd(name: str):
    if shutil.which(name) is None:
        raise PigError(f"missing system command: {name}")


def run_cmd(argv, need_root: bool = False):
    if need_root and os.geteuid() != 0:
        require_cmd("sudo")
        argv = ["sudo"] + argv
    try:
        return subprocess.run(argv)
    except FileNotFoundError:
        raise PigError(f"missing system command: {argv[0]}")
    except PermissionError:
        raise PigError(f"permission denied running: {' '.join(argv)}")


# ---------- installers ----------

def get_deb_field(deb_file: Path, field: str):
    """One control field (Package, Version, ...) from a .deb, or None."""
    require_cmd("dpkg-deb")
    try:
        r = subprocess.run(["dpkg-deb", "-f", str(deb_file), field],
                           capture_output=True, text=True)
    except FileNotFoundError:
        raise PigError("missing system command: dpkg-deb")
    if r.returncode != 0:
        return None
    lines = r.stdout.strip().splitlines()
    return lines[0].strip() if lines and lines[0].strip() else None


def install_deb(deb_file: Path):
    require_cmd("dpkg")
    info("installing deb...")
    r = run_cmd(["dpkg", "-i", str(deb_file)], need_root=True)
    if r.returncode == 0:
        return
    # try to fix missing deps with system tools (not turning pig into apt)
    if shutil.which("apt-get") is not None:
        info("fixing dependencies...")
        r2 = run_cmd(["apt-get", "install", "-f", "-y"], need_root=True)
        if r2.returncode != 0:
            raise PigError("dpkg failed; run 'sudo apt-get install -f' manually")
        info("dependencies fixed")
    else:
        raise PigError("dpkg failed; run 'sudo apt-get install -f' manually")


def _lexical_rel(name: str) -> str:
    """Archive member name -> relative path inside dest. Rejects escapes."""
    import posixpath
    if not name:
        raise PigError("bad archive: empty entry name")
    if name.startswith("/") or name.startswith("\\"):
        raise PigError(f"unsafe archive entry (absolute path): {name!r}")
    norm = posixpath.normpath(name.replace("\\", "/"))
    if norm in (".", ""):
        raise PigError(f"unsafe archive entry: {name!r}")
    if norm == ".." or norm.startswith("../"):
        raise PigError(f"unsafe archive entry (outside destination): {name!r}")
    return norm


def _within(dest_real: str, path: str) -> bool:
    rp = os.path.realpath(path)
    return rp == dest_real or rp.startswith(dest_real + os.sep)


def _extract_tar(archive: Path, dest: Path):
    """Manual tar extraction. Everything must stay inside dest.

    Guards: ../, absolute paths, symlink/hardlink escapes (checked both
    lexically and against the real filesystem, following links created
    earlier in the same archive), device nodes and other special files.
    Never uses extractall().
    """
    import posixpath
    dest.mkdir(parents=True, exist_ok=True)
    dest_real = os.path.realpath(dest)
    try:
        tf = tarfile.open(archive, "r:*")
    except tarfile.TarError as e:
        raise PigError(f"bad archive {archive.name}: {e}")
    except OSError as e:
        raise PigError(f"cannot read {archive.name}: {e}")
    with tf:
        try:
            members = tf.getmembers()
        except (tarfile.TarError, OSError) as e:
            raise PigError(f"bad archive {archive.name}: {e}")
        # phase 1: validate names and types before writing anything
        items = []
        for m in members:
            if m.type in (tarfile.XHDTYPE, tarfile.XGLTYPE,
                          tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
                continue  # metadata carriers, applied by tarfile itself
            if m.name.startswith("/"):
                raise PigError(f"unsafe archive entry (absolute path): {m.name!r}")
            if m.name.rstrip("/") in (".", ""):
                # top-level './' entry of `tar -czf x.tar.gz .` style archives
                if m.isdir():
                    continue
                raise PigError(f"bad archive entry: {m.name!r}")
            rel = _lexical_rel(m.name)
            if not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
                raise PigError(f"unsupported archive entry: {m.name!r}")
            items.append((m, rel))
        # phase 2: extract in order, resolving through existing links
        for m, rel in items:
            target = dest / rel
            parent = target.parent
            try:
                parent.mkdir(parents=True, exist_ok=True)
            except OSError as e:
                raise PigError(f"cannot extract {m.name!r}: {e}")
            if not _within(dest_real, str(parent)):
                raise PigError(f"unsafe archive entry (escapes destination): {m.name!r}")
            try:
                if m.isdir():
                    target.mkdir(exist_ok=True)
                    try:
                        os.chmod(target, (m.mode & 0o777) | 0o700)
                    except OSError:
                        pass
                elif m.isfile():
                    src = tf.extractfile(m)
                    if src is None:
                        raise PigError(f"bad archive entry: {m.name!r}")
                    with src, open(target, "wb") as out:
                        shutil.copyfileobj(src, out, length=1024 * 64)
                    try:
                        os.chmod(target, (m.mode & 0o7777) & ~0o6000)
                    except OSError:
                        pass
                elif m.issym():
                    link = m.linkname
                    if not link or link.startswith("/"):
                        raise PigError(f"unsafe symlink in archive: {m.name!r}")
                    eff = posixpath.normpath(posixpath.join(posixpath.dirname(rel), link))
                    if eff == ".." or eff.startswith("../"):
                        raise PigError(f"unsafe symlink in archive: {m.name!r}")
                    if os.path.lexists(target):
                        os.unlink(target)
                    os.symlink(link, target)
                    if not _within(dest_real, str(target)):
                        try:
                            os.unlink(target)
                        except OSError:
                            pass
                        raise PigError(f"unsafe symlink in archive: {m.name!r}")
                elif m.islnk():
                    link = m.linkname
                    if not link or link.startswith("/"):
                        raise PigError(f"unsafe hardlink in archive: {m.name!r}")
                    src_rel = posixpath.normpath(posixpath.join(posixpath.dirname(rel), link))
                    if src_rel == ".." or src_rel.startswith("../"):
                        raise PigError(f"unsafe hardlink in archive: {m.name!r}")
                    src_path = dest / src_rel
                    if not _within(dest_real, str(src_path)) or not src_path.is_file():
                        raise PigError(f"unsafe hardlink in archive: {m.name!r}")
                    if os.path.lexists(target):
                        os.unlink(target)
                    os.link(src_path, target)
            except PigError:
                raise
            except (tarfile.TarError, OSError) as e:
                raise PigError(f"cannot extract {m.name!r}: {e}")


# extensions that are never the application binary
_EXE_BAD_SUFFIXES = (".so", ".pak", ".dat", ".bin", ".o", ".a", ".png",
                     ".jpg", ".jpeg", ".svg", ".ico", ".txt", ".md",
                     ".json", ".js", ".map", ".html", ".css", ".xml",
                     ".desktop", ".ttf", ".woff", ".woff2", ".pem",
                     ".key", ".crt", ".db", ".sqlite", ".mo", ".qm",
                     ".log", ".py", ".pyc", ".sh")
# name fragments that mark helpers, not the application itself
_EXE_BAD_NAME_PARTS = ("helper", "crash", "sandbox", "uninstall", "updater")


def _exe_candidates(root: Path):
    """Executable files under root: [(posix rel, depth, target rel|None)].

    In-tree symlinks to executable files are candidates too (rel is the
    link, target rel is where it points); dangling or escaping links
    are skipped.
    """
    root_real = os.path.realpath(root)
    out = []
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            p = Path(dirpath) / fn
            try:
                rel = p.relative_to(root).as_posix()
                if p.is_symlink():
                    rp = p.resolve()
                    if not _within(root_real, str(rp)) or not rp.is_file():
                        continue
                    if not os.access(rp, os.X_OK):
                        continue
                    out.append((rel, len(Path(rel).parts), rp.relative_to(root_real).as_posix()))
                else:
                    if not p.is_file() or not os.access(p, os.X_OK):
                        continue
                    out.append((rel, len(Path(rel).parts), None))
            except OSError:
                continue
    return out


def _pick_shallowest(cands, name: str) -> str:
    best = min(d for _, d in cands)
    top = sorted(r for r, d in cands if d == best)
    if len(top) > 1:
        show = ", ".join(top[:5])
        raise PigError(f"cannot determine executable for '{name}': ambiguous ({show})")
    return top[0]


def _fallback_allowed(rel: str) -> bool:
    low = rel.lower()
    base = low.rsplit("/", 1)[-1]
    if ".so" in base:
        return False
    if any(base.endswith(s) for s in _EXE_BAD_SUFFIXES):
        return False
    if any(part in base for part in _EXE_BAD_NAME_PARTS):
        return False
    return True


def select_executable(root: Path, name: str) -> str:
    """Pick the application binary inside an extracted tree.

    0. vendor entry point: a top-level symlink named like the package
       pointing at an executable inside the tree (follow it),
    1. exact basename match (case-sensitive), 2. case-insensitive match,
    3. a single unambiguous executable near the top of the tree.
    Returns the posix relative path. Never guesses randomly.
    """
    cands = _exe_candidates(root)
    links = [(r, d, t) for r, d, t in cands
             if t is not None and Path(r).name.lower() == name.lower() and d <= 2]
    if links:
        best = min(d for _, d, _ in links)
        tgts = sorted({t for _, d, t in links if d == best})
        if len(tgts) > 1:
            raise PigError(f"cannot determine executable for '{name}': ambiguous ({', '.join(tgts[:5])})")
        return tgts[0]
    exact = [(r, d) for r, d, _ in cands if Path(r).name == name]
    if exact:
        return _pick_shallowest(exact, name)
    ci = [(r, d) for r, d, _ in cands if Path(r).name.lower() == name.lower()]
    if ci:
        return _pick_shallowest(ci, name)
    rest = [(r, d) for r, d, _ in cands if _fallback_allowed(r) and d <= 2]
    if len(rest) == 1:
        return rest[0][0]
    show = ", ".join(sorted(r for r, _, _ in cands)[:5]) or "none found"
    raise PigError(f"cannot determine executable for '{name}': {len(rest)} candidates ({show})")


def _move_tree(src: Path, dst: Path):
    """Rename src onto dst (atomic on one filesystem), copy fallback across."""
    try:
        os.rename(src, dst)
        return
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
    shutil.copytree(src, dst, symlinks=True)
    shutil.rmtree(src, ignore_errors=True)


def _write_launcher(link: Path, target: Path):
    """Point ~/.local/bin/<name> at the installed binary. Never clobbers
    foreign files: an existing entry is replaced only if it is our symlink."""
    bin_dir().mkdir(parents=True, exist_ok=True)
    if os.path.lexists(link):
        allowed = False
        if link.is_symlink():
            try:
                cur = str(link.resolve())
            except OSError:
                cur = None
            if cur is not None:
                base = opt_base().resolve()
                allowed = cur == str(base / link.name) or _within(str(base / link.name), cur)
        if not allowed:
            raise PigError(f"refusing to overwrite {link}: not installed by pig")
        link.unlink()
    link.symlink_to(target)


def install_archive(archive: Path, name: str):
    """User-local install of an archive application.

    Extracts to a staging dir, picks the executable, then swaps the new
    tree into ~/.local/opt/<name>/ and (re)points ~/.local/bin/<name>.
    The old installation is untouched until the new tree is ready;
    on failure it is restored. Nothing stays in ~/.cache/pig/.
    """
    dest = opt_base() / name
    link = bin_dir() / name
    tag = str(os.getpid())
    stage = cache_dir() / f".{name}.stage-{tag}"
    bak = cache_dir() / f".{name}.old-{tag}"
    if stage.exists():
        shutil.rmtree(stage, ignore_errors=True)
    try:
        info(f"extracting to {dest}...")
        _extract_tar(archive, stage)
        exe_rel = select_executable(stage, name)
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    target = dest / exe_rel
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists() or os.path.lexists(dest):
            if bak.exists() or os.path.lexists(bak):
                if bak.is_dir() and not bak.is_symlink():
                    shutil.rmtree(bak, ignore_errors=True)
                else:
                    try:
                        bak.unlink()
                    except OSError:
                        pass
            os.rename(dest, bak)
            try:
                _move_tree(stage, dest)
            except Exception:
                try:
                    if dest.exists() or os.path.lexists(dest):
                        if dest.is_dir() and not dest.is_symlink():
                            shutil.rmtree(dest, ignore_errors=True)
                        else:
                            dest.unlink(missing_ok=True)
                    os.rename(bak, dest)  # rollback
                except OSError:
                    pass
                raise
            if bak.is_dir() and not bak.is_symlink():
                shutil.rmtree(bak, ignore_errors=True)
            else:
                try:
                    bak.unlink()
                except OSError:
                    pass
        else:
            _move_tree(stage, dest)
        _write_launcher(link, target)
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        if isinstance(sys.exc_info()[1], PigError):
            raise
        raise PigError(f"cannot install '{name}': {sys.exc_info()[1]}")
    _fix_owner(dest)
    _fix_owner(bin_dir())
    return {"type": None, "path": str(dest), "exe": exe_rel, "launcher": str(link)}


def install_sh(script: Path):
    try:
        st = script.stat()
        script.chmod(st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except OSError as e:
        raise PigError(f"chmod failed for {script.name}: {e}")
    try:
        with open(script, "rb") as f:
            head = f.read(2)
    except OSError as e:
        raise PigError(f"cannot read {script.name}: {e}")
    if head != b"#!":
        raise PigError(f"refusing to run {script.name}: no shebang line")
    # run exactly as ./filename so the kernel picks the interpreter
    argv = ["./" + script.name]
    info("running installer...")
    try:
        r = subprocess.run(argv, cwd=str(script.parent))
    except OSError as e:
        raise PigError(f"cannot run ./{script.name}: {e.strerror or e}")
    if r.returncode != 0:
        raise PigError(f"installer exited with code {r.returncode}")


def do_install_file(name: str, url: str, tmpdir: Path) -> dict:
    """Download + install. Returns extra record fields. Cleans downloaded file."""
    remote = is_remote(url)
    ftype = detect_type(url)
    if ftype == "unknown" and not remote:
        raise PigError(f"unknown format for '{name}' (supports .deb, .tar.gz, .tar.xz, .sh): {url}")
    info("downloading...")
    dl_dir = Path(tmpdir) / "dl"
    dl_dir.mkdir(parents=True, exist_ok=True)
    f, final, cd_name = download_file(url, dl_dir, name)
    try:
        if ftype == "unknown":
            # 1. final url (after redirects), 2. Content-Disposition
            # filename of any http response, 3. magic bytes fallback
            ftype = detect_type(final)
            if ftype == "unknown" and cd_name:
                ftype = detect_type(cd_name)
            if ftype == "unknown":
                ftype = sniff_type(f)
            if ftype == "unknown":
                raise PigError(f"unknown format for '{name}' (supports .deb, .tar.gz, .tar.xz, .sh): {url}")
        if ftype == "deb":
            pkg = get_deb_field(f, "Package")
            install_deb(f)
            rec = {"type": "deb", "package": pkg}
            ver = get_deb_field(f, "Version")
            if ver:
                rec["version"] = ver
            return rec
        if ftype in ("tar.gz", "tar.xz"):
            rec = install_archive(f, name)
            rec["type"] = ftype
            return rec
        if ftype == "sh":
            install_sh(f)
            return {"type": "sh"}
    finally:
        try:
            if f.exists():
                f.unlink()
        except OSError:
            pass
    raise PigError("install failed")  # unreachable


# ---------- commands ----------

def cmd_search(query: str):
    info(f"searching for {query}...")
    by_source, errors = load_all_dicts()
    q = query.lower()
    found = []
    for src, (_, entries) in sorted(by_source.items()):
        for n, u in sorted(entries.items()):
            if q in n.lower():
                found.append((n, u, src))
    if not found:
        info(f"no results for '{query}'")
    else:
        print(f"results for '{query}':")
        for n, u, src in found:
            print(f"  {n} ({src})")
            print(f"    {u}")
    for e in errors:
        info(f"warning: {e}")
    return 0


def cmd_list():
    by_source, errors = load_all_dicts()
    # group by url, first seen name is canonical
    groups = {}  # url -> [names in order]
    for src in sorted(by_source):
        _, entries = by_source[src]
        for n, u in entries.items():
            if u not in groups:
                groups[u] = []
            if n not in groups[u]:
                groups[u].append(n)
    # sort by canonical
    ordered = sorted(groups.items(), key=lambda kv: kv[1][0].lower())
    for url, names in ordered:
        print(names[0])
        if len(names) > 1:
            print(f"  aliases: {', '.join(names[1:])}")
    for e in errors:
        info(f"warning: {e}")
    return 0


def cmd_install(name: str, yes: bool = False):
    ensure_dirs()
    by_source, errors = load_all_dicts()
    for e in errors:
        info(f"warning: {e}")
    cands = find_package(name, by_source)
    if not cands:
        raise PigError(f"package '{name}' not found")
    pkgs = load_installed()
    if name in pkgs and not yes:
        print(f"{name} is already installed")
        try:
            raw = input("reinstall? [y/N]: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            raise PigError("cancelled")
        if raw != "y":
            return 0
    if len(cands) > 1:
        if yes:
            # config order: official first; the pick is logged, not silent
            src, url = cands[0]
            info(f"using source '{src}'")
        else:
            # config order, not sorted: official first as in the example
            src, url = choose_source(name, cands)
    else:
        src, url = cands[0]
    info(f"found {name}")
    import datetime
    with tempfile.TemporaryDirectory(prefix="pig-", dir=str(cache_dir())) as td:
        extra = do_install_file(name, url, Path(td))
    record = {"name": name, "url": url, "source": src,
              "installed_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    record.update(extra)
    pkgs[name] = record
    save_installed(pkgs)
    info("done")
    return 0


def cmd_remove(name: str):
    pkgs = load_installed()
    if name not in pkgs:
        raise PigError(f"package '{name}' is not installed via pig")
    rec = pkgs[name]
    ftype = rec.get("type", "unknown")
    if ftype == "deb":
        pkg = rec.get("package")
        if not pkg:
            raise PigError(f"cannot remove '{name}': unknown deb package name")
        require_cmd("dpkg")
        info(f"removing {pkg}...")
        r = run_cmd(["dpkg", "-r", pkg], need_root=True)
        if r.returncode != 0:
            raise PigError(f"failed to remove '{pkg}'")
    elif ftype in ("tar.gz", "tar.xz"):
        p = Path(rec["path"]) if rec.get("path") else (opt_base() / name)
        rp = p.resolve()
        # safety: only delete ~/.local/opt/<name>
        # (or ~/.cache/pig/<name> from the pre-opt install model)
        if rp != opt_base().resolve() / name and rp != cache_dir().resolve() / name:
            raise PigError(f"refusing to delete unexpected path for '{name}': {p}")
        if p.exists() or os.path.lexists(p):
            info(f"removing {p}...")
            try:
                if p.is_dir() and not p.is_symlink():
                    shutil.rmtree(p)
                else:
                    p.unlink()
            except OSError as e:
                raise PigError(f"cannot remove {p}: {e}")
        else:
            info(f"{name}: directory already gone")
        link = Path(rec["launcher"]) if rec.get("launcher") else None
        if link is None:
            pass  # legacy record: no launcher was created
        elif os.path.lexists(link):
            if link.is_symlink():
                try:
                    cur = str(link.resolve())
                except OSError:
                    cur = None
                if cur is None or not _within(str(rp), cur):
                    raise PigError(f"refusing to delete {link}: not installed by pig")
                try:
                    link.unlink()
                except OSError as e:
                    raise PigError(f"cannot remove {link}: {e}")
            else:
                raise PigError(f"refusing to delete {link}: not installed by pig")
        _fix_owner(bin_dir())
    elif ftype == "sh":
        # automatic removal is not supported: a shell installer may have
        # written unknown files, and the record must stay so pig knows
        # the package is still installed.
        raise PigError(f"cannot remove '{name}' automatically (installed via shell script); remove it manually")
    else:
        raise PigError(f"cannot remove '{name}': unknown install type")
    del pkgs[name]
    save_installed(pkgs)
    info("done")
    return 0


def cmd_upgrade(yes: bool = False):
    ensure_dirs()
    pkgs = load_installed()
    if not pkgs:
        info("nothing installed")
        return 0
    by_source, errors = load_all_dicts()
    for e in errors:
        info(f"warning: {e}")
    changed = 0
    failed = []
    for name in sorted(pkgs):
        try:
            if _upgrade_one(name, pkgs, by_source, yes):
                changed += 1
        except PigError as e:
            if "cancelled" in str(e):
                raise
            err(f"{name}: {e}")
            failed.append(name)
            continue
    if failed:
        raise PigError(f"upgrade finished with errors ({', '.join(failed)})")
    info("done" if changed else "all up to date")
    return 0


def _upgrade_one(name: str, pkgs: dict, by_source: dict, yes: bool = False) -> bool:
    """Upgrade one package. Returns True if it was upgraded."""
    import datetime
    rec = pkgs[name]
    cands = find_package(name, by_source)
    if not cands:
        info(f"{name}: not found in dictionaries, skipping")
        return False
    urls = {u for _, u in cands}
    if len(urls) == 1:
        cur_url = next(iter(urls))
        cur_src = rec.get("source") if rec.get("source") in [s for s, _ in cands] else cands[0][0]
    elif yes:
        # non-interactive: stay on the recorded source when possible
        saved = [c for c in cands if c[0] == rec.get("source")]
        cur_src, cur_url = saved[0] if saved else cands[0]
        info(f"{name}: using source '{cur_src}'")
    else:
        info(f"{name}: found in multiple sources with different urls")
        cur_src, cur_url = choose_source(name, cands)
    if cur_url == rec.get("url"):
        info(f"{name} is up to date")
        return False
    info(f"{name}: url changed")
    print(f"  old: {rec.get('url')}")
    print(f"  new: {cur_url}")
    old_path = rec.get("path")
    with tempfile.TemporaryDirectory(prefix="pig-", dir=str(cache_dir())) as td:
        extra = do_install_file(name, cur_url, Path(td))
    if old_path and old_path != extra.get("path"):
        # install type changed away from an unpacked archive:
        # drop the stale directory (safety-checked, cache/<name> only)
        p = Path(old_path)
        try:
            if p.resolve() == (cache_dir() / name).resolve() and p.exists():
                shutil.rmtree(p)
        except OSError as e:
            raise PigError(f"upgraded '{name}' but cannot remove stale {p}: {e}")
    rec["url"] = cur_url
    rec["source"] = cur_src
    rec["installed_at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    # type may have changed: drop stale keys then update
    for k in ("type", "path", "package", "version", "exe", "launcher"):
        rec.pop(k, None)
    rec.update(extra)
    pkgs[name] = rec
    save_installed(pkgs)
    info(f"{name} upgraded")
    return True


def cmd_update():
    ensure_dirs()
    sources = load_sources()
    fail = 0
    for s in sources:
        if not is_remote(s["url"]):
            continue
        try:
            text = fetch_text(s["url"])
            _cache_file_for(s["name"]).write_text(text, encoding="utf-8")
            info(f"updated '{s['name']}'")
        except PigError as e:
            err(str(e))
            fail += 1
    if not any(is_remote(s["url"]) for s in sources):
        info("no remote dictionaries to update")
    # self-update pig from official source
    try:
        _self_update()
    except PigError as e:
        err(str(e))
        fail += 1
    if fail:
        raise PigError("update finished with errors")
    info("done")
    return 0


def _self_update():
    try:
        new = fetch_text(OFFICIAL_PIG_URL)
    except PigError as e:
        if "404" in str(e):
            raise PigError(f"pig self-update failed: file not published (404) at {OFFICIAL_PIG_URL}")
        raise PigError(f"pig self-update failed: {e}")
    _install_new_executable(Path(__file__).resolve(), new)


def _install_new_executable(target: Path, data: str):
    """Replace target executable with data. User dir: direct atomic replace,
    root-owned location: sudo copy to temp name + sudo rename (never a
    partially written target file). Verifies content afterwards."""
    if not data or len(data) < 500:
        raise PigError("pig self-update failed: bad remote file")
    first = data.splitlines()[0] if data.splitlines() else ""
    if "python" not in first and "pig" not in data[:2000]:
        raise PigError("pig self-update failed: bad remote file")
    try:
        cur = target.read_text(encoding="utf-8")
    except OSError:
        cur = None
    if cur == data:
        info("pig is already up to date")
        return
    parent = target.parent
    tmp_name = f".pig.new-{os.getpid()}"
    if os.access(parent, os.W_OK):
        tmp = parent / tmp_name
        try:
            tmp.write_text(data, encoding="utf-8")
            st = tmp.stat()
            tmp.chmod(st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            os.replace(tmp, target)  # atomic on one filesystem
            _fix_owner(target)
        except OSError as e:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
            raise PigError(f"pig self-update failed (current install kept): {e}")
        try:
            if target.read_text(encoding="utf-8") != data:
                raise PigError("pig self-update failed: verify mismatch (current install kept)")
        except OSError as e:
            raise PigError(f"pig self-update failed (current install kept): {e}")
        info("pig updated")
        return
    # root-owned location: stage in cache, install via sudo
    if os.geteuid() != 0:
        require_cmd("sudo")
        sudo = ["sudo"]
    else:
        sudo = []
    staged = cache_dir() / f"pig.new-{os.getpid()}"
    new_tmp = parent / tmp_name
    try:
        ensure_dirs()
        staged.write_text(data, encoding="utf-8")
        st = staged.stat()
        staged.chmod(st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        for argv in (sudo + ["cp", str(staged), str(new_tmp)],
                     sudo + ["chmod", "755", str(new_tmp)],
                     sudo + ["mv", str(new_tmp), str(target)]):
            try:
                r = subprocess.run(argv)
            except OSError as e:
                raise PigError(f"pig self-update failed (current install kept): {e}")
            if r.returncode != 0:
                raise PigError(f"pig self-update failed (current install kept): {' '.join(argv)}")
        try:
            if target.read_text(encoding="utf-8") != data:
                raise PigError("pig self-update failed: verify mismatch (current install kept)")
        except OSError as e:
            raise PigError(f"pig self-update failed (current install kept): {e}")
        info("pig updated")
    finally:
        try:
            staged.unlink(missing_ok=True)
        except OSError:
            pass
        try:
            if new_tmp.exists() or os.path.lexists(new_tmp):
                if sudo:
                    subprocess.run(sudo + ["rm", "-f", str(new_tmp)])
                else:
                    new_tmp.unlink(missing_ok=True)
        except OSError:
            pass


def cmd_config():
    cp = ensure_config()
    print(f"config: {cp}")
    for s in load_sources():
        print(f"  {s['name']} = {s['url']}")
    print("edit this file to add your own dictionaries (local paths allowed)")
    return 0


def _short(path: str) -> str:
    """Abbreviate a path under home with ~."""
    try:
        return "~/" + str(Path(path).relative_to(real_home()))
    except ValueError:
        return path


def cmd_installed():
    pkgs = load_installed()
    if not pkgs:
        info("nothing installed")
        return 0
    for name in sorted(pkgs):
        print(name)
    return 0


def cmd_info(name: str):
    pkgs = load_installed()
    rec = pkgs.get(name)
    by_source, errors = load_all_dicts()
    cands = find_package(name, by_source)
    if rec is None and not cands:
        raise PigError(f"package '{name}' not found")
    info(name)
    print()
    print()
    if rec is not None:
        print(f"name: {rec.get('name', name)}")
        print(f"source: {rec.get('source', '?')}")
        print(f"type: {rec.get('type', '?')}")
        if rec.get("version"):
            print(f"version: {rec['version']}")
        print(f"url: {rec.get('url', '?')}")
        print("installed: yes")
        if rec.get("path"):
            print(f"path: {_short(rec['path'])}")
        if rec.get("launcher"):
            print(f"launcher: {_short(rec['launcher'])}")
    else:
        src, url = cands[0]
        print(f"name: {name}")
        print(f"source: {src}")
        ftype = detect_type(url)
        if ftype != "unknown":
            print(f"type: {ftype}")
        print(f"url: {url}")
        print("installed: no")
    for e in errors:
        info(f"warning: {e}")
    return 0


def cmd_clean():
    """Delete temp files from the cache. Keeps dicts/, installed.json
    and everything installed."""
    ensure_dirs()
    removed = 0
    freed = 0
    for entry in cache_dir().iterdir():
        if entry.name in ("dicts", "installed.json"):
            continue
        if not (entry.name.startswith(".") or entry.name.startswith("pig-")
                or entry.name.startswith("pig.new-")):
            continue
        try:
            if entry.is_dir() and not entry.is_symlink():
                freed += sum(p.stat().st_size for p in entry.rglob("*") if p.is_file())
                shutil.rmtree(entry)
            else:
                freed += entry.stat().st_size
                entry.unlink()
            removed += 1
        except OSError as e:
            raise PigError(f"cannot clean {entry}: {e}")
    if removed:
        info(f"removed {removed} temp file(s), freed {freed} bytes")
    else:
        info("cache clean")
    return 0


# ---------- main ----------

def build_parser():
    p = argparse.ArgumentParser(prog="pig", description="minimal package manager (stdlib only)")
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("install", help="install app by name")
    i.add_argument("-y", "--yes", action="store_true", help="skip confirmations")
    i.add_argument("name")
    r = sub.add_parser("remove", help="remove app installed via pig")
    r.add_argument("-y", "--yes", action="store_true", help="skip confirmations")
    r.add_argument("name")
    s = sub.add_parser("search", help="search names and aliases")
    s.add_argument("query")
    sub.add_parser("list", help="list names and aliases")
    sub.add_parser("installed", help="list packages installed via pig")
    f = sub.add_parser("info", help="show package info")
    f.add_argument("name")
    sub.add_parser("update", help="update dict cache and pig itself")
    u = sub.add_parser("upgrade", help="upgrade installed apps whose url changed")
    u.add_argument("-y", "--yes", action="store_true", help="skip confirmations")
    sub.add_parser("clean", help="delete temp files from the cache")
    sub.add_parser("config", help="show config and sources")
    sub.add_parser("doctor", help="check distro support and environment")
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.cmd == "install":
            return cmd_install(args.name, args.yes)
        if args.cmd == "remove":
            return cmd_remove(args.name)
        if args.cmd == "search":
            return cmd_search(args.query)
        if args.cmd == "list":
            return cmd_list()
        if args.cmd == "installed":
            return cmd_installed()
        if args.cmd == "info":
            return cmd_info(args.name)
        if args.cmd == "update":
            return cmd_update()
        if args.cmd == "upgrade":
            return cmd_upgrade(args.yes)
        if args.cmd == "clean":
            return cmd_clean()
        if args.cmd == "config":
            return cmd_config()
        if args.cmd == "doctor":
            return cmd_doctor()
    except PigError as e:
        err(str(e))
        return 1
    except OSError as e:
        err(str(e))
        return 1
    except KeyboardInterrupt:
        print("\n[pig] cancelled", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
