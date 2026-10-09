# supported distributions

pig itself runs on any linux distribution with `python3` (standard
library only). What differs is `.deb` support, which needs `dpkg`.

Check yours with:

```sh
pig doctor
```

## full support

`.deb`, `.tar.gz`, `.tar.xz` and `.sh`, no limitations.

- Debian
- Ubuntu
- Linux Mint
- Kali Linux
- Pop!_OS
- Zorin OS
- MX Linux
- Raspberry Pi OS (Raspbian)
- elementary OS
- Parrot OS
- PureOS
- Devuan
- Deepin

Debian/Ubuntu derivatives not listed here are usually picked up
automatically through `ID_LIKE=debian` / `ID_LIKE=ubuntu`
in `/etc/os-release`.

## full support

`.deb`, `.tar.gz`, `.tar.xz` and `.sh`, no limitations.

- Debian
- Ubuntu
- Linux Mint
- Kali Linux
- Pop!_OS
- Zorin OS
- MX Linux
- Raspberry Pi OS (Raspbian)
- elementary OS
- Parrot OS
- PureOS
- Devuan
- Deepin

Debian/Ubuntu derivatives not listed here are usually picked up
automatically through `ID_LIKE=debian` / `ID_LIKE=ubuntu`
in `/etc/os-release`.

## partial support

`.tar.gz`, `.tar.xz` and `.sh` work. `.deb` packages need `dpkg`,
which these distributions do not ship.

On these, the `pacman` ones additionally fall back to the system
package manager and the AUR for names no dictionary knows (see README,
"system packages"). The rest do not.

- Arch Linux
- Manjaro
- EndeavourOS
- Garuda Linux
- Fedora
- RHEL / CentOS / AlmaLinux / Rocky Linux / Oracle Linux
- openSUSE Leap / Tumbleweed
- Gentoo
- Alpine Linux
- Void Linux
- NixOS
- Slackware

On these distributions pig switches to the `pig-arch.txt` dictionary,
which lists only archives and shell installers, so `pig install` has
something to work with. `pig doctor` shows the dictionary in use:

```text
support: partial (archives, shell; no dpkg)
dictionary: pig-arch.txt
```

A config that names its own dictionary keeps it; see the README
section "distributions without dpkg".

## unknown distributions

Anything else reports `support: unknown` from `pig doctor`.
Archives and shell installers will most likely still work, since pig
needs nothing but `python3`. The installer refuses unknown
distributions unless forced:

```sh
sh install.sh --force
```

Forcing means you take responsibility for your own system:
untested combinations may behave unexpectedly. If pig works on your
distro, report it so the list grows.
