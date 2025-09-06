#!/usr/bin/env bash
# cip-active-netlite-ui-v12.sh
# Pick a CIP branch, then clone, build, package with makepkg, and register via kernel-install (mkinitcpio, BLS).
set -euo pipefail

BASE="https://kernel.googlesource.com/pub/scm/linux/kernel/git/cip/linux-cip"
CLONE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-120}"
NOW_EPOCH=$(date +%s)
CIP_WIKI_URL="https://wiki.linuxfoundation.org/civilinfrastructureplatform/start?do=edit"

need_cmd() { command -v "$1" >/dev/null 2>&1; }
curlq() { curl -fsSL "$1"; }
trim() { awk '{$1=$1;print}'; }

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

month_end_epoch() { TZ=UTC date -d "${1}-01 +1 month -1 day 23:59:59" +%s 2>/dev/null || echo 0; }

diff_ymd() {
  local start="$1" end="$2"
  if (( end <= start )); then echo "0 yrs 0 mos 0 days"; return; fi
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

declare -A EOL_MAP FIRST_MAP
build_eol_map() {
  local src; src="$(curlq "$CIP_WIKI_URL" 2>/dev/null)" || return 1
  while IFS='|' read -r _ col_ver _ col_first col_eol _ _; do
    local ver="$(printf '%s' "$col_ver" | trim)"; ver="${ver#SLTS v}"
    local first="$(printf '%s' "$col_first" | trim)"
    local eol="$(printf '%s' "$col_eol" | trim)"
    if [[ "$ver" =~ ^[0-9]+\.[0-9]+(-rt)?$ ]]; then
      [[ "$eol" =~ ^[0-9]{4}-[0-9]{2}$ ]] && EOL_MAP["$ver"]="$eol"
      [[ "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && FIRST_MAP["$ver"]="$first"
    fi
  done < <(printf '%s\n' "$src" | awk -F'[|]' '/[|][[:space:]]*SLTS v[0-9]+\.[0-9]+/ {print}')
}

branch_to_eol_key() {
  local br="$1" ver rest
  if [[ "$br" =~ linux-([0-9]+\.[0-9]+)\.y-cip(.*) ]]; then
    ver="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    [[ "$rest" == *-rt* ]] && printf '%s-rt\n' "$ver" || printf '%s\n' "$ver"
  fi
}

REFS_HTML="$(curlq "$BASE/+refs")"
mapfile -t BRANCHES_ALL < <(printf '%s\n' "$REFS_HTML" | grep -oE 'linux-[0-9]+\.[0-9]+\.y-cip(-rt|-rebase)?' | sort -Vu)
(( ${#BRANCHES_ALL[@]} )) || { echo "No CIP branches found on +refs"; exit 1; }

BRANCHES=()
if [[ -n "${INCLUDE_REBASE:-}" ]]; then BRANCHES=("${BRANCHES_ALL[@]}"); else
  for b in "${BRANCHES_ALL[@]}"; do [[ "$b" == *-rebase ]] && continue; BRANCHES+=("$b"); done
fi

branch_head_epoch() {
  local br="$1" b64 epoch
  b64="$(curlq "$BASE/+/refs/heads/$br?format=TEXT" 2>/dev/null)" || { echo 0; return; }
  epoch="$(printf '%s' "$b64" | base64 -d 2>/dev/null | awk '/^committer /{print $(NF-1); exit}')"
  [[ "$epoch" =~ ^[0-9]+$ ]] && printf '%s\n' "$epoch" || echo 0
}

fmt_days_ago() { local d="$1"; ((d<=0)) && echo "today" || { ((d==1)) && echo "1 day ago" || echo "$d days ago"; }; }

build_eol_map || true
setup_colors

declare -a BODY_SORTABLE ACTIVE_SORTABLE
HEADER=$'Branch\tStatus\tLast Commit\tFirst Release\tEOL\tTime-to-EOL'
ACTIVE=()

for br in "${BRANCHES[@]}"; do
  epoch="$(branch_head_epoch "$br")"
  status="UNKNOWN"; age_str="-"
  if (( epoch > 0 )); then
    age_days=$(( (NOW_EPOCH - epoch)/86400 )); (( age_days < 0 )) && age_days=0
    status="STALE"; (( NOW_EPOCH - epoch < THRESHOLD_DAYS*86400 )) && status="ACTIVE"
    age_str="$(fmt_days_ago "$age_days")"; [[ "$status" == "ACTIVE" ]] && ACTIVE+=("$br")
  fi
  key="$(branch_to_eol_key "$br")"
  first_rel="${FIRST_MAP[$key]:-UNKNOWN}"; eol="${EOL_MAP[$key]:-UNKNOWN}"
  eol_epoch=-1; tte="-"
  if [[ "$eol" != "UNKNOWN" ]]; then
    eol_epoch="$(month_end_epoch "$eol")"; (( eol_epoch > 0 )) && tte="$(diff_ymd "$NOW_EPOCH" "$eol_epoch")" || eol_epoch=-1
  fi
  row="$(printf "%s\t%s\t%s\t%s\t%s\t%s" "$br" "$status" "$age_str" "$first_rel" "$eol" "$tte")"
  BODY_SORTABLE+=( "$(printf "%s\t%s" "$eol_epoch" "$row")" )
  [[ "$status" == "ACTIVE" ]] && ACTIVE_SORTABLE+=( "$(printf "%s\t%s" "$eol_epoch" "$br")" )
done

sorted_body="$(printf "%s\n" "${BODY_SORTABLE[@]}" | sort -t $'\t' -k1,1nr -k2,2 | cut -f2-)"
out="$HEADER"$'\n'"$sorted_body"
if need_cmd column; then out="$(printf "%s\n" "$out" | column -t -s $'\t')"; else out="$(printf "%s\n" "$out" | sed $'s/\t/  /g')"; fi
[[ -n "${GREEN}${RED}${RESET}" ]] && out="$(printf "%s\n" "$out" | sed -E "1! s/ACTIVE/${GREEN}&${RESET}/g; 1! s/STALE/${RED}&${RESET}/g")"
printf "%s\n" "$out"

if ((${#ACTIVE[@]}==0)); then echo; echo "No ACTIVE branches under the current threshold ($THRESHOLD_DAYS days)."; exit 0; fi

echo; echo "Pick an ACTIVE branch:"
choice=""
ACTIVE_LIST_SORTED="$(printf "%s\n" "${ACTIVE_SORTABLE[@]}" | sort -t $'\t' -k1,1nr -k2,2 | cut -f2-)"
if need_cmd fzf; then choice="$(printf "%s\n" "$ACTIVE_LIST_SORTED" | fzf --prompt="SLTS> " --height=10 --reverse)" || true
else PS3="Select branch> "; ACTIVE_ARR=( $(printf "%s\n" "$ACTIVE_LIST_SORTED") ); select br in "${ACTIVE_ARR[@]}"; do choice="$br"; break; done; fi
[[ -n "${choice:-}" ]] && echo "You selected: $choice"
[[ -z "${choice:-}" ]] && exit 0

############################################
# Build, package, install, kernel-install
############################################
# Tooling
require_tools=(git make gcc awk sed grep tar xz zstd bc perl bison flex openssl pahole ld dtc rsync cpio strip makepkg fakeroot kernel-install mkinitcpio base64)
missing=(); for t in "${require_tools[@]}"; do need_cmd "$t" || missing+=("$t"); done
if ((${#missing[@]})); then echo "Missing required tools: ${missing[*]}"; echo "Install base-devel and the listed tools, then rerun."; exit 1; fi
(( EUID == 0 )) && { echo "Do not run as root. We use sudo only for system steps."; exit 1; }

# Ensure kernel-install config and cmdline (BLS layout with mkinitcpio)
ensure_kernel_install_conf() {
  sudo mkdir -p /etc
  if [[ ! -f /etc/kernel/install.conf ]]; then
    printf "layout=bls\ninitrd_generator=mkinitcpio\n" | sudo tee /etc/kernel/install.conf >/dev/null
  else
    grep -q '^layout=' /etc/kernel/install.conf || echo "layout=bls" | sudo tee -a /etc/kernel/install.conf >/dev/null
    grep -q '^initrd_generator=' /etc/kernel/install.conf || echo "initrd_generator=mkinitcpio" | sudo tee -a /etc/kernel/install.conf >/dev/null
  fi
}
ensure_cmdline() {
  if [[ ! -f /etc/kernel/cmdline ]]; then
    if [[ -r /proc/cmdline ]]; then
      awk '{for(i=1;i<=NF;i++){ if($i ~ /^BOOT_IMAGE=/) continue; if($i ~ /^initrd=/) continue; printf("%s%s",(out++?" ":""),$i)} printf("\n")}' /proc/cmdline \
        | sudo tee /etc/kernel/cmdline >/dev/null
    else
      echo "root=PARTUUID=XXXX rw quiet" | sudo tee /etc/kernel/cmdline >/dev/null
    fi
  fi
}
# Title plugin so the BLS entry shows "Arch Linux (CIP)"
install_cip_title_plugin() {
  local tmp; tmp="$(mktemp)"
  cat >"$tmp" <<'PLUG'
#!/bin/sh
set -eu
cmd="${1:-}"; kver="${2:-}"
[ "$cmd" = "add" ] || exit 0
[ "${KERNEL_INSTALL_LAYOUT:-}" = "bls" ] || exit 0
entries_dir="${KERNEL_INSTALL_BOOT_ROOT:-/boot}/loader/entries"
token="${KERNEL_INSTALL_ENTRY_TOKEN:-}"; [ -n "$token" ] || exit 0
for f in "$entries_dir/${token}-${kver}"*.conf; do
  [ -f "$f" ] || continue
  sed -i -E 's/^title .*/title Arch Linux (CIP)/' "$f"
done
PLUG
  sudo install -Dm755 "$tmp" "/etc/kernel/install.d/95-cip-title.install"; rm -f "$tmp"
}

ensure_kernel_install_conf
ensure_cmdline
install_cip_title_plugin

# Determine flavor and pkgbase from the selected branch
suffix=""
if [[ "$choice" == *-rt* ]]; then
  suffix="-rt"
elif [[ "$choice" == *-rebase* ]]; then
  suffix="-rebase"
fi
PKGBASE="linux-cip${suffix}"

# Workspace
BR_SAFE="$(printf '%s' "$choice" | sed 's@[^A-Za-z0-9._-]@-@g')"
WORKDIR="cip-build-$BR_SAFE"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# .install used by pacman to call kernel-install (generalized per flavor via $PKGBASE)
cat > "${PKGBASE}.install" <<'INST'
PKGBASE="@PKGBASE@"

_find_all_kvers_for_pkgbase() {
  for d in /usr/lib/modules/*; do
    [ -d "$d" ] || continue
    [ -f "$d/pkgbase" ] || continue
    if [ "$(cat "$d/pkgbase")" = "$PKGBASE" ]; then
      basename "$d"
    fi
  done | sort -V
}

_find_kver_latest_for_pkgbase() {
  _find_all_kvers_for_pkgbase | tail -n1
}

post_install() {
  local kver="$(_find_kver_latest_for_pkgbase)"
  if [ -n "$kver" ]; then
    echo "kernel-install add ${kver}"
    kernel-install add "${kver}" "/usr/lib/modules/${kver}/vmlinuz" || true
  fi
  _ensure_plugin_and_conf
}

post_upgrade() {
  local knew="$(_find_kver_latest_for_pkgbase)"
  if [ -n "$knew" ]; then
    echo "kernel-install add ${knew}"
    kernel-install add "${knew}" "/usr/lib/modules/${knew}/vmlinuz" || true
  fi
  # remove older entries of the same flavor
  local k
  for k in $(_find_all_kvers_for_pkgbase); do
    [ "$k" = "$knew" ] && continue
    echo "kernel-install remove ${k}"
    kernel-install remove "$k" || true
  done
  _ensure_plugin_and_conf
}

post_remove() {
  local k
  for k in $(_find_all_kvers_for_pkgbase); do
    echo "kernel-install remove ${k}"
    kernel-install remove "$k" || true
  done
}

_ensure_plugin_and_conf() {
  if [ ! -x /etc/kernel/install.d/95-cip-title.install ] && [ -x "/usr/share/${PKGBASE}/95-cip-title.install" ]; then
    install -Dm755 "/usr/share/${PKGBASE}/95-cip-title.install" /etc/kernel/install.d/95-cip-title.install || true
  fi
  if ! grep -qs '^layout=' /etc/kernel/install.conf 2>/dev/null; then
    printf 'layout=bls\n' | install -Dm644 /dev/stdin /etc/kernel/install.conf
  fi
  if ! grep -qs '^initrd_generator=' /etc/kernel/install.conf 2>/dev/null; then
    printf 'initrd_generator=mkinitcpio\n' | tee -a /etc/kernel/install.conf >/dev/null
  fi
}
INST

# Title plugin shipped in the package for reuse (keeps generic title)
cat > 95-cip-title.install <<'PLUG'
#!/bin/sh
set -eu
cmd="${1:-}"; kver="${2:-}"
[ "$cmd" = "add" ] || exit 0
[ "${KERNEL_INSTALL_LAYOUT:-}" = "bls" ] || exit 0
entries_dir="${KERNEL_INSTALL_BOOT_ROOT:-/boot}/loader/entries"
token="${KERNEL_INSTALL_ENTRY_TOKEN:-}"; [ -n "$token" ] || exit 0
for f in "$entries_dir/${token}-${kver}"*.conf; do
  [ -f "$f" ] || continue
  sed -i -E 's/^title .*/title Arch Linux (CIP)/' "$f"
done
PLUG

# PKGBUILD with flavor-aware pkgbase and split packages
cat > PKGBUILD <<'PKG'
pkgbase=@PKGBASE@
pkgname=(@PKGBASE@ @PKGBASE@-headers)
pkgver=0
pkgrel=1
pkgdesc="Civil Infrastructure Platform kernel from the selected CIP branch, packaged for Arch"
url="https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git"
arch=(x86_64)
license=(GPL2)
makedepends=(git bc kmod libelf pahole perl python xz zstd dtc cpio rsync)
options=('!debug')
source=("linux-cip::git+https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git#branch=@BRANCH@"
        "@PKGBASE@.install"
        "95-cip-title.install")
b2sums=('SKIP' 'SKIP' 'SKIP')

_branch='@BRANCH@'

prepare() {
  cd "${srcdir}/linux-cip"
  # Keep LOCALVERSION empty so kernelrelease stays clean
  if zcat /proc/config.gz >/dev/null 2>&1; then
    zcat /proc/config.gz > .config
  else
    make x86_64_defconfig
  fi
  make olddefconfig
}

pkgver() {
  cd "${srcdir}/linux-cip"
  # Prefer CIP tags, then stable tags, else kernelversion + revcount + hash
  local desc=""
  desc="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*-cip*' --long 2>/dev/null || true)"
  if [[ -z "$desc" ]]; then
    desc="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --long 2>/dev/null || true)"
  fi
  if [[ -n "$desc" ]]; then
    desc="${desc#v}"
    IFS='-' read -r tag commits ghash <<<"$desc"
    tag="${tag//-/.}"  # hyphens not allowed in pkgver
    if [[ "$commits" == "0" ]]; then
      printf '%s\n' "$tag"
    else
      printf '%s.r%s.%s\n' "$tag" "$commits" "${ghash/g/}"
    fi
  else
    printf "%s.r%s.%s\n" \
      "$(make -s kernelversion)" \
      "$(git rev-list --count HEAD)" \
      "$(git rev-parse --short HEAD)"
  fi
}

build() {
  cd "${srcdir}/linux-cip"
  make -j"$(nproc)" LOCALVERSION= bzImage modules
  make -s LOCALVERSION= kernelrelease > "${srcdir}/.kver"
}

_package_common_files() {
  local dest="$1"
  local kver; kver="$(<"${srcdir}/.kver")"
  make -C "${srcdir}/linux-cip" LOCALVERSION= INSTALL_MOD_PATH="${dest}/usr" INSTALL_MOD_STRIP=1 modules_install
  install -Dm644 "${srcdir}/linux-cip/arch/x86/boot/bzImage" "${dest}/usr/lib/modules/${kver}/vmlinuz"
  install -Dm644 "${srcdir}/linux-cip/System.map"           "${dest}/usr/lib/modules/${kver}/System.map"
  install -Dm644 "${srcdir}/linux-cip/.config"              "${dest}/usr/lib/modules/${kver}/config"
  echo "${pkgbase}" > "${dest}/usr/lib/modules/${kver}/pkgbase"
  git -C "${srcdir}/linux-cip" rev-parse HEAD > "${dest}/usr/lib/modules/${kver}/source_commit"
}

package_@PKGBASE@() {
  pkgdesc+=" (binary)"
  depends=(coreutils kmod)
  install -Dm755 "95-cip-title.install"   "${pkgdir}/usr/share/${pkgbase}/95-cip-title.install"
  _package_common_files "${pkgdir}"
  install=${pkgbase}.install
}

package_@PKGBASE@-headers() {
  pkgdesc+=" (headers for building out-of-tree modules)"
  depends=()
  local kver; kver="$(<"${srcdir}/.kver")"
  local builddir="${pkgdir}/usr/lib/modules/${kver}/build"

  install -dm755 "${builddir}"
  install -m644 "${srcdir}/linux-cip"/{Makefile,Kconfig,Module.symvers,System.map,.config} "${builddir}/" || true
  cp -a "${srcdir}/linux-cip"/{scripts,tools,include,arch,xz,lib} "${builddir}/"
  find "${builddir}/arch" -mindepth 1 -maxdepth 1 ! -name x86 -exec rm -rf {} +
  make -C "${srcdir}/linux-cip" LOCALVERSION= INSTALL_HDR_PATH="${builddir}/usr" headers_install
  install -dm755 "${pkgdir}/usr/src"
  ln -s "../lib/modules/${kver}/build" "${pkgdir}/usr/src/${pkgbase}"
}
PKG

# Fill in chosen branch and pkgbase
sed -i "s|@BRANCH@|$choice|g" PKGBUILD
sed -i "s|@PKGBASE@|$PKGBASE|g" PKGBUILD "${PKGBASE}.install"

echo
echo "Build files written to: $(pwd)"
echo "Building packages with makepkg..."

# Clean build, install deps, no prompts
makepkg -sCc --noconfirm

# Install both packages
PKGS=( $(ls -1 *.pkg.tar.* | sort) )
echo
echo "Installing packages with pacman..."
sudo pacman -U --noconfirm --needed "${PKGS[@]}"

echo
echo "Done. kernel-install should have created a BLS entry titled: Arch Linux (CIP)"
echo "Packages installed: ${PKGBASE} and ${PKGBASE}-headers"
echo "Check with:  bootctl list   and   kernel-install inspect --verbose"
