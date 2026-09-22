# pig

pig installs linux applications from plain-text dictionaries.

One executable python file, standard library only. No dependencies,
no database, no background processes. It does not replace apt and does
not manage system packages.

## features

- install/remove applications from remote or local dictionaries
- `.deb`, `.tar.gz`, `.tar.xz` and `.sh` installers
- archive applications land in `~/.local/opt` with a launcher in `~/.local/bin`
- multiple dictionaries, aliases, per-source conflict choice
- url-based upgrade, self-update, temp cache cleanup
- user-local install, no sudo by default
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

## dictionaries

Format, one entry per line:

```text
name::url
```

Empty lines, `#` comments and lines without `::` are ignored.
Duplicates keep the first entry.

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

See `CHANGELOG.md`. Current release: `v1.0.0`.
