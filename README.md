# pig

pig installs linux applications from plain-text dictionaries.

One executable python file, standard library only. No dependencies,
no database, no background processes. It does not replace apt.

Archives and shell installers are user-local: they land in `~/.local`
and need no root. On pacman systems a name that no dictionary knows is
handed to `pacman` or the AUR instead — those are real system packages
and they go through `sudo` (see "system packages").

## features

- install/remove applications from remote or local dictionaries
- `.deb`, `.tar.gz`, `.tar.xz` and `.sh` installers
- archive applications land in `~/.local/opt` with a launcher in `~/.local/bin`
- multiple dictionaries, aliases, per-source conflict choice
- url-based upgrade, self-update, temp cache cleanup
- user-local install, no sudo by default
- fallback to the system package manager: a name no dictionary knows is
  looked up in `pacman` and the AUR (see "system packages")
- per-distro dictionary: `pig-arch.txt` is selected automatically on
  distributions without `dpkg` (Arch, Fedora, NixOS, ...)
- distro check (`pig doctor`, see `DISTROS.md`)

## installation

Requirements: `python3`.

From git:

```sh
git clone https://github.com/blvcksyxx/pig
cd pig
sh install.sh
```

From PyPI (package `pigctl`, command stays `pig`):

```sh
pip install pigctl
```

The installer copies `pig` to `~/.local/bin/pig`, creates the needed directories,
initializes the config and adds `~/.local/bin` to PATH in `.bashrc` /
`.zshrc` (once, only if missing). No sudo, no system files.
The installer refuses unknown distributions unless forced
(`sh install.sh --force`, at your own responsibility).

## quick start

```sh
pig install postman
pig install -y postman
pig remove postman
pig search browser
pig list
pig installed
pig info postman
pig update
pig upgrade
pig clean
pig config
```

## commands

```text
pig install [-y] <name>   install application by name
pig remove [-y] <name>    remove application installed via pig
pig search <query>        search names and aliases in all dictionaries
pig list                  list available names and aliases
pig installed             list packages installed via pig
pig info <name>           show package details and install state
pig update                refresh dictionary cache, self-update pig
pig upgrade [-y]          reinstall packages whose url changed
pig clean                 delete temp files from the cache
pig config                show config file and sources
pig doctor                check distro support and environment
```

`-y` / `--yes` skips interactive confirmations. With several sources
for one name, `-y` uses the first source (config order) for `install`
and the recorded source for `upgrade`, and logs the pick.

Typical output:

```text
[pig] found postman
[pig] downloading...
[pig] extracting to /home/user/.local/opt/postman...
[pig] done
```

Errors look like this and never dump a traceback:

```text
[pig] error: package 'foobar' not found
```

## package formats

- `.deb` → `sudo dpkg -i <file>`. Missing dependencies are fixed with
  `sudo apt-get install -f -y`. The deb `Package` and `Version` fields
  are recorded.
- `.tar.gz` / `.tar.xz` → user-local application install (see below).
- `.sh` → `chmod +x`, executed as `./installer.sh`. A shebang is
  required; there is no `sh` fallback.
- Download urls without an extension are resolved by final url after
  redirects, then `Content-Disposition: filename=...`, then magic bytes.

## archive applications

Archives install without root:

1. the archive is extracted to a staging directory;
2. the application binary is picked (exact name, then case-insensitive
   match, vendor top-level symlink first; `.so`, helpers and other
   non-binaries are never chosen; if there is no single candidate,
   install fails with an error instead of guessing);
3. the tree is moved to `~/.local/opt/<name>/`;
4. a launcher symlink is created at `~/.local/bin/<name>`.

Nothing of the application stays in `~/.cache/pig/`.

## configuration

Config file:

```text
~/.config/pig/config.toml
```

```toml
[sources]
official = "https://github.com/blvcksyxx/pig/raw/refs/heads/main/pig.txt"
custom = "/home/user/my.txt"
```

Created automatically on first run. Local paths and `file://` urls
work as sources. Read with `tomllib` when the python version has it,
otherwise with a minimal built-in parser; written with stdlib only.

## distributions without dpkg

`.deb` needs `dpkg`, which Arch, Fedora, NixOS and friends do not ship.
The stock `pig.txt` is therefore mostly unusable there, so pig keeps a
second dictionary, `pig-arch.txt`, holding only `.tar.gz`, `.tar.xz` and
`.sh` entries.

The choice is automatic: on any distribution `pig doctor` reports as
`partial`, a source named `official` that points at the stock
`pig.txt` url is redirected to `pig-arch.txt` and reported as
`official-arch`:

