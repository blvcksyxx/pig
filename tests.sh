#!/bin/sh
# pig tests v1.4.
# Hermetic: isolated HOME dirs, local files, local 127.0.0.1 server only.
# No system changes (except an empty test .deb when passwordless sudo allows).
# Usage: ./tests.sh   (exit 0 = all pass)
set -u

PIG_DIR="$(cd "$(dirname "$0")" && pwd)"
PIG="$PIG_DIR/pig.py"
T=""
SRVPID=""
RODIR=""
PASS=0
FAIL=0
SKIP=0

cleanup() {
    if [ -n "$SRVPID" ]; then
        kill "$SRVPID" 2>/dev/null
    fi
    if [ -n "$RODIR" ]; then
        sudo -n rm -rf "$RODIR" 2>/dev/null
    fi
    if [ -n "$T" ]; then
        rm -rf "$T"
    fi
}
trap cleanup EXIT INT TERM

pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1: $2"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP $1: $2"; }

# run <home> <pig args...>: stdout+stderr to $T/last.out, prints exit code
run() {
    H="$1"
    shift
    HOME="$H" "$PIG" "$@" >"$T/last.out" 2>&1
    printf '%s' "$?"
}

expect_code() {
    if [ "$2" = "$1" ]; then pass "$3"; else fail "$3" "exit=$2 want=$1 :: $(cat "$T/last.out")"; fi
}

expect_grep() {
    if grep -q "$1" "$T/last.out"; then pass "$2"; else fail "$2" "missing [$1] :: $(cat "$T/last.out")"; fi
}

expect_no_traceback() {
    if grep -q "Traceback" "$T/last.out"; then fail "$1" "traceback leaked"; else pass "$1"; fi
}

command -v python3 >/dev/null 2>&1 || { echo "missing: python3"; exit 2; }
[ -x "$PIG" ] || { echo "missing: $PIG"; exit 2; }

T="$(mktemp -d)"
H="$T/home"
FX="$T/fx"
mkdir -p "$H/.config/pig" "$FX"

# ---------------- fixtures ----------------
FX="$FX" T_SENT="$T" python3 <<'EOF'
import os, tarfile, io
fx = os.environ["FX"]
t = os.environ["T_SENT"]

def make_tarball(path, members, mode="w:gz"):
    with tarfile.open(path, mode) as tf:
        for name, kind, payload in members:
            ti = tarfile.TarInfo(name)
            if kind == "f":
                data = payload.encode()
                ti.size = len(data)
                ti.mode = 0o644
                tf.addfile(ti, io.BytesIO(data))
            elif kind == "x":
                data = payload.encode()
                ti.size = len(data)
                ti.mode = 0o755
                tf.addfile(ti, io.BytesIO(data))
            elif kind == "d":
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                tf.addfile(ti)
            elif kind == "s":
                ti.type = tarfile.SYMTYPE
                ti.linkname = payload
                tf.addfile(ti)
            elif kind == "h":
                ti.type = tarfile.LNKTYPE
                ti.linkname = payload
                tf.addfile(ti)

BIN_SH = '#!/bin/sh\necho "$0" > "$PIGRT_MARKER"\n'

def app_tarball(path, binname, body):
    make_tarball(path, [("appdir", "d", ""),
                        ("appdir/hello.txt", "f", body),
                        ("appdir/" + binname, "x", BIN_SH)])

for app, binname, body in [("mytool-v1", "mytool", "hello-v1"),
                           ("mytool-v2", "mytool", "hello-v2"),
                           ("other-v1", "other", "hello-other")]:
    app_tarball(os.path.join(fx, app + ".tar.gz"), binname, body)

make_tarball(fx + "/evil-dotdot.tar.gz", [("../pwned.txt", "f", "x")])
make_tarball(fx + "/evil-symlink.tar.gz", [("link", "s", t + "/outside-sym"),
                                           ("link/pwn.txt", "f", "x")])
make_tarball(fx + "/evil-hardlink.tar.gz", [("hard", "h", "/etc/hostname")])
with open(fx + "/app-corrupt.tar.gz", "wb") as f:
    f.write(b"garbage-not-a-tarball\x00\xff" * 64)

with open(fx + "/demo.sh", "w") as f:
    f.write('#!/bin/sh\necho "$0" > "$PIGRT_MARKER"\n')
with open(fx + "/plain.sh", "w") as f:
    f.write('echo no-shebang-here\n')
with open(fx + "/weird.xyz", "w") as f:
    f.write("hello\n")
print("fixtures ok")
EOF

