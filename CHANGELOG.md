# changelog

## v1.4.1

- fix: the stanza enabling a repository travelled through stdin, which
  `sudo -S` consumes for the password, so the write silently did
  nothing; it now travels through a temporary file and the result is
  verified by reading the file back
- fix: the backup and the append lost `need_root`, so writing
  /etc/pacman.conf failed with "Permission denied"
- repository names are validated before being put into a shell command

## v1.4.0

- fuzzy package names: exact, prefix, substring, shared abbreviation,
  letters in order and one or two typos; separators are ignored, so
  `torbrowser` and `tor-browser` are the same name
- widened search when the literal one finds nothing: a stem search
  (`veskp` still reaches `vesktop`) and a comparison against every
  package in the enabled repositories (`discor` reaches `discord`)
- weak matches are never used to choose out of 15000 packages, and a
  one or two character query matches nothing but itself
- a `.deb` dictionary entry on a system without `dpkg` now falls
  through to the package manager instead of failing on `dpkg-deb`
- pig offers to enable a disabled repository itself: appends the
  stanza to `/etc/pacman.conf`, keeps a `.pig-bak`, verifies the
  result and refreshes the databases; only `core`, `extra` and
  `multilib` are ever enabled this way
- near-miss suggestions when a name is not found anywhere

## v1.3.0

- fallback to the system package manager: a name no dictionary knows
  is looked up in `pacman` and the AUR, the matches are listed and the
  user picks (Arch and other pacman systems)
- ranking: exact name, then prefix, then substring, then description;
  official repositories before the AUR, more popular AUR packages
  first; at most 10 candidates shown
- `-y` installs only on a single exact name match; anything fuzzier
  still asks, and cancels instead of guessing without a terminal
- AUR installs go through `paru`, then `yay`, with a clear error when
  neither is installed; official repositories use `pacman -S`
- `pig info`, `pig installed` and `pig remove` understand native
  records; `pig remove` uses `pacman -Rns`
- `pig upgrade` compares versions with `vercmp`, so epochs and package
  release numbers order correctly
- a package that exists only in a disabled repository (`steam` in
  `multilib`) is reported instead of being silently replaced by AUR
  lookalikes
- `pig doctor` reports enabled repositories and the AUR helper
- README no longer claims pig never manages system packages

## v1.2.0

- new `pig-arch.txt` dictionary for distributions without `dpkg`
  (Arch, Fedora, NixOS, ...): archives and shell installers only
- pig picks it automatically: a stock `official` source is redirected
  to `pig-arch.txt` on any distribution `pig doctor` reports as
  `partial`; a dictionary configured by the user is never rewritten
- fresh configs on those distributions are written with `pig-arch.txt`
- `pig doctor` prints the dictionary in use; `pig config` explains why
- executable pick: paths under a `debug/` directory are no longer
  candidates (fixes the Tor expert bundle), and the fallback now takes
  the shallowest remaining candidate instead of refusing whenever more
  than one exists (fixes VSCodium)
- `check_installs.py`: installs every dictionary entry in a throwaway
  `HOME` to verify it end to end
- dictionary fixes: `vesktop` (wrong asset name), `cursor` (new url
  format), `anydesk` (unversioned url is gone), `opencode` (missing
  `-deb` suffix), `ayugram` (the entry pointed at a GitHub *source*
  tarball with no binary; AyuGram ships no linux build at all, removed)
- dictionary refresh: tor 15.0.21 -> 15.0.24, burpsuite 2026.7.3 ->
  2026.9.2, obsidian 1.13.7 -> 1.14.4, dbeaver 26.2.1 -> 26.2.2,
  insomnia 13.2.0 -> 13.3.1, github-desktop 3.4.9 -> 3.4.13,
  slack 4.52.155 -> 4.52.178, rpi-imager 2.0.11.1 -> 2.0.12
- vscode and cursor now track the vendor's latest build instead of a
  pinned version

## v1.1.0

- distro support tiers and `pig doctor` (full / partial / unknown,
  see `DISTROS.md`)
- installer refuses unknown distributions unless forced
  (`sh install.sh --force`, at your own responsibility)
- PyPI packaging (`pyproject.toml`, project `pigctl`, command `pig`)
- self-update points at the published `pig.py`; a 404 now says
  the file is not published instead of a bare download error
- `install.sh` works with the `pig.py` filename

## v1.0.0

First full release.

- package installation (`pig install`, with `-y`/`--yes`)
- removal (`pig remove`), including legacy cache-dir installs
- search/list (`pig search`, `pig list`)
- installed list (`pig installed`) and package details (`pig info`)
- multiple dictionaries, local dictionary files
- aliases (separate keys sharing one url)
- per-source conflict choice
- safe archive extraction (no `extractall`; `../`, absolute paths,
  escaping symlinks/hardlinks and special files rejected;
  setuid/setgid stripped)
- archive application installation (`~/.local/opt/<name>` +
  `~/.local/bin/<name>` launcher; executable picked by name,
  never guessed; atomic swap on upgrade, old version kept on failure)
- user-local launchers (symlinks, no sudo, foreign files never clobbered)
- deb installation (`dpkg -i`, dependency fix via system tools,
  `Package`/`Version` recorded; version shown only when known)
- shell installers (shebang required, run as `./installer.sh`;
  automatic removal refused, record kept)
- type detection by extension, final url after redirects,
  `Content-Disposition` filename, magic bytes fallback
- update (dictionary cache refresh + self-update: direct atomic
  replace in user locations, sudo copy+rename for root-owned ones,
  verified, current install kept on error)
- url-based upgrade (per-package errors, non-zero exit)
- config (`~/.config/pig/config.toml`, `tomllib` or built-in parser)
- cache (`~/.cache/pig`; `pig clean` removes only temp files)
- installed state (`installed.json`: name, url, source, path,
  executable, launcher, deb package/version)
- user-local installer (`sh install.sh`, bash/zsh PATH handling
  without duplicates, `--uninstall` keeps applications and records)
- sudo only per-operation, `SUDO_USER` home resolution
