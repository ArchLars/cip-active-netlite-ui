#!/usr/bin/env bash
# cip-active-netlite-ui-optimized.sh
# Optimized CIP kernel build script with ccache, persistent builds, and update support
# Pick a CIP branch, then clone/update, build, package with makepkg, and register via kernel-install
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
USE_NINJA="${USE_NINJA:-0}"  # Experimental
USE_LOCALMODCONFIG="${USE_LOCALMODCONFIG:-1}"
INCREMENTAL_BUILD="${INCREMENTAL_BUILD:-1}"
DEBUG_SYMBOLS="${DEBUG_SYMBOLS:-0}"

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

# Check if build exists for branch
check_existing_build() {
  local branch="$1"
  local build_dir="${BUILD_CACHE_DIR}/${branch//\//_}"
  local state_file="${build_dir}/.build_state"
  
  if [[ -f "$state_file" ]]; then
    source "$state_file"
    echo "${GREEN}Found existing build:${RESET}"
    echo "  Branch: $LAST_BRANCH"
    echo "  Version: $LAST_VERSION"
    echo "  Commit: $LAST_COMMIT"
    echo "  Built: $LAST_BUILD_DATE"
    return 0
  fi
  return 1
}

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
  
  # Disable IKHEADERS to prevent constant regeneration
  ./scripts/config --file "$config_file" \
    -d IKHEADERS \
    -d IKHEADERS_PROC || true
  
  # Enable compression for modules
  ./scripts/config --file "$config_file" \
    -e MODULE_COMPRESS_GZIP || true
}

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

if ((${#ACTIVE[@]}==0)); then echo; echo "No ACTIVE branches under the current threshold ($THRESHOLD_DAYS days)."; exit 0; fi

# Check for update mode
if [[ "${1:-}" == "--update" ]] || [[ "${1:-}" == "-u" ]]; then
  echo
  echo "${BLUE}Update mode: Checking for existing builds...${RESET}"
  found_build=0
  for br in "${ACTIVE[@]}"; do
    if check_existing_build "$br"; then
      choice="$br"
      found_build=1
      break
    fi
  done
  
  if [[ "$found_build" == "0" ]]; then
    echo "${YELLOW}No existing builds found. Please run initial build first.${RESET}"
    exit 1
  fi
else
  echo; echo "Pick an ACTIVE branch:"
  choice=""
  ACTIVE_LIST_SORTED="$(printf "%s\n" "${ACTIVE_SORTABLE[@]}" | sort -t $'\t' -k1,1nr -k2,2 | cut -f2-)"
  if need_cmd fzf; then choice="$(printf "%s\n" "$ACTIVE_LIST_SORTED" | fzf --prompt="SLTS> " --height=10 --reverse)" || true
  else PS3="Select branch> "; ACTIVE_ARR=( $(printf "%s\n" "$ACTIVE_LIST_SORTED") ); select br in "${ACTIVE_ARR[@]}"; do choice="$br"; break; done; fi
  [[ -n "${choice:-}" ]] && echo "You selected: $choice"
fi

[[ -z "${choice:-}" ]] && exit 0

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
[[ "$USE_NINJA" == "1" ]] && require_tools+=(ninja python3)
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

# Check if this is an update or fresh build
IS_UPDATE=0
if [[ -d "${BUILD_DIR}/linux-cip" ]] && [[ -f "${BUILD_DIR}/.build_state" ]]; then
  echo "${GREEN}Found existing build directory. Performing incremental update...${RESET}"
  IS_UPDATE=1
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

# Use deterministic timestamp for ccache
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
    fi
    cd "${_builddir}"
    echo "Cloning fresh repository..."
    git clone --depth 1 --branch "${_branch}" \
      "https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git"
    cd linux-cip
  fi

  # Keep LOCALVERSION empty so kernelrelease stays clean
  echo "" > .scmversion

  # Configuration strategy
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

  # Optimize config
  @OPTIMIZE_CONFIG@

  # Save config for future updates
  cp .config "${_builddir}/.config.saved"
}

pkgver() {
  cd "${_builddir}/linux-cip"
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
  cd "${_builddir}/linux-cip"
  
  # Set up build environment
  if [[ $_use_ccache -eq 1 ]]; then
    export CC="${_cc_prefix}gcc"
    export HOSTCC="${_cc_prefix}gcc"
  fi
  
  # Incremental or clean build
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
  
  # Save build state
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
  
  # Architecture specific files
  find "${builddir}/arch" -mindepth 1 -maxdepth 1 ! -name x86 -exec rm -rf {} +
  
  # Clean up build files
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

# Clean build, install deps, no prompts
if [[ "$IS_UPDATE" == "1" ]]; then
  # For updates, skip cleaning source
  makepkg -se --noconfirm --needed
else
  # For fresh builds, do full clean
  makepkg -sCc --noconfirm
fi

if [[ "$USE_CCACHE" == "1" ]]; then
  echo
  echo "${BLUE}ccache statistics after build:${RESET}"
  ccache -s | grep -E "cache hit rate|cache size|files in cache"
fi

# Install both packages
PKGS=( $(ls -1 *.pkg.tar.* | sort) )
echo
echo "Installing packages with pacman..."
sudo pacman -U --noconfirm --needed "${PKGS[@]}"

echo
echo "${GREEN}Done!${RESET}"
echo "kernel-install should have created a BLS entry titled: Arch Linux (CIP)"
echo "Packages installed: ${PKGBASE} and ${PKGBASE}-headers"
echo
echo "${BLUE}Tips for next time:${RESET}"
echo "  - Run with --update flag for incremental builds: $0 --update"
echo "  - Save hardware profile: $0 --save-profile [name]"
echo "  - Load hardware profile: $0 --load-profile [name]"
echo "  - Merge multiple profiles: $0 --merge-profiles"
echo
echo "Check with: bootctl list && kernel-install inspect --verbose"

# Create update script for convenience
cat > update-cip-kernel.sh <<'UPDATE'
#!/bin/bash
# Quick update script for CIP kernels
exec "$(dirname "$0")/cip-active-netlite-ui-optimized.sh" --update "$@"
UPDATE
chmod +x update-cip-kernel.sh
echo
echo "${BLUE}Created update-cip-kernel.sh for quick updates${RESET}"
