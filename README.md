# cip-active-netlite-ui

Build and package Civil Infrastructure Platform (CIP) Super Long Term Support kernels on Arch based systems, then register them using kernel-install and Boot Loader Specification entries (BLS). This script helps you pick an active CIP branch, compiles it efficiently, creates Arch packages, and installs a boot menu entry titled "Arch Linux (CIP)".

> Works on Arch Linux and Arch derivatives like EndeavourOS. Do not run the script as root, the script will use sudo only for system changes.

<p align="center">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-green.svg"></a>
  <img alt="Arch" src="https://img.shields.io/badge/Arch-yes-blue.svg">
  <img alt="PRs welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg">
</p>

*(Optional) Add a short asciinema or GIF that shows the branch table and selection prompt.*

---

## Why CIP SLTS

The Civil Infrastructure Platform provides Super Long Term Support Linux kernels that receive security and bugfix maintenance for many years (often ten). This is useful when you want a stable base that changes very slowly, for example workstations that prize reliability or systems that must avoid frequent kernel churn.

---

## Features

* Discovers CIP branches and marks each as ACTIVE or STALE based on the most recent commit time, with a configurable threshold in days.
* Builds the selected branch using makepkg, produces two packages: `linux-cip*` and `linux-cip*-headers`.
* Uses kernel-install to add Boot Loader Specification entries, integrates with mkinitcpio. The boot entry is titled "Arch Linux (CIP)".
* Optional trimmed configs via `make localmodconfig`. Supports saving, loading, and merging `lsmod` profiles, which helps keep the kernel lean while reducing the risk of missing drivers.
* Incremental updates with a persistent build cache directory. ccache support is enabled by default.
* Update mode that reuses your last built branch when it is still marked ACTIVE.

---

## Requirements

The script checks for these tools and will stop if any are missing.

**Build chain**

* `git`, `gcc`, `make`, `bc`, `bison`, `flex`, `perl`, `openssl`, `pahole`, `ld`, `dtc`

**Packaging and archive**

* `makepkg`, `fakeroot`, `kmod`, `xz`, `zstd`, `tar`, `rsync`, `cpio`, `strip`, `base64`

**Kernel tools**

* `kernel-install` (from systemd), `mkinitcpio`

**Optional**

* `ccache` (recommended), `fzf` for nicer branch selection, `ninja` and `python3` if you enable the experimental Ninja path.

On Arch you can usually get most of the above with:

```bash
sudo pacman -S --needed base-devel git ccache pahole dtc rsync cpio mkinitcpio systemd
```

> Note: `kernel-install` is part of systemd on Arch. Ensure your `/boot` partition is mounted when installing kernels.

---

## Installation

Option A, recommended for transparency:

```bash
git clone https://github.com/ArchLars/cip-active-netlite-ui
cd cip-active-netlite-ui
```

Option B, quick try from a temp location (you can read the script first):

```bash
cd "$(mktemp -d)"
curl -fsSLO https://raw.githubusercontent.com/ArchLars/cip-active-netlite-ui/HEAD/cip-active-netlite-ui-optimized.sh
chmod +x cip-active-netlite-ui-optimized.sh
```

---

## Quick start

```bash
./cip-active-netlite-ui-optimized.sh
# Pick an ACTIVE branch when prompted
# Wait for build and packaging to finish
# Packages are installed with pacman, kernel-install adds a BLS entry

# Verify boot entries
bootctl list
```

Reboot when ready and select the "Arch Linux (CIP)" entry if your boot manager shows it.

---

## Usage

### Flags

* `--update` (use the last built ACTIVE branch and perform an incremental build)
* `--save-profile [name]` (save the current `lsmod` to `~/.config/cip-kernel/profiles/<name>.modules`)
* `--load-profile [name]` (export `LSMOD` to a saved profile for localmodconfig)
* `--merge-profiles` (merge all saved profiles into a single list that localmodconfig can consume)

### Environment variables (with defaults)

