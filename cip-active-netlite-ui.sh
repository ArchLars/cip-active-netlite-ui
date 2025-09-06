#!/usr/bin/env bash
# cip-active-netlite-ui-optimized.sh
# Optimized CIP kernel build script with ccache, persistent builds, and automatic updater+hook installation
# Pick a CIP branch, then clone or update, build, package with makepkg, and register via kernel-install
set -euo pipefail

# Configuration
BASE="https://kernel.googlesource.com/pub/scm/linux/kernel/git/cip/linux-cip"
CLONE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-120}"
NOW_EPOCH=$(date +%s)
CIP_WIKI_URL="https://wiki.linuxfoundation.org/civilinfrastructureplatform/start?do=edit"

# Build optimization settings
CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache-cip}"
BUILD_CACHE_DIR="${BUILD_CACHE_DIR:-${HOME}/.cache/cip-builds}"
CONFIG_CACHE_DIR="${CONFIG_CACHE_DIR:-${HOME}/.config/cip-kernel}"
LSMOD_PROFILES_DIR="${LSMOD_PROFILES_DIR:-${CONFIG_CACHE_DIR}/profiles}"
USE_CCACHE="${USE_CCACHE:-1}"
USE_LOCALMODCONFIG="${USE_LOCALMODCONFIG:-1}"
INCREMENTAL_BUILD="${INCREMENTAL_BUILD:-1}"
DEBUG_SYMBOLS="${DEBUG_SYMBOLS:-0}"

# Paths used by the auto-updater this script installs
UPDATER_BIN="/usr/local/bin/cip-kernel-autoupdate"
UPDATER_CONF="/etc/cip-kernel-updater.conf"
UPDATER_HOOK="/etc/pacman.d/hooks/90-cip-kernel-autoupdate.hook"

# Create necessary directories
mkdir -p "$CCACHE_DIR" "$BUILD_CACHE_DIR" "$CONFIG_CACHE_DIR" "$LSMOD_PROFILES_DIR"

# Utility functions
need_cmd() { command -v "$1" >/dev/null 2>&1; }
curlq() { curl -fsSL "$1"; }
trim() { awk '{$1=$1;print}'; }

setup_colors() {
  RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET="";
  if [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]] && { [[ -t 1 ]] || [[ -n "${FORCE_COLOR:-}" ]]; }; then
    if need_cmd tput && tput colors >/dev/null 2>&1; then
      RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; RESET="$(tput sgr0)";
    else
      RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m';
    fi
  fi
}

# ccache setup
setup_ccache() {
  if [[ "$USE_CCACHE" == "1" ]] && need_cmd ccache; then
    export CCACHE_DIR
    ccache --set-config=max_size=10G
    ccache --set-config=compression=true
    ccache --set-config=compression_level=1
    ccache --set-config=sloppiness=file_macro,time_macros,include_file_mtime,include_file_ctime
    if [[ -n "${BUILD_CACHE_DIR}" ]]; then
      ccache --set-config=base_dir="$BUILD_CACHE_DIR"
    fi
    echo "${GREEN}ccache configured:${RESET}"
    ccache -s | head -n 6
    return 0
  fi
  return 1
}

# Profile management
save_hardware_profile() {
  local profile_name="${1:-default}"
  local profile_file="${LSMOD_PROFILES_DIR}/${profile_name}.modules"
  echo "${BLUE}Saving current hardware profile to: $profile_file${RESET}"
  lsmod > "$profile_file"
  echo "Profile saved with $(wc -l < "$profile_file") modules"
}

load_hardware_profile() {
  local profile_name="${1:-default}"
  local profile_file="${LSMOD_PROFILES_DIR}/${profile_name}.modules"
  if [[ -f "$profile_file" ]]; then
    echo "${BLUE}Loading hardware profile from: $profile_file${RESET}"
    export LSMOD="$profile_file"
    return 0
  fi
  echo "${YELLOW}No profile found at $profile_file, using current modules${RESET}"
  return 1
}