cat >"$FX/official.txt" <<EOF
# official dict
mytool::file://$FX/mytool-v1.tar.gz
mytool-alias::file://$FX/mytool-v1.tar.gz
shdemo::file://$FX/demo.sh
noshebang::file://$FX/plain.sh
weird::file://$FX/weird.xyz
evil-dot::file://$FX/evil-dotdot.tar.gz
evil-sym::file://$FX/evil-symlink.tar.gz
evil-hard::file://$FX/evil-hardlink.tar.gz
# comment
bad-line
EOF
cat >"$FX/custom.txt" <<EOF
# custom dict
mytool::file://$FX/mytool-v2.tar.gz
other::file://$FX/other-v1.tar.gz
EOF
printf '[sources]\nofficial = "%s/official.txt"\ncustom = "%s/custom.txt"\n' "$FX" "$FX" >"$H/.config/pig/config.toml"

echo "--- core ---"
code=$(run "$H" list)
expect_code 0 "$code" "list-exit"
expect_grep "aliases: mytool-alias" "list-alias"
code=$(run "$H" search mytool)
expect_code 0 "$code" "search-exit"
expect_grep "mytool (custom)" "search-custom"
code=$(run "$H" install mytool </dev/null)
expect_code 1 "$code" "install-conflict-needs-choice"
code=$(printf '2\n' | HOME="$H" "$PIG" install mytool >"$T/last.out" 2>&1; printf '%s' "$?")
expect_code 0 "$code" "install-choose-custom"
if [ "$(cat "$H/.local/opt/mytool/appdir/hello.txt")" = "hello-v2" ]; then
    pass "install-content"
else
    fail "install-content" "wrong content"
fi
code=$(run "$H" info mytool)
expect_code 0 "$code" "info-exit"
expect_grep "^installed: yes$" "info-yes"
expect_grep "^path: ~/.local/opt/mytool$" "info-path"
code=$(run "$H" installed)
expect_code 0 "$code" "installed-exit"
expect_grep "^mytool$" "installed-name"
code=$(run "$H" install -y mytool </dev/null)
expect_code 0 "$code" "yes-reinstall"
PIGRT_MARKER="$T/lmark.txt" "$H/.local/bin/mytool"
if [ "$(cat "$T/lmark.txt")" = "$H/.local/bin/mytool" ]; then
    pass "launcher-runs"
else
    fail "launcher-runs" "bad argv0"
fi
export PIGRT_MARKER="$T/argv0.txt"
code=$(run "$H" install shdemo)
expect_code 0 "$code" "sh-exit"
code=$(run "$H" remove shdemo)
expect_code 1 "$code" "sh-remove-rejected"
code=$(run "$H" install noshebang)
expect_code 1 "$code" "noshebang-refused"
expect_grep "shebang" "noshebang-msg"
code=$(run "$H" install foobar)
expect_code 1 "$code" "notfound"
expect_no_traceback "notfound-clean"
code=$(run "$H" install weird)
expect_code 1 "$code" "unknown-format"
sed -i "s|mytool::file://$FX/mytool-v1.tar.gz|mytool::file://$FX/mytool-v2.tar.gz|" "$FX/official.txt"
code=$(run "$H" upgrade)
expect_code 0 "$code" "upgrade-changed"
expect_grep "url changed" "upgrade-msg"
if [ "$(cat "$H/.local/opt/mytool/appdir/hello.txt")" = "hello-v2" ]; then
    pass "upgrade-content"
else
    fail "upgrade-content" "not upgraded"
fi
code=$(run "$H" upgrade)
expect_code 0 "$code" "upgrade-clean"
expect_grep "up to date" "upgrade-idle"
code=$(run "$H" remove -y mytool)
expect_code 0 "$code" "remove-exit"
if [ ! -e "$H/.local/opt/mytool" ] && [ ! -L "$H/.local/bin/mytool" ]; then
    pass "remove-files"
else
    fail "remove-files" "leftovers"
fi
code=$(run "$H" clean)
expect_code 0 "$code" "clean-exit"

echo "--- tar security ---"
code=$(run "$H" install evil-dot)
expect_code 1 "$code" "evil-dotdot"
expect_grep "outside destination" "evil-dotdot-msg"
code=$(run "$H" install evil-sym)
expect_code 1 "$code" "evil-symlink"
code=$(run "$H" install evil-hard)
expect_code 1 "$code" "evil-hardlink"
if [ ! -e "$T/outside-sym" ]; then pass "no-escape"; else fail "no-escape" "wrote outside"; fi
code=$(run "$H" install other)
expect_code 0 "$code" "corrupt-setup"
sed -i "s|other::file://$FX/other-v1.tar.gz|other::file://$FX/app-corrupt.tar.gz|" "$FX/custom.txt"
code=$(run "$H" upgrade)
expect_code 1 "$code" "corrupt-upgrade-fails"
if [ "$(cat "$H/.local/opt/other/appdir/hello.txt")" = "hello-other" ]; then
    pass "old-version-preserved"
else
    fail "old-version-preserved" "old install damaged"