```text
[pig] config: /home/user/.config/pig/config.toml
  official-arch = https://github.com/blvcksyxx/pig/raw/refs/heads/main/pig-arch.txt
```

A fresh config on such a distribution is written with `pig-arch.txt`
from the start. Only that one source is touched — a dictionary you
added under a name of your own is never rewritten. To keep the `.deb`
dictionary on a distribution without `dpkg`, name the source
yourself:

```toml
[sources]
debs = "https://github.com/blvcksyxx/pig/raw/refs/heads/main/pig.txt"
```

`pig doctor` then notes `dictionary: pig.txt (expected pig-arch.txt
for this distro)` so the mismatch stays visible.

`pig-arch.txt` is intentionally shorter: it lists only what pig can
unpack itself. Apps the vendor ships as `.deb`, `.rpm`, `.AppImage` or
`.pkg.tar.zst` are not listed there — but most of them are one command
away in `pacman` or the AUR, which pig finds for you (see "system
packages" below).

## system packages

When a name is in no dictionary and `pacman` exists, pig looks it up
in the enabled repositories and in the AUR, then shows what it found:

```text
$ pig install zoom
'zoom' is not in any dictionary, found in the package manager:
  1. aur/zoom 7.2.1-1 (AUR, 746 votes)
       Video Conferencing and Web Conferencing Server
  2. aur/zoom-citrix-plugin 7.0.11-1 (AUR, 2 votes)
       Zoom VDI Citrix plugin
choose package [1-2]:
```

Ordering is deliberate: exact name match first, then prefix, then
substring, then description match. Inside a rank an official repository
beats the AUR, and inside the AUR the more popular package wins. At
most ten candidates are shown.

Unlike everything else in pig, this writes to the system and uses
`sudo`. Official repositories go through `pacman -S`; AUR packages go
through an AUR helper, `paru` first, then `yay`. With neither
installed pig says so instead of failing obscurely.

`-y` only skips the question when there is exactly one exact name
match. Anything fuzzier still asks, because a wrong guess here changes
the system rather than `~/.local`. Under `-y` with no exact match and
no terminal, pig cancels instead of installing something arbitrary.

`pig info`, `pig installed` and `pig remove` all understand these
records; `pig remove` runs `pacman -Rns` (or the AUR helper's
equivalent) with `sudo`. `pig upgrade` compares the recorded version
against the one the package manager offers, using `vercmp` so epochs
and package release numbers compare correctly.

If a package exists only in a repository this machine has not enabled —
`steam` lives in `multilib` — pig offers to switch it on, appends the
stanza to `/etc/pacman.conf`, keeps a `.pig-bak` copy beside it and
refreshes the databases:

```text
[pig] 'steam' is in the multilib repository, which is not enabled (enabled: core, extra)
enable [multilib] and refresh the package databases? [y/N]:
```

Only `core`, `extra` and `multilib` are ever enabled this way; testing
repositories and anything custom stay your business. With `-y` the
question is skipped and shown instead.

## the pacman lock

pacman refuses to run while `/var/lib/pacman/db.lck` exists, and a
package manager that gets killed leaves that file behind — every later
run then stops on `could not lock database`.

pig tells a live lock from an abandoned one by looking at `/proc` for a
running `pacman`, `paru`, `yay` or `makepkg`, rather than trusting the
lock file:

- **nothing running** and the lock at least a minute old: it was
  abandoned, pig removes it and continues. With `-y` it says so
  instead of asking;
- **something running**: pig refuses and tells you to wait. It will not
  remove a lock belonging to a live process — that would corrupt
  somebody else's transaction;
- **lock younger than a minute**: treated as live, because a package
  manager may be starting at that moment.

pig cannot give itself priority over a running package manager; trying
would be a way to corrupt someone's install. What it can do is stop an
interrupted run from blocking every future one.

A `.deb` entry that pig cannot install here — no `dpkg` — is not an
error either: it falls through to the same search, so a dictionary
written for Debian still finds its packages on Arch.

## fuzzy names

A name is matched against packages in this order, each weaker than the
last: exact, prefix, substring, a shared abbreviation of four or more
characters (`chrome` reaches `chromium`), letters in order (`tgrm`
reaches `telegram-desktop`), and finally one or two typos. Separators
do not matter: `tor-browser` and `torbrowser` are the same name.

If the literal search finds nothing, pig widens it: first a stem search
— the name cut short, so `veskp` still reaches `vesktop` — then a
comparison against every package in the enabled repositories, which is
what catches real typos like `discor` for `discord`.

Matches weaker than a shared abbreviation are never used to pick a
package out of the 15000 available, and a query of one or two
characters matches nothing but itself. The AUR has no bulk listing, so
a typo in the name of an AUR-only package stays out of reach — type it
closely. Nothing fuzzy is ever installed without being asked for.

## dictionaries

Format, one entry per line:

```text
name::url
```

Empty lines, `#` comments and lines without `::` are ignored.
Duplicates keep the first entry.

Two dictionaries ship with pig:

| file | used on | contains |
| --- | --- | --- |
| `pig.txt` | distributions with `dpkg` | everything, `.deb` included |
| `pig-arch.txt` | distributions without `dpkg` | archives and shell installers only |

Both are plain text in the repository root and can be used as an extra
`[sources]` entry on any distribution.

## checking entries

`check_links.py` resolves every url in a dictionary and reports the
status, the redirect target and the file type pig would detect:

```sh
python3 check_links.py pig.txt
```

`check_installs.py` goes further and runs a real `pig install` of every
entry in a throwaway `HOME`, which is what actually proves an entry
works end to end:

```sh
python3 check_installs.py pig-arch.txt
```

Shell installers (`.sh`) are downloaded and checked for a shebang but
not executed: they write to `/opt` and call `apt`/`dnf`.

## aliases

An alias is a separate key with the same url:

```text
vscode::https://...
code::https://...
```

`pig list` groups them:

```text
vscode
  aliases: code
```

## source conflicts

If one name exists in several dictionaries, pig does not pick silently:

```text
found telegram in:
  1. official
  2. custom
choose source [1-2]:
```

## update / upgrade

`pig update` refreshes the local dictionary cache and self-updates `pig`
from the official github source. User-owned locations are replaced
directly (atomic rename), root-owned ones via `sudo`
(copy to a temp name + rename, verified afterwards).
A failed update keeps the current install.

`pig upgrade` compares the saved `url` in `installed.json` with the
current dictionary `url`. On change it stages the new tree and swaps it
in; on failure the old version stays. A failing package does not stop
the others; the exit code is non-zero. Upgrade is url-based: pig does
not parse versions from html, metadata or third-party apis.

## installed applications

`pig installed` shows only what pig installed:

```text
postman
telegram
vscode
```

`pig info postman` shows details:

```text
[pig] postman


name: postman
source: official
type: tar.gz
url: https://...
installed: yes
path: ~/.local/opt/postman
launcher: ~/.local/bin/postman
```

A version line appears only when it is reliably known
(currently: the `Version` field of installed `.deb` packages).
Versions are never guessed.

Install state lives in:

```text
~/.cache/pig/installed.json
```

It stores name, url, source, install path, executable, launcher
(and deb package/version when known) — enough for remove and upgrade.

## cache

```text
~/.cache/pig/
```

Holds the dictionary cache, `installed.json` and temp files.
`pig clean` deletes temp/staging leftovers but keeps `dicts/`,
`installed.json` and all installed applications.

## uninstall

```sh
sh install.sh --uninstall
```

Removes the `pig` binary, temp cache files and the PATH block from
shell rc files. It keeps the config, `installed.json`, installed
applications, launchers and `~/.local/opt` — those need an explicit
user action.

## security

- tar extraction is manual, without `extractall`: `../`, absolute
  paths, escaping symlinks/hardlinks and special files are rejected;
  setuid/setgid bits are stripped.
- `remove` only deletes `~/.local/opt/<name>` (or the legacy cache dir)
  and pig's own launcher symlink; foreign files are refused.
- upgrades and self-updates stage first and swap atomically;
  failures keep the old version.
- no `sudo pig`: root is used per-operation only (`dpkg`, self-update
  into root-owned paths). Under sudo, pig resolves the invoking user's
  home via `SUDO_USER`.
- dictionaries are plain text fetched over https with a timeout and a
  local-cache fallback. pig does not verify checksums: only add
  dictionaries you trust, and inspect `.sh` installers before use.

## development

```sh
./tests.sh
```

Hermetic regression + functional suite: isolated HOME dirs, local
files and a local 127.0.0.1 server only. No network, no system changes
(except an empty test `.deb` when passwordless sudo allows it).

`check_links.py` and `check_installs.py` are the other half: they hit
the network to verify that every dictionary entry still resolves and
still installs. See "checking entries".

## license

PolyForm Noncommercial 1.0.0 (see `LICENSE`).

You may use, modify, fork and share pig for noncommercial purposes.
You must keep the copyright notice (`Copyright (c) 2026 @blvcksyxx`)
and the license text with any copy or fork. Commercial use is not
allowed under this license — contact the author for other terms.

## author

`@blvcksyxx`

```text
Copyright (c) 2026 @blvcksyxx
```

## changelog

See `CHANGELOG.md`. Current release: `v1.4.2`.
