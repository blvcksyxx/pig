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

## partial support

`.tar.gz`, `.tar.xz` and `.sh` work. `.deb` packages need `dpkg`,
which these distributions do not ship.

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