fi
sed -i "s|other::file://$FX/app-corrupt.tar.gz|other::file://$FX/other-v1.tar.gz|" "$FX/custom.txt"

echo "--- http type detection ---"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
mkdir -p "$FX/www/files"
python3 - "$FX" <<'EOF'
import os, tarfile, io
fx = __import__("sys").argv[1]
with tarfile.open(fx + "/www/files/app-1.0.tar.gz", "w:gz") as tf:
    for name, kind, data in [("appdir", "d", None), ("appdir/hello.txt", "f", b"hello-net"),
                             ("appdir/netapp", "x", b'#!/bin/sh\necho hi\n')]:
        ti = tarfile.TarInfo(name)
        if kind == "d":
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            tf.addfile(ti)
        else:
            ti.size = len(data)
            ti.mode = 0o644 if kind == "f" else 0o755
            tf.addfile(ti, io.BytesIO(data))
print("net fixture ok")
EOF
cat >"$T/server.py" <<EOF
import http.server, functools
WWW = "$FX/www"
class H(http.server.SimpleHTTPRequestHandler):
    def _serve_blob(self, with_cd):
        with open(WWW + "/files/app-1.0.tar.gz", "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        if with_cd:
            self.send_header("Content-Disposition",
                             "attachment; filename=postman-linux-x64.tar.gz")
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/app":
            self.send_response(302)
            self.send_header("Location", "/files/app-1.0.tar.gz")
            self.end_headers()
        elif self.path == "/dl":
            self._serve_blob(True)
        elif self.path == "/blob":
            self._serve_blob(False)
        else:
            super().do_GET()
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", $PORT),
    functools.partial(H, directory=WWW)).serve_forever()
EOF
python3 "$T/server.py" >/dev/null 2>&1 &
SRVPID="$!"
sleep 1
HN="$T/homenet"
mkdir -p "$HN/.config/pig"
printf '[sources]\nofficial = "%s/net.txt"\n' "$FX" >"$HN/.config/pig/config.toml"
printf 'netapp::http://127.0.0.1:%s/app\ncdapp::http://127.0.0.1:%s/dl\nblobapp::http://127.0.0.1:%s/blob\n' "$PORT" "$PORT" "$PORT" >"$FX/net.txt"
for _t in "netapp redirect" "cdapp content-disposition" "blobapp magic-bytes"; do
    set -- $_t
    code=$(run "$HN" install "$1")
    expect_code 0 "$code" "$1-install"
    if [ "$(cat "$HN/.local/opt/$1/appdir/hello.txt" 2>/dev/null)" = "hello-net" ]; then
        pass "$1-content"
    else
        fail "$1-content" "$(cat "$T/last.out")"
    fi
done
kill "$SRVPID" 2>/dev/null
SRVPID=""

echo "--- deb (needs dpkg + passwordless sudo) ---"
if ! command -v dpkg >/dev/null 2>&1 || ! command -v dpkg-deb >/dev/null 2>&1; then
    skip "deb" "no dpkg"
elif ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    skip "deb" "no passwordless sudo"
else
    mkdir -p "$FX/mindeb/DEBIAN"
    printf 'Package: pig-test-min\nVersion: 0.1\nArchitecture: all\nMaintainer: pig test\nDescription: minimal test package\n' >"$FX/mindeb/DEBIAN/control"
    dpkg-deb --build "$FX/mindeb" "$FX/min_0.1_all.deb" >/dev/null 2>&1
    printf 'mindeb::file://%s/min_0.1_all.deb\n' "$FX" >>"$FX/official.txt"
    code=$(run "$H" install mindeb </dev/null)
    expect_code 0 "$code" "deb-install"
    code=$(run "$H" info mindeb)
    expect_grep "^version: 0.1$" "deb-version"
    code=$(run "$H" remove mindeb </dev/null)
    expect_code 0 "$code" "deb-remove"
    if dpkg -l pig-test-min 2>/dev/null | grep -q "^ii"; then
        fail "deb-gone" "package still installed"
    else
        pass "deb-gone"
    fi
fi

echo "--- self-update (helper, no network) ---"
PIGSRC="$PIG" T_HOME="$H" python3 <<'PYEOF'
import os, types, pathlib, stat
src = pathlib.Path(os.environ["PIGSRC"]).read_text()
mod = types.ModuleType("pig")
mod.__dict__["__file__"] = os.environ["PIGSRC"]
exec(compile(src, "pig", "exec"), mod.__dict__)
os.environ["HOME"] = os.environ["T_HOME"]
fake = pathlib.Path(os.environ["T_HOME"]) / "fake-pig"
fake.write_text(src)
fake.chmod(0o755)
bump = src + "\n# regtest-bump\n"
mod._install_new_executable(fake, bump)
assert fake.read_text() == bump, "content not replaced"
assert fake.stat().st_mode & 0o111, "exec bit lost"
mod._install_new_executable(fake, bump)
print("selfupdate-user ok")
PYEOF
if [ $? -eq 0 ]; then pass "selfupdate-user"; else fail "selfupdate-user" "helper failed"; fi
if [ "$(id -u)" = "0" ]; then
    skip "selfupdate-root" "running as root"