merge_hardware_profiles() {
  local output_file="${LSMOD_PROFILES_DIR}/merged.modules"
  echo "Module Size Used_by" > "$output_file"
  for profile in "$LSMOD_PROFILES_DIR"/*.modules; do
    [[ -f "$profile" ]] || continue
    tail -n +2 "$profile" >> "$output_file"
  done
  sort -u -o "$output_file" "$output_file"
  echo "${GREEN}Merged profiles into: $output_file${RESET}"
  export LSMOD="$output_file"
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

branch_head_epoch() {
  local br="$1" b64 epoch
  b64="$(curlq "$BASE/+/refs/heads/$br?format=TEXT" 2>/dev/null)" || { echo 0; return; }
  epoch="$(printf '%s' "$b64" | base64 -d 2>/dev/null | awk '/^committer /{print $(NF-1); exit}')"
  [[ "$epoch" =~ ^[0-9]+$ ]] && printf '%s\n' "$epoch" || echo 0
}

fmt_days_ago() { local d="$1"; ((d<=0)) && echo "today" || { ((d==1)) && echo "1 day ago" || echo "$d days ago"; }; }

# Save build state
save_build_state() {
  local branch="$1" version="$2" commit="$3" build_dir="$4"
  local state_file="${build_dir}/.build_state"
  cat > "$state_file" <<EOF
LAST_BRANCH="$branch"
LAST_VERSION="$version"
LAST_COMMIT="$commit"
LAST_BUILD_DATE="$(date)"
BUILD_DIR="$build_dir"
EOF
}

# Optimized kernel config
optimize_kernel_config() {
  local config_file="$1"
  if [[ "$DEBUG_SYMBOLS" == "0" ]]; then
    echo "${BLUE}Disabling debug symbols for smaller builds...${RESET}"
    ./scripts/config --file "$config_file" \
      -d DEBUG_INFO \
      -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
      -d DEBUG_INFO_DWARF4 \
      -d DEBUG_INFO_DWARF5 \
      -e CONFIG_DEBUG_INFO_NONE || true
  fi
  ./scripts/config --file "$config_file" -d IKHEADERS -d IKHEADERS_PROC || true
  ./scripts/config --file "$config_file" -e MODULE_COMPRESS_GZIP || true
}

# Parse args
CHOICE_FROM_ARG=""
if [[ "${1:-}" == "--branch" && -n "${2:-}" ]]; then
  CHOICE_FROM_ARG="$2"
  shift 2
fi

# Main branch discovery
REFS_HTML="$(curlq "$BASE/+refs")"
mapfile -t BRANCHES_ALL < <(printf '%s\n' "$REFS_HTML" | grep -oE 'linux-[0-9]+\.[0-9]+\.y-cip(-rt|-rebase)?' | sort -Vu)
(( ${#BRANCHES_ALL[@]} )) || { echo "No CIP branches found on +refs"; exit 1; }

BRANCHES=()
if [[ -n "${INCLUDE_REBASE:-}" ]]; then BRANCHES=("${BRANCHES_ALL[@]}"); else
  for b in "${BRANCHES_ALL[@]}"; do [[ "$b" == *-rebase ]] && continue; BRANCHES+=("$b"); done
fi

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

# Choose branch
choice=""
if [[ -n "$CHOICE_FROM_ARG" ]]; then
  # Non-interactive choice passed by updater
  for b in "${ACTIVE[@]}"; do [[ "$b" == "$CHOICE_FROM_ARG" ]] && choice="$b" && break; done
  if [[ -z "$choice" ]]; then
    # fallback to any branch match, even if marked STALE
    for b in "${BRANCHES[@]}"; do [[ "$b" == "$CHOICE_FROM_ARG" ]] && choice="$b" && break; done
  fi
  [[ -z "$choice" ]] && { echo "Branch $CHOICE_FROM_ARG not found"; exit 1; }
  echo "Selected by argument: $choice"
else
  if ((${#ACTIVE[@]}==0)); then echo; echo "No ACTIVE branches under the current threshold ($THRESHOLD_DAYS days)."; exit 0; fi
  echo; echo "Pick an ACTIVE branch:"
  ACTIVE_LIST_SORTED="$(printf "%s\n" "${ACTIVE_SORTABLE[@]}" | sort -t $'\t' -k1,1nr -k2,2 | cut -f2-)"
  if need_cmd fzf; then choice="$(printf "%s\n" "$ACTIVE_LIST_SORTED" | fzf --prompt="SLTS> " --height=10 --reverse)" || true
  else PS3="Select branch> "; ACTIVE_ARR=( $(printf "%s\n" "$ACTIVE_LIST_SORTED") ); select br in "${ACTIVE_ARR[@]}"; do choice="$br"; break; done; fi
  [[ -z "${choice:-}" ]] && exit 0
  echo "You selected: $choice"
fi

############################################
# Build, package, install, kernel-install
############################################

# Check for hardware profile management
if [[ "${1:-}" == "--save-profile" ]]; then
  save_hardware_profile "${2:-default}"
  exit 0
fi

if [[ "${1:-}" == "--load-profile" ]]; then
  load_hardware_profile "${2:-default}"
fi

if [[ "${1:-}" == "--merge-profiles" ]]; then
  merge_hardware_profiles
fi

# Tooling
require_tools=(git make gcc awk sed grep tar xz zstd bc perl bison flex openssl pahole ld dtc rsync cpio strip makepkg fakeroot kernel-install mkinitcpio base64)
[[ "$USE_CCACHE" == "1" ]] && require_tools+=(ccache)
missing=(); for t in "${require_tools[@]}"; do need_cmd "$t" || missing+=("$t"); done
if ((${#missing[@]})); then echo "Missing required tools: ${missing[*]}"; echo "Install base-devel and the listed tools, then rerun."; exit 1; fi
(( EUID == 0 )) && { echo "Do not run as root. We use sudo only for system steps."; exit 1; }

# Setup ccache if enabled
if [[ "$USE_CCACHE" == "1" ]]; then
  setup_ccache && CC_PREFIX="ccache " || CC_PREFIX=""
else
  CC_PREFIX=""
fi

# Ensure kernel-install config and cmdline (BLS layout with mkinitcpio)
ensure_kernel_install_conf() {
  sudo mkdir -p /etc/kernel
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

# Workspace with persistent build directory
BR_SAFE="$(printf '%s' "$choice" | sed 's@[^A-Za-z0-9._-]@-@g')"
BUILD_DIR="${BUILD_CACHE_DIR}/${BR_SAFE}"
WORKDIR="cip-build-$BR_SAFE"
mkdir -p "$WORKDIR" "$BUILD_DIR"
cd "$WORKDIR"

# Determine if incremental build is possible
IS_UPDATE=0
if [[ -d "${BUILD_DIR}/linux-cip" ]] && [[ -f "${BUILD_DIR}/.build_state" ]]; then
  echo "${GREEN}Found existing build directory. Performing incremental update...${RESET}"
  IS_UPDATE=1
  # shellcheck source=/dev/null
  source "${BUILD_DIR}/.build_state"
fi

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

# Title plugin shipped in the package
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

# PKGBUILD with optimizations for incremental builds
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
options=('!debug' '!strip')
source=("@PKGBASE@.install"
        "95-cip-title.install")
b2sums=('SKIP' 'SKIP')

_branch='@BRANCH@'
_builddir='@BUILD_DIR@'
_is_update=@IS_UPDATE@
_use_ccache=@USE_CCACHE@
_use_localmodconfig=@USE_LOCALMODCONFIG@
_cc_prefix='@CC_PREFIX@'

export KBUILD_BUILD_TIMESTAMP=""
export KBUILD_BUILD_USER="cip"
export KBUILD_BUILD_HOST="archlinux"

prepare() {
  if [[ $_is_update -eq 1 ]] && [[ -d "${_builddir}/linux-cip" ]]; then
    cd "${_builddir}/linux-cip"
    echo "Updating existing repository..."
    git fetch origin "${_branch}"
    git checkout "${_branch}"
    git pull --ff-only
  else
    if [[ -d "${_builddir}/linux-cip" ]]; then
      rm -rf "${_builddir}/linux-cip"
    fi>
    cd "${_builddir}"
    echo "Cloning fresh repository..."
    git clone --depth 1 --branch "${_branch}" \
      "https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git"
    cd linux-cip
  fi

  echo "" > .scmversion

  if [[ -f "${_builddir}/.config.saved" ]] && [[ $_is_update -eq 1 ]]; then
    echo "Using saved config from previous build..."
    cp "${_builddir}/.config.saved" .config
    make olddefconfig
  elif [[ $_use_localmodconfig -eq 1 ]] && [[ -n "${LSMOD:-}" ]]; then
    echo "Using localmodconfig with profile: ${LSMOD}"
    if zcat /proc/config.gz >/dev/null 2>&1; then
      zcat /proc/config.gz > .config
    else
      make x86_64_defconfig
    fi
    yes "" | make LSMOD="${LSMOD}" localmodconfig
  elif [[ $_use_localmodconfig -eq 1 ]]; then
    echo "Using localmodconfig with current modules..."
    if zcat /proc/config.gz >/dev/null 2>&1; then
      zcat /proc/config.gz > .config
    else
      make x86_64_defconfig
    fi
    yes "" | make localmodconfig
  else
    echo "Using standard config..."
    if zcat /proc/config.gz >/dev/null 2>&1; then
      zcat /proc/config.gz > .config
    else
      make x86_64_defconfig
    fi
    make olddefconfig
  fi

  @OPTIMIZE_CONFIG@

  cp .config "${_builddir}/.config.saved"
}

pkgver() {
  cd "${_builddir}/linux-cip"
  local desc=""
  desc="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*-cip*' --long 2>/dev/null || true)"
  if [[ -z "$desc" ]]; then
    desc="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --long 2>/dev/null || true)"
  fi
  if [[ -n "$desc" ]]; then
    desc="${desc#v}"
    IFS='-' read -r tag commits ghash <<<"$desc"
    tag="${tag//-/.}"
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
  cd "${_builddir}/linux-cip"
  if [[ $_use_ccache -eq 1 ]]; then
    export CC="${_cc_prefix}gcc"
    export HOSTCC="${_cc_prefix}gcc"
  fi
  if [[ $_is_update -eq 1 ]] && [[ -f "${_builddir}/.build_complete" ]]; then
    echo "Performing incremental build..."
    make -j"$(nproc)" LOCALVERSION= bzImage modules
  else
    echo "Performing clean build..."
    make clean 2>/dev/null || true
    make -j"$(nproc)" LOCALVERSION= bzImage modules
    touch "${_builddir}/.build_complete"
  fi
  make -s LOCALVERSION= kernelrelease > "${_builddir}/.kver"
  local kver=$(cat "${_builddir}/.kver")
  local commit=$(git rev-parse HEAD)
  cat > "${_builddir}/.build_state" <<EOF
LAST_BRANCH="${_branch}"
LAST_VERSION="${kver}"
LAST_COMMIT="${commit}"
LAST_BUILD_DATE="$(date)"
BUILD_DIR="${_builddir}"
EOF
}

_package_common_files() {
  local dest="$1"
  local kver; kver="$(<"${_builddir}/.kver")"
  cd "${_builddir}/linux-cip"
  make LOCALVERSION= INSTALL_MOD_PATH="${dest}/usr" INSTALL_MOD_STRIP=1 modules_install
  install -Dm644 "arch/x86/boot/bzImage" "${dest}/usr/lib/modules/${kver}/vmlinuz"
  install -Dm644 "System.map"           "${dest}/usr/lib/modules/${kver}/System.map"
  install -Dm644 ".config"              "${dest}/usr/lib/modules/${kver}/config"
  echo "${pkgbase}" > "${dest}/usr/lib/modules/${kver}/pkgbase"
  git rev-parse HEAD > "${dest}/usr/lib/modules/${kver}/source_commit"
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
  local kver; kver="$(<"${_builddir}/.kver")"
  local builddir="${pkgdir}/usr/lib/modules/${kver}/build"
  cd "${_builddir}/linux-cip"
  install -dm755 "${builddir}"
  install -m644 {Makefile,Kconfig,Module.symvers,System.map,.config} "${builddir}/" || true
  cp -a {scripts,tools,include,arch} "${builddir}/"
  find "${builddir}/arch" -mindepth 1 -maxdepth 1 ! -name x86 -exec rm -rf {} +
  find "${builddir}" -type f -name "*.o" -delete
  find "${builddir}" -type f -name "*.cmd" -delete
  make LOCALVERSION= INSTALL_HDR_PATH="${builddir}/usr" headers_install
  install -dm755 "${pkgdir}/usr/src"
  ln -s "../lib/modules/${kver}/build" "${pkgdir}/usr/src/${pkgbase}"
}
PKG

# Optimization for config
OPTIMIZE_CONFIG=""
if [[ "$DEBUG_SYMBOLS" == "0" ]]; then
  OPTIMIZE_CONFIG="./scripts/config --file .config -d DEBUG_INFO -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -d DEBUG_INFO_DWARF4 -d DEBUG_INFO_DWARF5 -e CONFIG_DEBUG_INFO_NONE || true"
fi

# Fill in chosen branch and settings
sed -i "s|@BRANCH@|$choice|g" PKGBUILD
sed -i "s|@PKGBASE@|$PKGBASE|g" PKGBUILD "${PKGBASE}.install"
sed -i "s|@BUILD_DIR@|$BUILD_DIR|g" PKGBUILD
sed -i "s|@IS_UPDATE@|$IS_UPDATE|g" PKGBUILD
sed -i "s|@USE_CCACHE@|$USE_CCACHE|g" PKGBUILD
sed -i "s|@USE_LOCALMODCONFIG@|$USE_LOCALMODCONFIG|g" PKGBUILD
sed -i "s|@CC_PREFIX@|$CC_PREFIX|g" PKGBUILD
sed -i "s|@OPTIMIZE_CONFIG@|$OPTIMIZE_CONFIG|g" PKGBUILD

echo
echo "Build files written to: $(pwd)"
echo "Build cache directory: ${BUILD_DIR}"
echo "${BLUE}Build configuration:${RESET}"
echo "  - ccache: $([ "$USE_CCACHE" == "1" ] && echo "${GREEN}enabled${RESET}" || echo "${YELLOW}disabled${RESET}")"
echo "  - localmodconfig: $([ "$USE_LOCALMODCONFIG" == "1" ] && echo "${GREEN}enabled${RESET}" || echo "${YELLOW}disabled${RESET}")"
echo "  - incremental: $([ "$IS_UPDATE" == "1" ] && echo "${GREEN}yes${RESET}" || echo "${YELLOW}no (fresh)${RESET}")"
echo "  - debug symbols: $([ "$DEBUG_SYMBOLS" == "1" ] && echo "enabled" || echo "${GREEN}disabled${RESET}")"

if [[ "$USE_CCACHE" == "1" ]]; then
  echo
  echo "${BLUE}ccache statistics before build:${RESET}"
  ccache -s | grep -E "cache hit rate|cache size|files in cache"
fi

echo
echo "Building packages with makepkg..."
if [[ "$IS_UPDATE" == "1" ]]; then
  makepkg -se --noconfirm --needed
else
  makepkg -sCc --noconfirm
fi

if [[ "$USE_CCACHE" == "1" ]]; then
  echo
  echo "${BLUE}ccache statistics after build:${RESET}"
  ccache -s | grep -E "cache hit rate|cache size|files in cache"
fi

PKGS=( $(ls -1 *.pkg.tar.* | sort) )
echo
echo "Installing packages with pacman..."
sudo pacman -U --noconfirm --needed "${PKGS[@]}"

echo
echo "${GREEN}Done!${RESET}"
echo "kernel-install should have created a BLS entry titled: Arch Linux (CIP)"
echo "Packages installed: ${PKGBASE} and ${PKGBASE}-headers"
echo
echo "Check with: bootctl list && kernel-install inspect --verbose"

############################################
# Install the auto-updater and pacman hook
############################################
install_updater() {
  local self_path; self_path="$(readlink -f "$0")"
  local owner; owner="$(id -un)"

  echo "${BLUE}Installing CIP auto-updater and pacman hook...${RESET}"
  # Config used by the updater
  sudo install -Dm644 /dev/stdin "$UPDATER_CONF" <<EOF
# cip-kernel auto-updater configuration
OWNER="$owner"
BUILDER="$self_path"
CLONE_URL="$CLONE_URL"
BUILD_CACHE_DIR="$BUILD_CACHE_DIR"
CONFIG_CACHE_DIR="$CONFIG_CACHE_DIR"
CCACHE_DIR="$CCACHE_DIR"
EOF

  # Updater binary
  sudo install -Dm755 /dev/stdin "$UPDATER_BIN" <<'UPD'
#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/cip-kernel-updater.conf"
[[ -r "$CONF" ]] && source "$CONF"

: "${CLONE_URL:=https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git}"
: "${BUILD_CACHE_DIR:=/var/cache/cip-builds}"
: "${CONFIG_CACHE_DIR:=/etc/cip-kernel}"
: "${CCACHE_DIR:=/var/cache/ccache/cip}"
: "${OWNER:=root}"
: "${BUILDER:=/usr/local/bin/cip-builder-not-set}"

STATE_DIR="/var/lib/cip-kernel"
mkdir -p "$STATE_DIR"

kver="$(uname -r)"
moddir="/usr/lib/modules/${kver}"
pkgbase_file="${moddir}/pkgbase"
commit_file="${moddir}/source_commit"

# Only act if running a CIP kernel
if [[ ! -f "$pkgbase_file" ]]; then
  exit 0
fi
pkgbase="$(cat "$pkgbase_file" 2>/dev/null || true)"
case "$pkgbase" in
  linux-cip|linux-cip-rt|linux-cip-rebase) ;;
  *) exit 0 ;;
esac

suffix=""
[[ "$pkgbase" == "linux-cip-rt" ]] && suffix="-rt"
[[ "$pkgbase" == "linux-cip-rebase" ]] && suffix="-rebase"

# Derive branch from running kernel version
if [[ "$kver" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
  majmin="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
else
  exit 0
fi
branch="linux-${majmin}.y-cip${suffix}"

# Remote head SHA
remote_sha="$(git ls-remote "$CLONE_URL" "refs/heads/${branch}" | awk '{print $1}')"
if [[ -z "${remote_sha}" ]]; then
  exit 0
fi

# Local commit SHA we are running
local_sha=""
if [[ -f "$commit_file" ]]; then
  local_sha="$(cat "$commit_file" 2>/dev/null || true)"
fi
# If missing, try previous build state
if [[ -z "$local_sha" ]]; then
  br_safe="$(printf '%s' "$branch" | sed 's@[^A-Za-z0-9._-]@-@g')"
  state="${BUILD_CACHE_DIR}/${br_safe}/.build_state"
  [[ -r "$state" ]] && source "$state" || true
  local_sha="${LAST_COMMIT:-}"
fi

# Skip if already up to date
if [[ -n "$local_sha" && "$local_sha" == "$remote_sha" ]]; then
  exit 0
fi

# Avoid immediate re-trigger after our own install
stamp="${STATE_DIR}/last_${branch//\//_}.state"
if [[ -f "$stamp" ]]; then
  . "$stamp" || true
  now=$(date +%s)
  if [[ "${LAST_SHA:-}" == "$remote_sha" ]] && (( now - ${LAST_TIME:-0} < 86400 )); then
    exit 0
  fi
fi

# Wait for pacman DB lock to clear
for i in {1..60}; do
  [[ ! -e /var/lib/pacman/db.lck ]] && break
  sleep 5
done

# Build as the recorded owner, never as root
# Prepare env, prefer saved default hardware profile if present
lsmod_profile="${CONFIG_CACHE_DIR}/profiles/default.modules"
envs=(CCACHE_DIR="$CCACHE_DIR" BUILD_CACHE_DIR="$BUILD_CACHE_DIR" CONFIG_CACHE_DIR="$CONFIG_CACHE_DIR" USE_CCACHE=1 USE_LOCALMODCONFIG=1 DEBUG_SYMBOLS=0)
if [[ -f "$lsmod_profile" ]]; then
  envs+=(LSMOD="$lsmod_profile")
fi

if command -v sudo >/dev/null 2>&1; then
  sudo -u "$OWNER" env "${envs[@]}" bash -lc "'$BUILDER' --branch '$branch'"
else
  su -s /bin/bash - "$OWNER" -c "env ${envs[*]} '$BUILDER' --branch '$branch'"
fi

# Record stamp
date_epoch=$(date +%s)
cat > "$stamp" <<EOF
LAST_SHA="$remote_sha"
LAST_TIME="$date_epoch"
EOF

exit 0
UPD

  # Pacman hook, runs after any transaction
  sudo install -Dm644 /dev/stdin "$UPDATER_HOOK" <<'HOO'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = CIP kernel auto-update check
When = PostTransaction
NeedsTargets = False
Exec = /usr/local/bin/cip-kernel-autoupdate
HOO

  echo "${GREEN}Installed:${RESET} $UPDATER_BIN and $UPDATER_HOOK"
  echo "Config: $UPDATER_CONF"
}

install_updater