| Variable             | Default                         | Meaning                                                                              |
| -------------------- | ------------------------------- | ------------------------------------------------------------------------------------ |
| `THRESHOLD_DAYS`     | `120`                           | A branch is ACTIVE if its last commit is newer than this threshold (in days).        |
| `CCACHE_DIR`         | `~/.ccache-cip`                 | Location of ccache data.                                                             |
| `BUILD_CACHE_DIR`    | `~/.cache/cip-builds`           | Persistent per-branch build tree and state.                                          |
| `CONFIG_CACHE_DIR`   | `~/.config/cip-kernel`          | Config and profile storage.                                                          |
| `LSMOD_PROFILES_DIR` | `~/.config/cip-kernel/profiles` | Directory that holds saved `lsmod` profiles.                                         |
| `USE_CCACHE`         | `1`                             | Wrap compilers with ccache and tune ccache settings.                                 |
| `USE_NINJA`          | `0`                             | Experimental, not used by default.                                                   |
| `USE_LOCALMODCONFIG` | `1`                             | Use `make localmodconfig` to trim the kernel to loaded modules.                      |
| `INCREMENTAL_BUILD`  | `1`                             | Prefer incremental builds when possible.                                             |
| `DEBUG_SYMBOLS`      | `0`                             | Disable kernel debug info for faster, smaller builds. Set to `1` to keep debug info. |
| `INCLUDE_REBASE`     | unset                           | Include branches that end with `-rebase` in the picker when set.                     |

### Examples

Build with a saved hardware profile (for example, docked peripherals):

```bash
./cip-active-netlite-ui-optimized.sh --save-profile docked
# Later, before building again
./cip-active-netlite-ui-optimized.sh --load-profile docked
```

Fast updates:

```bash
# Uses last ACTIVE branch and performs an incremental build when possible
./cip-active-netlite-ui-optimized.sh --update
# or use the helper that this script writes next to your build files
./update-cip-kernel.sh
```

Localmodconfig caveat: it only sees modules that are loaded. If a device or feature was not in use, the relevant driver may be disabled. You can save multiple profiles and merge them to reduce that risk.

---

## What this script modifies or adds

* Creates or amends `/etc/kernel/install.conf` with `layout=bls` and `initrd_generator=mkinitcpio`.
* Creates `/etc/kernel/cmdline` if it does not exist, based on your current `/proc/cmdline` (removes `BOOT_IMAGE=` and `initrd=` keys).
* Installs a small plugin at `/etc/kernel/install.d/95-cip-title.install` that sets the BLS title to `Arch Linux (CIP)` whenever a kernel is added.
* Installs BLS entries under `/boot/loader/entries` and kernel assets under your boot partition, using `kernel-install`.

---

## Uninstall and rollback

Remove the packages, then clean up entries if any remain.

```bash
# Replace the names with your actual package names
sudo pacman -Rns linux-cip linux-cip-headers

# List kernels known to kernel-install
kernel-install list

# Remove any remaining entries by kernel version
sudo kernel-install remove <kver>

# Verify boot entries
bootctl list
```

If you intend to remove the BLS title plugin as well:

```bash
sudo rm -f /etc/kernel/install.d/95-cip-title.install
```


---

## License

MIT license. See [LICENSE](LICENSE). 

---

## Acknowledgements and references

* Civil Infrastructure Platform (overview): [https://www.cip-project.org](https://www.cip-project.org)
* CIP Wiki: [https://wiki.linuxfoundation.org/civilinfrastructureplatform/start](https://wiki.linuxfoundation.org/civilinfrastructureplatform/start)
* Arch Wiki, PKGBUILD: [https://wiki.archlinux.org/title/PKGBUILD](https://wiki.archlinux.org/title/PKGBUILD)
* Arch Wiki, Makepkg: [https://wiki.archlinux.org/title/Makepkg](https://wiki.archlinux.org/title/Makepkg)
* kernel-install manual: [https://www.freedesktop.org/software/systemd/man/latest/kernel-install.html](https://www.freedesktop.org/software/systemd/man/latest/kernel-install.html)
* Arch Wiki, kernel-install: [https://wiki.archlinux.org/title/Kernel-install](https://wiki.archlinux.org/title/Kernel-install)
* Boot Loader Specification: [https://uapi-group.org/specifications/specs/boot\_loader\_specification](https://uapi-group.org/specifications/specs/boot_loader_specification)
* Linux kernel docs, localmodconfig: [https://www.kernel.org/doc/html/latest/kbuild/kconfig.html#localmodconfig](https://www.kernel.org/doc/html/latest/kbuild/kconfig.html#localmodconfig)