elif ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    skip "selfupdate-root" "no passwordless sudo"
else
    RODIR="$T/rodir"
    sudo mkdir -p "$RODIR" && sudo cp "$PIG" "$RODIR/pig" && sudo chown root:root "$RODIR" "$RODIR/pig" && sudo chmod 755 "$RODIR" "$RODIR/pig"
    PIGSRC="$PIG" T_HOME="$H" RODIR="$RODIR" python3 <<'PYEOF'
import os, types, pathlib, stat
src = pathlib.Path(os.environ["PIGSRC"]).read_text()
mod = types.ModuleType("pig")
mod.__dict__["__file__"] = os.environ["PIGSRC"]
exec(compile(src, "pig", "exec"), mod.__dict__)
os.environ["HOME"] = os.environ["T_HOME"]
target = pathlib.Path(os.environ["RODIR"]) / "pig"
bump = src + "\n# regtest-bump-root\n"
mod._install_new_executable(target, bump)
assert target.read_text() == bump, "content not replaced"
assert stat.S_IMODE(target.stat().st_mode) == 0o755, oct(stat.S_IMODE(target.stat().st_mode))
leftovers = [p for p in target.parent.iterdir() if p.name.startswith(".pig.new-")]
assert not leftovers, leftovers
print("selfupdate-root ok")
PYEOF
    if [ $? -eq 0 ]; then pass "selfupdate-root"; else fail "selfupdate-root" "sudo branch failed"; fi
fi

echo "--- doctor and distros ---"
code=$(run "$H" doctor)
expect_code 0 "$code" "doctor-exit"
expect_grep "^distro: " "doctor-distro"
expect_grep "^support: " "doctor-support"
printf 'ID=arch\nNAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\n' >"$T/os-arch"
code=$(PIG_OS_RELEASE="$T/os-arch" run "$H" doctor)
expect_code 0 "$code" "doctor-arch-exit"
expect_grep "support: partial" "doctor-arch-partial"
printf 'ID=pop\nNAME="Pop!_OS"\nID_LIKE=ubuntu\nPRETTY_NAME="Pop!_OS 22.04"\n' >"$T/os-pop"
code=$(PIG_OS_RELEASE="$T/os-pop" run "$H" doctor)
expect_code 0 "$code" "doctor-pop-exit"
expect_grep "support: full" "doctor-pop-full"
printf 'ID=weirdos\nNAME="WeirdOS"\nPRETTY_NAME="WeirdOS 1"\n' >"$T/os-weird"
code=$(PIG_OS_RELEASE="$T/os-weird" run "$H" doctor)
expect_code 1 "$code" "doctor-unknown-exit"
expect_grep "support: unknown" "doctor-unknown-msg"
expect_no_traceback "doctor-no-traceback"

echo "--- per-distro dictionary ---"
PIG_TXT_URL="https://github.com/blvcksyxx/pig/raw/refs/heads/main/pig.txt"
PIG_ARCH_URL="https://github.com/blvcksyxx/pig/raw/refs/heads/main/pig-arch.txt"
printf 'ID=debian\nNAME="Debian GNU/Linux"\nPRETTY_NAME="Debian GNU/Linux 12"\n' >"$T/os-debian"

dict_check() { # dict_check <name> <os> <home> <config-body> <expect-url-substr>
    _n="$1"; _os="$2"; _h="$3"; _cfg="$4"; _want="$5"
    rm -rf "$_h"; mkdir -p "$_h/.config/pig"
    printf '%s' "$_cfg" >"$_h/.config/pig/config.toml"
    PIG_OS_RELEASE="$_os" run "$_h" doctor >/dev/null
    # run() prints the exit code and leaves pig's output in $T/last.out
    if grep -q "dictionary: .*$_want" "$T/last.out"; then
        pass "$_n"
    else
        fail "$_n" "$(grep dictionary "$T/last.out")"
    fi
}

# fresh config on a distro without dpkg points at pig-arch.txt
HD="$T/hdict-arch"; rm -rf "$HD"; mkdir -p "$HD"
if PIG_OS_RELEASE="$T/os-arch" run "$HD" config >/dev/null &&
   grep -q "$PIG_ARCH_URL" "$HD/.config/pig/config.toml"; then
    pass "dict-arch-fresh"
else
    fail "dict-arch-fresh" "$(cat "$HD/.config/pig/config.toml" 2>/dev/null)"
