# changelog

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
