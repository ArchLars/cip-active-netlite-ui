#!/usr/bin/env bash
# cip-active-netlite-ui-v9.sh
# After selecting a CIP branch, clone, build, package with makepkg, then register with kernel-install using mkinitcpio.
# Produces a BLS entry titled "Arch Linux (CIP)" and uses only kernel-install for boot integration.

set -euo pipefail

BASE="https://kernel.googlesource.com/pub/scm/linux/kernel/git/cip/linux-cip"
CLONE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-120}"   # active if last commit < 120 days
NOW_EPOCH=$(date +%s)
CIP_WIKI_URL="https://wiki.linuxfoundation.org/civilinfrastructureplatform/start?do=edit"

need_cmd() { command -v "$1" >/dev/null 2>&1; }
curlq() { curl -fsSL "$1"; }
trim() { awk '{$1=$1;print}'; }

# Colors (respect NO_COLOR, TERM=dumb, allow FORCE_COLOR)
setup_colors() {
  RED=""; GREEN=""; RESET="";
  if [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]] && { [[ -t 1 ]] || [[ -n "${FORCE_COLOR:-}" ]]; }; then
    if need_cmd tput && tput colors >/dev/null 2>&1; then
      RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; RESET="$(tput sgr0)";
    else
      RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m';
    fi
  fi
}

month_end_epoch() {
  local ym="$1"
  TZ=UTC date -d "${ym}-01 +1 month -1 day 23:59:59" +%s 2>/dev/null || echo 0
}