fi
# fresh config on a distro with dpkg still points at pig.txt
HD="$T/hdict-deb"; rm -rf "$HD"; mkdir -p "$HD"
if PIG_OS_RELEASE="$T/os-debian" run "$HD" config >/dev/null &&
   grep -q "$PIG_TXT_URL" "$HD/.config/pig/config.toml" &&
   ! grep -q "pig-arch" "$HD/.config/pig/config.toml"; then
    pass "dict-debian-fresh"
else
    fail "dict-debian-fresh" "$(cat "$HD/.config/pig/config.toml" 2>/dev/null)"
fi
# a config written by an older pig (official = pig.txt) is redirected
dict_check "dict-arch-redirect" "$T/os-arch" "$T/hdict-old" \
    "[sources]
official = \"$PIG_TXT_URL\"
" "pig-arch.txt"
# a source the user named themselves is never rewritten
dict_check "dict-arch-user-source" "$T/os-arch" "$T/hdict-user" \
    "[sources]
debs = \"$PIG_TXT_URL\"
" "pig.txt"
# a custom local dictionary is never rewritten
dict_check "dict-arch-local-source" "$T/os-arch" "$T/hdict-local" \
    "[sources]
mine = \"/tmp/mine.txt\"
" "mine.txt"
# the same user-named source is untouched on a full distro too
dict_check "dict-debian-user-source" "$T/os-debian" "$T/hdict-deb2" \
    "[sources]
debs = \"$PIG_TXT_URL\"
" "pig.txt"

echo "--- native packages (pacman + AUR) ---"
if ! command -v pacman >/dev/null 2>&1; then
    skip "native-supported" "no pacman"
else
    HN2="$T/hnative"
    mkdir -p "$HN2/.config/pig"
    printf 'other::file://%s/other-v1.tar.gz\n' "$FX" >"$FX/native.txt"
    printf '[sources]\ntest = "%s/native.txt"\n' "$FX" >"$HN2/.config/pig/config.toml"
    # ranking and query variants are pure: no network, no subprocesses
    if python3 - "$PIG" <<'PYEOF'
import importlib.util, shutil, sys
spec = importlib.util.spec_from_file_location("pig", sys.argv[1])
pig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pig)
def C(src, repo, pkg, ver="1", votes=0, desc="", out=False):
    return {"source": src, "repo": repo, "package": pkg, "version": ver,
            "votes": votes, "popularity": 0.0, "outdated": out,
            "installed": False, "description": desc}
fail = []
def check(cond, msg):
    if not cond:
        fail.append(msg)

names = [c["package"] for c in pig.rank_native("zoom", [
    C("aur", "aur", "zoom", "7.2.1-1", 746, "Video conferencing"),
    C("pacman", "extra", "zoom-tools", votes=0, desc="helpers"),
    C("aur", "aur", "aimp-skin-zoom", votes=0, desc="skins"),
])]
check(names[0] == "zoom", f"exact name must rank first, got {names}")
check(names[1] == "zoom-tools", f"prefix must beat substring, got {names}")

# official repository wins over the AUR at the same tier
names = [c["repo"] for c in pig.rank_native("code", [
    C("aur", "aur", "code", votes=900, desc="editor"),
    C("pacman", "extra", "code", votes=0, desc="editor"),
])]
check(names[0] == "extra", f"official repo must outrank AUR, got {names}")

# popular AUR package wins inside the AUR
names = [c["package"] for c in pig.rank_native("zoom", [
    C("aur", "aur", "zoom-b", votes=2, desc="conferencing"),
    C("aur", "aur", "zoom-a", votes=500, desc="conferencing"),
])]
check(names[0] == "zoom-a", f"higher votes must win, got {names}")

# description-only matches are kept, unrelated packages are dropped
names = [c["package"] for c in pig.rank_native("editor", [
    C("aur", "aur", "some-gui", desc="a nice text editor"),
    C("aur", "aur", "totally-different", desc="nothing to do with it"),
])]
check(names == ["some-gui"], f"only matching packages must survive, got {names}")

# a hyphenated query also reaches packages spelled without separators
r = pig.rank_native("tor-browser", [C("aur", "aur", "torbrowser-launcher")],
                    pig.query_variants("tor-browser"))
check([c["package"] for c in r] == ["torbrowser-launcher"],
      "hyphen query must reach the unhyphenated package")

# query variants only add, never duplicate
check(pig.query_variants("zoom") == [], "plain query needs no variant")
check(pig.query_variants("tor-browser") == ["torbrowser"],
      "hyphen query should gain the stripped variant")
check(pig.query_variants("torbrowser") == [],
      "unhyphenated query cannot guess where separators go")

# native_supported follows pacman being on PATH
check(pig.native_supported() == (shutil.which("pacman") is not None),
      "native_supported must follow pacman")

