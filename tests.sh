#!/bin/sh
# pig tests v1.1.
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
    if ls "$T/pkgbuild/dist/"pig_pm-1.1.0* >/dev/null 2>&1; then
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