diff_ymd() {
  local start="$1" end="$2"
  if (( end <= start )); then
    echo "0 yrs 0 mos 0 days"; return
  fi
  local sy sm sd ey em ed
  read -r sy sm sd < <(TZ=UTC date -u -d "@$start" '+%Y %m %d')
  read -r ey em ed < <(TZ=UTC date -u -d "@$end"   '+%Y %m %d')
  local months=$(( (10#$ey - 10#$sy)*12 + (10#$em - 10#$sm) ))
  local anchor
  anchor=$(TZ=UTC date -u -d "$sy-$sm-$sd + ${months} months" +%s)
  if (( anchor > end )); then
    months=$((months - 1))
    anchor=$(TZ=UTC date -u -d "$sy-$sm-$sd + ${months} months" +%s)
  fi
  local years=$(( months / 12 ))
  local mos=$(( months % 12 ))
  local days=$(( (end - anchor)/86400 ))
  (( days < 0 )) && days=0
  printf "%d yrs %d mos %d days\n" "$years" "$mos" "$days"
}

declare -A EOL_MAP
declare -A FIRST_MAP
build_eol_map() {
  local src
  if ! src="$(curlq "$CIP_WIKI_URL" 2>/dev/null)"; then
    return 1
  fi
  while IFS='|' read -r _ col_ver _ col_first col_eol _ _; do
    local ver="$(printf '%s' "$col_ver"   | trim)"
    local first="$(printf '%s' "$col_first" | trim)"
    local eol="$(printf '%s' "$col_eol"   | trim)"
    ver="${ver#SLTS v}"
    if [[ "$ver" =~ ^[0-9]+\.[0-9]+(-rt)?$ ]]; then
      [[ "$eol"   =~ ^[0-9]{4}-[0-9]{2}$        ]] && EOL_MAP["$ver"]="$eol"
      [[ "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && FIRST_MAP["$ver"]="$first"
    fi
  done < <(printf '%s\n' "$src" | awk -F'[|]' '/[|][[:space:]]*SLTS v[0-9]+\.[0-9]+/ {print}')
}

branch_to_eol_key() {
  local br="$1" ver rest
  if [[ "$br" =~ linux-([0-9]+\.[0-9]+)\.y-cip(.*) ]]; then
    ver="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    if [[ "$rest" == *-rt* ]]; then
      printf '%s-rt\n' "$ver"
    else
      printf '%s\n' "$ver"
    fi
  fi
}

# Discover branches, filter -rebase unless INCLUDE_REBASE is set
REFS_HTML="$(curlq "$BASE/+refs")"
mapfile -t BRANCHES_ALL < <(printf '%s\n' "$REFS_HTML" \
  | grep -oE 'linux-[0-9]+\.[0-9]+\.y-cip(-rt|-rebase)?' \
  | sort -Vu)

if ((${#BRANCHES_ALL[@]}==0)); then
  echo "No CIP branches found on +refs"
  exit 1
fi

BRANCHES=()
if [[ -n "${INCLUDE_REBASE:-}" ]]; then
  BRANCHES=("${BRANCHES_ALL[@]}")
else
  for b in "${BRANCHES_ALL[@]}"; do
    [[ "$b" == *-rebase ]] && continue
    BRANCHES+=("$b")
  done
fi

branch_head_epoch() {
  local br="$1" b64 epoch
  if ! b64="$(curlq "$BASE/+/refs/heads/$br?format=TEXT" 2>/dev/null)"; then
    echo 0; return
  fi
  epoch="$(printf '%s' "$b64" | base64 -d 2>/dev/null \
           | awk '/^committer /{print $(NF-1); exit}')"
  [[ "$epoch" =~ ^[0-9]+$ ]] && printf '%s\n' "$epoch" || echo 0
}

fmt_days_ago() {
  local d="$1"
  if   (( d <= 0 )); then echo "today"
  elif (( d == 1 )); then echo "1 day ago"
  else                   echo "$d days ago"
  fi
}

build_eol_map || true
setup_colors

declare -a BODY_SORTABLE=()
declare -a ACTIVE_SORTABLE=()

HEADER=$'Branch\tStatus\tLast Commit\tFirst Release\tEOL\tTime-to-EOL'

ACTIVE=()
for br in "${BRANCHES[@]}"; do
  epoch="$(branch_head_epoch "$br")"
  status="UNKNOWN"; age_str="-"
  if (( epoch > 0 )); then
    age_days=$(( (NOW_EPOCH - epoch)/86400 ))
    (( age_days < 0 )) && age_days=0
    status="STALE"
    (( NOW_EPOCH - epoch < THRESHOLD_DAYS*86400 )) && status="ACTIVE"
    age_str="$(fmt_days_ago "$age_days")"
    [[ "$status" == "ACTIVE" ]] && ACTIVE+=("$br")
  fi
  key="$(branch_to_eol_key "$br")"
  first_rel="${FIRST_MAP[$key]:-UNKNOWN}"
  eol="${EOL_MAP[$key]:-UNKNOWN}"
  eol_epoch=-1; tte="-"
  if [[ "$eol" != "UNKNOWN" ]]; then
    eol_epoch="$(month_end_epoch "$eol")"
    if (( eol_epoch > 0 )); then
      tte="$(diff_ymd "$NOW_EPOCH" "$eol_epoch")"
    else
      eol_epoch=-1
    fi
  fi
  row="$(printf "%s\t%s\t%s\t%s\t%s\t%s" "$br" "$status" "$age_str" "$first_rel" "$eol" "$tte")"
  BODY_SORTABLE+=( "$(printf "%s\t%s" "$eol_epoch" "$row")" )
  if [[ "$status" == "ACTIVE" ]]; then
    ACTIVE_SORTABLE+=( "$(printf "%s\t%s" "$eol_epoch" "$br")" )
  fi
done

sorted_body="$(
  printf "%s\n" "${BODY_SORTABLE[@]}" \
  | sort -t $'\t' -k1,1nr -k2,2 \
  | cut -f2-
)"

out="$HEADER"$'\n'"$sorted_body"
if need_cmd column; then
  out="$(printf "%s\n" "$out" | column -t -s $'\t')"
else
  out="$(printf "%s\n" "$out" | sed $'s/\t/  /g')"
fi
if [[ -n "${GREEN}${RED}${RESET}" ]]; then
  out="$(printf "%s\n" "$out" | sed -E "1! s/ACTIVE/${GREEN}&${RESET}/g; 1! s/STALE/${RED}&${RESET}/g")"
fi
printf "%s\n" "$out"

if ((${#ACTIVE[@]}==0)); then
  echo
  echo "No ACTIVE branches under the current threshold ($THRESHOLD_DAYS days)."
  exit 0
fi

echo
echo "Pick an ACTIVE branch:"
choice=""
ACTIVE_LIST_SORTED="$(
  printf "%s\n" "${ACTIVE_SORTABLE[@]}" \
  | sort -t $'\t' -k1,1nr -k2,2 \
  | cut -f2-
)"
if need_cmd fzf; then
  choice="$(printf "%s\n" "$ACTIVE_LIST_SORTED" | fzf --prompt="SLTS> " --height=10 --reverse)" || true
else
  PS3="Select branch> "
  ACTIVE_ARR=( $(printf "%s\n" "$ACTIVE_LIST_SORTED") )
  select br in "${ACTIVE_ARR[@]}"; do choice="$br"; break; done
fi
[[ -n "${choice:-}" ]] && echo "You selected: $choice"
[[ -z "${choice:-}" ]] && exit 0

############################################
# From here on: build, package, and install
############################################

# Hard requirements for build and packaging
require_tools=(
  git make gcc awk sed grep tar xz zstd bc perl bison flex openssl
  pahole ld dtc rsync cpio strip
  makepkg fakeroot
  kernel-install systemctl
  mkinitcpio
  base64
)
missing=()
for t in "${require_tools[@]}"; do need_cmd "$t" || missing+=("$t"); done
if ((${#missing[@]})); then
  echo "Missing required tools: ${missing[*]}"
  echo "Please install base-devel and the listed tools, then rerun."
  exit 1
fi

# Refuse to run makepkg as root
if (( EUID == 0 )); then
  echo "Do not run this script as root. It will elevate only for system steps."
  exit 1
fi

# Ensure kernel-install main config and cmdline exist
ensure_kernel_install_conf() {
  sudo mkdir -p /etc
  if [[ ! -f /etc/kernel/install.conf ]]; then
    echo "layout=bls" | sudo tee /etc/kernel/install.conf >/dev/null
    echo "initrd_generator=mkinitcpio" | sudo tee -a /etc/kernel/install.conf >/dev/null
  else
    if ! grep -q '^layout=' /etc/kernel/install.conf; then
      echo "layout=bls" | sudo tee -a /etc/kernel/install.conf >/dev/null
    fi
    if ! grep -q '^initrd_generator=' /etc/kernel/install.conf; then
      echo "initrd_generator=mkinitcpio" | sudo tee -a /etc/kernel/install.conf >/dev/null
    fi
  fi
}

ensure_cmdline() {
  if [[ ! -f /etc/kernel/cmdline ]]; then
    # Derive a sane default from the current cmdline, drop BOOT_IMAGE= and initrd= tokens
    if [[ -r /proc/cmdline ]]; then
      awk '{
        for(i=1;i<=NF;i++){
          if($i ~ /^BOOT_IMAGE=/) continue;
          if($i ~ /^initrd=/) continue;
          printf("%s%s", (out++?" ":""), $i)
        }
        printf("\n")
      }' /proc/cmdline | sudo tee /etc/kernel/cmdline >/dev/null
    else
      echo "root=PARTUUID=XXXX quiet" | sudo tee /etc/kernel/cmdline >/dev/null
    fi
  fi
}

# Kernel-install plugin to rename the entry title to "Arch Linux (CIP)"
install_cip_title_plugin() {
  local tmp="$(mktemp)"
  cat >"$tmp" <<'PLUG'
#!/bin/sh
# 95-cip-title.install
# Force BLS entry title to "Arch Linux (CIP)" for CIP kernels.

set -eu

cmd="${1:-}"
kver="${2:-}"

# Only act on add, and only for BLS layout
[ "$cmd" = "add" ] || exit 0
[ "${KERNEL_INSTALL_LAYOUT:-}" = "bls" ] || exit 0

# Find the entry file(s) created by 90-loaderentry
entries_dir="${KERNEL_INSTALL_BOOT_ROOT:-/boot}/loader/entries"
token="${KERNEL_INSTALL_ENTRY_TOKEN:-}"
[ -n "$token" ] || exit 0

# Pattern: $BOOT/loader/entries/${token}-${kver}.conf  (tries may append suffixes)
for f in "$entries_dir/${token}-${kver}"*.conf; do
  [ -f "$f" ] || continue
  # Replace the title line
  sed -i -E 's/^title .*/title Arch Linux (CIP)/' "$f"
done
PLUG
  sudo install -Dm755 "$tmp" "/etc/kernel/install.d/95-cip-title.install"
  rm -f "$tmp"
}

ensure_kernel_install_conf
ensure_cmdline
install_cip_title_plugin

# Build workspace
BR_SAFE="$(printf '%s' "$choice" | sed 's@[^A-Za-z0-9._-]@-@g')"
WORKDIR="cip-build-$BR_SAFE"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Write linux-cip.install (pacman scriptlet)
cat > linux-cip.install <<'INST'
post_install() {
  local full="$1"
  local kver="${full%%-*}"   # strip pkgrel to get kernel release
  _ensure_title_plugin
  echo "Running: kernel-install add ${kver}"
  kernel-install add "${kver}" "/usr/lib/modules/${kver}/vmlinuz" || true
}

post_upgrade() {
  local new="$1" old="$2"
  local knew="${new%%-*}"
  local kold="${old%%-*}"
  _ensure_title_plugin
  echo "Running: kernel-install add ${knew}"
  kernel-install add "${knew}" "/usr/lib/modules/${knew}/vmlinuz" || true
  if [ "${kold}" != "${knew}" ]; then
    echo "Running: kernel-install remove ${kold}"
    kernel-install remove "${kold}" || true
  fi
}

post_remove() {
  local old="$1"
  local kold="${old%%-*}"
  echo "Running: kernel-install remove ${kold}"
  kernel-install remove "${kold}" || true
}

_ensure_title_plugin() {
  # Ensure our title plugin exists before we add entries
  if [ ! -x /etc/kernel/install.d/95-cip-title.install ]; then
    install -Dm755 /usr/share/linux-cip/95-cip-title.install /etc/kernel/install.d/95-cip-title.install || true
  fi
  # Ensure layout=bls is present
  if ! grep -qs '^layout=' /etc/kernel/install.conf 2>/dev/null; then
    printf 'layout=bls\n' | install -Dm644 /dev/stdin /etc/kernel/install.conf
  fi
  if ! grep -qs '^initrd_generator=' /etc/kernel/install.conf 2>/dev/null; then
    printf 'initrd_generator=mkinitcpio\n' | tee -a /etc/kernel/install.conf >/dev/null
  fi
}
INST

# Write 95-cip-title.install so the package can ship a copy to /usr/share for future runs
cat > 95-cip-title.install <<'PLUG'
#!/bin/sh
set -eu
cmd="${1:-}" ; kver="${2:-}"
[ "$cmd" = "add" ] || exit 0
[ "${KERNEL_INSTALL_LAYOUT:-}" = "bls" ] || exit 0
entries_dir="${KERNEL_INSTALL_BOOT_ROOT:-/boot}/loader/entries"
token="${KERNEL_INSTALL_ENTRY_TOKEN:-}"
[ -n "$token" ] || exit 0
for f in "$entries_dir/${token}-${kver}"*.conf; do
  [ -f "$f" ] || continue
  sed -i -E 's/^title .*/title Arch Linux (CIP)/' "$f"
done
PLUG

# PKGBUILD for split packages: linux-cip and linux-cip-headers
cat > PKGBUILD <<'PKG'
pkgbase=linux-cip
pkgname=(linux-cip linux-cip-headers)
pkgrel=1
pkgdesc="Civil Infrastructure Platform kernel built from selected CIP branch, packaged for Arch"
url="https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git"
arch=(x86_64)
license=(GPL2)
makedepends=(git bc kmod libelf pahole perl python xz zstd dtc cpio rsync)
options=('!debug')  # keep symbols as per defaults
source=("linux-cip::git+https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git#branch=@BRANCH@"
        "linux-cip.install"
        "95-cip-title.install")
b2sums=('SKIP' 'SKIP' 'SKIP')

# Save the branch name for display
_branch='@BRANCH@'

prepare() {
  cd "${srcdir}/linux-cip"
  # Help setlocalversion produce a stable suffix if git is visible
  scripts/setlocalversion --save-scmversion
  # Seed config from running kernel if available, else defconfig
  if zcat /proc/config.gz >/dev/null 2>&1; then
    zcat /proc/config.gz > .config
  else
    make x86_64_defconfig
  fi
  make olddefconfig
}

pkgver() {
  cd "${srcdir}/linux-cip"
  # Kernel release string (same format as uname -r), no hyphens
  make -s kernelrelease
}

build() {
  cd "${srcdir}/linux-cip"
  make -j"$(nproc)" bzImage modules
}

_package_common_files() {
  # args: destdir
  local dest="$1"
  local kver
  kver="$(make -s -C "${srcdir}/linux-cip" kernelrelease)"
  # Modules
  make -C "${srcdir}/linux-cip" INSTALL_MOD_PATH="${dest}/usr" INSTALL_MOD_STRIP=1 modules_install
  # Kernel image + metadata under /usr/lib/modules/$kver/
  install -Dm644 "${srcdir}/linux-cip/arch/x86/boot/bzImage" "${dest}/usr/lib/modules/${kver}/vmlinuz"
  install -Dm644 "${srcdir}/linux-cip/System.map"           "${dest}/usr/lib/modules/${kver}/System.map"
  install -Dm644 "${srcdir}/linux-cip/.config"              "${dest}/usr/lib/modules/${kver}/config"
  # pkgbase marker for tools
  echo "${pkgbase}" > "${dest}/usr/lib/modules/${kver}/pkgbase"
}

package_linux-cip() {
  pkgdesc+=" (binary)"
  depends=(coreutils kmod)
  # Ship our kernel-install title plugin copy for reuse
  install -Dm755 "95-cip-title.install"   "${pkgdir}/usr/share/linux-cip/95-cip-title.install"
  _package_common_files "${pkgdir}"
  # Make pacman run our kernel-install add/remove
  install=${pkgbase}.install
}

package_linux-cip-headers() {
  pkgdesc+=" (headers for building out-of-tree modules)"
  depends=()
  local kver
  kver="$(make -s -C "${srcdir}/linux-cip" kernelrelease)"
  local builddir="${pkgdir}/usr/lib/modules/${kver}/build"

  # Install a prepared build tree subset suitable for dkms and external modules
  install -dm755 "${builddir}"
  # Copy essential files and directories
  install -m644 "${srcdir}/linux-cip"/{Makefile,Kconfig,Module.symvers,System.map,.config} "${builddir}/" || true
  cp -a "${srcdir}/linux-cip"/{scripts,tools,include,arch,xz,lib} "${builddir}/"
  # Prune architecture to x86 only for headers to reduce size
  find "${builddir}/arch" -mindepth 1 -maxdepth 1 ! -name x86 -exec rm -rf {} +
  # Export UAPI headers
  make -C "${srcdir}/linux-cip" INSTALL_HDR_PATH="${builddir}/usr" headers_install
  # Provide the canonical /usr/src link
  install -dm755 "${pkgdir}/usr/src"
  ln -s "../lib/modules/${kver}/build" "${pkgdir}/usr/src/${pkgbase}"
}
PKG

# Substitute the chosen branch into PKGBUILD
sed -i "s|@BRANCH@|$choice|g" PKGBUILD

echo
echo "Build files written to: $(pwd)"
echo "Building packages with makepkg..."

# Build with deps, clean build, install interactively at the end
makepkg -sCc --noconfirm

# Install both packages, kernel package first
PKGS=( $(ls -1 *.pkg.tar.* | sort) )
echo
echo "Installing packages with pacman..."
sudo pacman -U --noconfirm --needed "${PKGS[@]}"

echo
echo "Done."
echo "Tip: you can inspect kernel-install’s view with:  kernel-install inspect --verbose"