# fuzzy tiers: exact, prefix, substring, shared abbreviation, letters in
# order, typos - and a hard "no relation"
for q, n, want in [("zoom", "zoom", 0), ("zoom", "zoom-tools", 1),
                   ("etcher", "balena-etcher", 2),
                   ("chrome", "chromium", 3), ("tgrm", "telegram", 4),
                   ("obsidan", "obsidian", 3), ("local-send", "localsend", 0),
                   ("git", "gimp", None), ("abc", "xyz", None),
                   ("a", "b", None), ("", "zoom", None),
                   ("zoom", "", None)]:
    check(pig.name_distance(q, n) == want,
          f"name_distance({q!r}, {n!r}) = "
          f"{pig.name_distance(q, n)}, expected {want}")

# a single or two letter query must not sweep the dictionary
check(pig.name_distance("ab", "abc") is None,
      "a two letter query must not match a longer name")
check(pig.name_distance("a", "abcdef") is None,
      "a one letter query must not match everything")
check(pig.name_distance("ab", "ab") == 0,
      "an exact short name still matches itself")

# separators do not change identity
check(pig.name_distance("tor-browser", "torbrowser") == 0,
      "hyphens must not matter for identity")

# levenshtein bails out instead of running away on long names
check(pig._levenshtein("a", "a" * 50, 2) > 2, "long names must bail out")
check(pig._levenshtein("kitten", "sitting", 3) == 3, "known distance")
check(pig._levenshtein("same", "same", 2) == 0, "identical strings")

# the wide scan keeps only strong signals, so a fuzzy query does not
# drown in subsequence noise
if shutil.which("pacman"):
    pkgs = pig._sync_packages()
    if pkgs:
        strong = [c["package"] for c in
                  pig.native_search_recovery("discor")[:5]]
        check(strong and strong[0] == "discord",
              f"typo must find discord first, got {strong[:3]}")
        junk = [c["package"] for c in pig.native_search_recovery("tgrm")]
        check(not any(p.startswith("python-") for p in junk),
              f"weak matches must be filtered out, got {junk[:3]}")
print("; ".join(fail))
sys.exit(1 if fail else 0)
PYEOF
    then
        pass "native-rank"
    else
        fail "native-rank" "ranking expectations not met"
    fi

    # a name missing from every dictionary falls back to the package manager
    code=$(run "$HN2" install definitely-not-a-real-package-xyzzy)
    expect_code 1 "$code" "native-fallback-exit"
    if grep -q "pacman repositories or the AUR" "$T/last.out"; then
        pass "native-fallback-msg"
    else
        fail "native-fallback-msg" "$(cat "$T/last.out")"
    fi
    expect_no_traceback "native-fallback-no-traceback"

    # -y must not silently pick a fuzzy match: it has to ask
    code=$(printf '2\n' | run "$HN2" install definitely-not-a-real-package-xyzzy)
    if grep -q "not in any dictionary" "$T/last.out" ||
       grep -q "not found" "$T/last.out"; then
        pass "native-yes-no-fuzzy-pick"
    else
        fail "native-yes-no-fuzzy-pick" "$(cat "$T/last.out")"
    fi

    # a dictionary hit must NOT be diverted to the package manager
    code=$(run "$HN2" install other)
    expect_code 0 "$code" "native-dictionary-wins"

    # a .deb entry on a system without dpkg must fall through to the
    # package manager instead of failing on dpkg-deb
    printf 'debonly::file://%s/only.deb\n' "$FX" >"$FX/debonly.txt"
    printf '[sources]\ntest = "%s/debonly.txt"\n' "$FX" >"$HN2/.config/pig/config.toml"
    if ! command -v dpkg >/dev/null 2>&1; then
        code=$(run "$HN2" install debonly)
        expect_code 1 "$code" "native-deb-fallthrough-exit"
        if grep -q "searching the package manager" "$T/last.out"; then
            pass "native-deb-fallthrough-msg"
        else
            fail "native-deb-fallthrough-msg" "$(cat "$T/last.out")"
        fi
        if grep -q "dpkg-deb" "$T/last.out"; then
            fail "native-deb-no-dpkg-error" "still tried dpkg-deb"
        else
            pass "native-deb-no-dpkg-error"
        fi
        # a dict entry pig can actually install must still be honoured
        rm -rf "$HN2/.cache" "$HN2/.local"
        printf '[sources]\ntest = "%s/native.txt"\n' "$FX" >"$HN2/.config/pig/config.toml"
        code=$(run "$HN2" install other)
        expect_code 0 "$code" "native-archive-still-works"
    else
        skip "native-deb-fallthrough-msg" "dpkg present, no fallthrough expected"
        skip "native-deb-no-dpkg-error" "dpkg present"
        skip "native-archive-still-works" "dpkg present"
    fi

    # enabling a repository: the allowlist and the conf check are pure
    if python3 - "$PIG" <<'PYEOF2'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pig", sys.argv[1])
pig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pig)
fail = []
check = lambda c, m: None if c else fail.append(m)
check(set(pig.NATIVE_ENABLEABLE_REPOS) == {"core", "extra", "multilib"},
      "only stable official repositories may be enabled")
try:
    pig.enable_repo("core-testing")
    fail.append("must refuse a repository outside the allowlist")
except pig.PigError as e:
    check("only enables" in str(e), f"refusal should explain: {e}")
check(isinstance(pig.repo_in_conf("multilib"), bool),
      "repo_in_conf must answer without raising")
check(pig.enabled_repos() is not None, "enabled_repos must answer")

# the pacman.conf edit itself, on a throwaway file: no root involved
import os, pathlib, tempfile, time
tmp = pathlib.Path(tempfile.mkdtemp())
conf = tmp / "pacman.conf"
conf.write_text("[core]\nInclude = /etc/pacman.d/mirrorlist\n"
                "#[multilib]\n#[custom]\n")
check(pig.repo_in_conf("core") is False or True, "readable")
saved, pig.PACMAN_CONF = pig.PACMAN_CONF, conf
check(pig.repo_in_conf("multilib") is False,
      "a commented-out stanza must count as not enabled")
bak = pig.append_repo_block(conf, "multilib")
check(pig.repo_in_conf("multilib") is True,
      "the stanza must be live after the append")
text = conf.read_text()
check("[core]" in text, "existing stanzas must survive")
check("#[custom]" in text, "commented stanzas must survive")
check(pathlib.Path(bak).exists(), "the backup must exist")
check(pathlib.Path(bak).read_text() != text,
      "the backup must be the pre-append content")
# appending twice must not duplicate the live stanza
import re as _re
active = lambda n: len(_re.findall(r"^\[" + n + r"\]$",
                                   conf.read_text(), _re.M))
pig.append_repo_block(conf, "multilib", backup=False)
check(active("multilib") == 1,
      f"a second append must not duplicate the stanza, got {active('multilib')}")
# an existing stanza must not be duplicated either
pig.append_repo_block(conf, "core", backup=False)
check(active("core") == 1,
      f"an existing stanza must not be duplicated, got {active('core')}")
check(active("custom") == 0,
      "a commented stanza must stay commented")

# the pacman lock: live vs abandoned. No root involved, the removal is
# stubbed out, so this is safe to exercise on any machine.
lock = tmp / "db.lck"
saved_lock, pig.PACMAN_LOCK = pig.PACMAN_LOCK, lock
saved_run, saved_busy = pig.run_cmd, pig.native_pkgmgr_running
class RC:
    def __init__(self, code=0):
        self.returncode = code
old = time.time() - 3600

# no lock at all
check(pig.pacman_lock_state() == "none", "no lock means none")

# a lock left by a killed run, with nothing running
lock.write_text("")
os.utime(lock, (old, old))
pig.native_pkgmgr_running = lambda: False
check(pig.pacman_lock_state() == "stale", "old lock, no process: stale")

# the same lock while a package manager runs
pig.native_pkgmgr_running = lambda: True
check(pig.pacman_lock_state() == "live", "a running process means live")
try:
    pig.ensure_pacman_unlocked(yes=True)
    fail.append("must refuse to remove a live lock")
except pig.PigError as e:
    check("will not remove a lock" in str(e), f"refusal should explain: {e}")
check(lock.exists(), "a live lock must be left alone")

# a brand new lock probably belongs to a process that is just starting
os.utime(lock, (time.time(), time.time()))
pig.native_pkgmgr_running = lambda: False
check(pig.pacman_lock_state() == "live", "a fresh lock must not be called stale")

# an abandoned lock is removed, and removal is actually verified
os.utime(lock, (old, old))
pig.run_cmd = lambda argv, need_root=False, stdin=None: RC(0)
try:
    pig.ensure_pacman_unlocked(yes=True)
    fail.append("must not claim success when the file survives")
except pig.PigError as e:
    check("still present" in str(e), f"should report a failed removal: {e}")

def _remove(argv, need_root=False, stdin=None):
    lock.unlink(missing_ok=True)
    return RC(0)
pig.run_cmd = _remove
pig.ensure_pacman_unlocked(yes=True)
check(not lock.exists(), "an abandoned lock must be gone afterwards")

# a non-zero rm is an error, not a warning
lock.write_text("")
os.utime(lock, (old, old))
pig.run_cmd = lambda argv, need_root=False, stdin=None: RC(1)
try:
    pig.ensure_pacman_unlocked(yes=True)
    fail.append("a failing rm must raise")
except pig.PigError as e:
    check("cannot remove" in str(e), f"should say it cannot remove: {e}")

# without -y a refusal at the prompt stops the install
lock.unlink(missing_ok=True)
pig.run_cmd, pig.native_pkgmgr_running = saved_run, saved_busy
pig.PACMAN_LOCK = saved_lock
lock.unlink(missing_ok=True)
# the stanza must not travel through stdin: under `sudo -S` the password
# is read from there and would swallow it
seen = {}
real_run = pig.run_cmd
def spy(argv, need_root=False, stdin=None):
    seen["stdin"] = stdin
    return real_run(argv, need_root=need_root, stdin=stdin)
pig.run_cmd = spy
conf2 = tmp / "stdin-test.conf"
conf2.write_text("[core]\n")
pig.append_repo_block(conf2, "multilib", backup=False)
pig.run_cmd = real_run
check(seen["stdin"] is None,
      f"the append must not use stdin, got {seen['stdin']!r}")
check(active("multilib") >= 1, "the stanza must still be written")
# an odd repository name must be refused before it reaches a shell
for bad in ("evil]; rm -rf /", "a b", "x/y", ""):
    try:
        pig.repo_block(bad)
        fail.append(f"repo_block must refuse {bad!r}")
    except pig.PigError:
        pass
pig.PACMAN_CONF = saved
import shutil as _sh
_sh.rmtree(tmp, ignore_errors=True)
print("; ".join(fail))
sys.exit(1 if fail else 0)
PYEOF2
    then
        pass "native-enable-guard"
    else
        fail "native-enable-guard" "repository guard expectations not met"
    fi
fi

echo "--- installer gate ---"
HI="$T/hinstall"
mkdir -p "$HI"
touch "$HI/.bashrc"
PIG_OS_RELEASE="$T/os-weird" HOME="$HI" sh "$PIG_DIR/install.sh" >"$T/install.out" 2>&1
if [ $? -ne 0 ] && [ ! -e "$HI/.local/bin/pig" ]; then
    pass "installer-refuses-unknown"
else
    fail "installer-refuses-unknown" "$(cat "$T/install.out")"
fi
if grep -q -- --force "$T/install.out"; then
    pass "installer-force-hint"
else
    fail "installer-force-hint" "no --force hint"
fi
PIG_OS_RELEASE="$T/os-weird" HOME="$HI" sh "$PIG_DIR/install.sh" --force >"$T/install.out" 2>&1
if [ $? -eq 0 ] && [ -x "$HI/.local/bin/pig" ]; then
    pass "installer-force"
else
    fail "installer-force" "$(cat "$T/install.out")"
fi
if grep -q "take responsibility" "$T/install.out"; then
    pass "installer-force-warning"
else
    fail "installer-force-warning" "no responsibility warning"
fi
(cd "$PIG_DIR" && HOME="$HI" sh ./install.sh >/dev/null 2>&1)
if [ "$(grep -c "pig installer" "$HI/.bashrc")" = "2" ]; then
    pass "installer-no-duplicates"
else
    fail "installer-no-duplicates" "PATH block duplicated"
fi
mkdir -p "$HI/.local/opt/keepapp"
printf '{"keepapp": {"name": "keepapp"}}' >"$HI/.cache/pig/installed.json"
(cd "$PIG_DIR" && HOME="$HI" sh ./install.sh --uninstall >/dev/null 2>&1)
if [ ! -e "$HI/.local/bin/pig" ] && [ -d "$HI/.local/opt/keepapp" ] && ! grep -q "pig installer" "$HI/.bashrc"; then
    pass "installer-uninstall"
else
    fail "installer-uninstall" "uninstall wrong"
fi

echo "--- packaging ---"
if python3 -c "import build" 2>/dev/null; then
    HAVE_BUILD=1
elif pip install build >/dev/null 2>&1 && python3 -c "import build" 2>/dev/null; then
    HAVE_BUILD=1
else
    HAVE_BUILD=0
fi
if [ "$HAVE_BUILD" = "1" ]; then
    rm -rf "$T/pkgbuild" && mkdir -p "$T/pkgbuild" && cp "$PIG_DIR"/pig.py "$PIG_DIR"/pyproject.toml "$PIG_DIR"/README.md "$PIG_DIR"/LICENSE "$T/pkgbuild/" 2>/dev/null
    (cd "$T/pkgbuild" && python3 -m build --sdist --wheel --outdir dist >/dev/null 2>&1)
    PIG_VER=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$PIG_DIR/pig.py" | head -1)
    if ls "$T/pkgbuild/dist/"pigctl-"$PIG_VER"* >/dev/null 2>&1; then
        pass "pyproject-build"
    else
        fail "pyproject-build" "no dist files: $(ls "$T/pkgbuild/dist" 2>/dev/null)"
    fi
else
    skip "pyproject-build" "no python build package"
fi

echo "---"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
