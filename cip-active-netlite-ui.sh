#!/usr/bin/env bash
# cip-active-netlite-ui-v8.sh
# Adds:
#   - Sort rows by remaining Time-to-EOL (descending, longest left on top)
#   - Hide -rebase branches by default, unless INCLUDE_REBASE=1
#
# Table columns: Branch, Status, Last Commit, First Release (YYYY-MM-DD), EOL (YYYY-MM), Time-to-EOL

set -euo pipefail

BASE="https://kernel.googlesource.com/pub/scm/linux/kernel/git/cip/linux-cip"
CLONE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/cip/linux-cip.git"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-120}"   # active if last commit < 120 days
NOW_EPOCH=$(date +%s)

# CIP wiki source view, easy to parse with pipes
CIP_WIKI_URL="https://wiki.linuxfoundation.org/civilinfrastructureplatform/start?do=edit"

need_cmd() { command -v "$1" >/dev/null 2>&1; }
curlq() { curl -fsSL "$1"; }  # quiet, fail on HTTP errors
trim() { awk '{$1=$1;print}'; }

# Terminal colors (respect NO_COLOR, TERM=dumb, and allow FORCE_COLOR=1)
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

# Convert "YYYY-MM" into epoch at last second of that month, use UTC to avoid DST
month_end_epoch() {
  local ym="$1"
  TZ=UTC date -d "${ym}-01 +1 month -1 day 23:59:59" +%s 2>/dev/null || echo 0
}

# Calendar-aware difference in years, months, days between two epochs (start < end)
# Always prints "X yrs Y mos Z days", zeros included, clamped at 0 when end <= start
diff_ymd() {
  local start="$1" end="$2"
  if (( end <= start )); then
    echo "0 yrs 0 mos 0 days"; return
  fi

  # Parse start and end in UTC to avoid DST artifacts
  local sy sm sd ey em ed
  read -r sy sm sd < <(TZ=UTC date -u -d "@$start" '+%Y %m %d')
  read -r ey em ed < <(TZ=UTC date -u -d "@$end"   '+%Y %m %d')

  # Total month distance ignoring days
  local months=$(( (10#$ey - 10#$sy)*12 + (10#$em - 10#$sm) ))

  # Anchor = start + months months, adjust back one month if it overshoots end
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

# Build maps:
#   EOL_MAP["6.1"]="2033-08", EOL_MAP["6.1-rt"]="2033-08"
#   FIRST_MAP["6.1"]="2023-07-14", FIRST_MAP["6.1-rt"]="2023-07-16"
declare -A EOL_MAP
declare -A FIRST_MAP
build_eol_map() {
  local src
  if ! src="$(curlq "$CIP_WIKI_URL" 2>/dev/null)"; then
    return 1
  fi
  # Use -F'[|]' to avoid awk escape warnings, match rows containing "SLTS vX.Y"
  while IFS='|' read -r _ col_ver _ col_first col_eol _ _; do
    local ver="$(printf '%s' "$col_ver"   | trim)"   # "SLTS v6.12" or "SLTS v6.1-rt"
    local first="$(printf '%s' "$col_first" | trim)" # "YYYY-MM-DD"
    local eol="$(printf '%s' "$col_eol"   | trim)"   # "YYYY-MM"
    ver="${ver#SLTS v}"
    if [[ "$ver" =~ ^[0-9]+\.[0-9]+(-rt)?$ ]]; then
      [[ "$eol"   =~ ^[0-9]{4}-[0-9]{2}$        ]] && EOL_MAP["$ver"]="$eol"
      [[ "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && FIRST_MAP["$ver"]="$first"
    fi
  done < <(printf '%s\n' "$src" | awk -F'[|]' '/[|][[:space:]]*SLTS v[0-9]+\.[0-9]+/ {print}')
}

# Map a branch name to EOL key: linux-6.1.y-cip[-rt|-rebase] -> "6.1" or "6.1-rt"
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

# Discover branches from +refs, optionally exclude *-rebase
REFS_HTML="$(curlq "$BASE/+refs")"
# Always detect all, we will filter unless INCLUDE_REBASE is set
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
  # Hide -rebase unless INCLUDE_REBASE is set
  for b in "${BRANCHES_ALL[@]}"; do
    [[ "$b" == *-rebase ]] && continue
    BRANCHES+=("$b")
  done
fi

# Read head in TEXT mode, base64-decode, parse committer epoch
branch_head_epoch() {
  local br="$1" b64 epoch
  if ! b64="$(curlq "$BASE/+/refs/heads/$br?format=TEXT" 2>/dev/null)"; then
    echo 0; return
  fi
  epoch="$(printf '%s' "$b64" | base64 -d 2>/dev/null \
           | awk '/^committer /{print $(NF-1); exit}')"
  [[ "$epoch" =~ ^[0-9]+$ ]] && printf '%s\n' "$epoch" || echo 0
}

# Pretty "N days ago" text, with nicer grammar
fmt_days_ago() {
  local d="$1"
  if   (( d <= 0 )); then echo "today"
  elif (( d == 1 )); then echo "1 day ago"
  else                   echo "$d days ago"
  fi
}

# Build maps once
build_eol_map || true

# Set up colors
setup_colors

# We will assemble body rows as:
#   "<eol_epoch>\t<printable tab-separated row>"
# then sort numerically on the hidden first column, reverse, and drop it.
declare -a BODY_SORTABLE=()
declare -a ACTIVE_SORTABLE=()

HEADER=$'Branch\tStatus\tLast Commit\tFirst Release\tEOL\tTime-to-EOL'

ACTIVE=()
for br in "${BRANCHES[@]}"; do
  epoch="$(branch_head_epoch "$br")"
  status="UNKNOWN"
  age_str="-"
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

  # Compute EOL epoch for sorting. Unknown -> -1 so it sorts to the very bottom.
  eol_epoch=-1
  tte="-"
  if [[ "$eol" != "UNKNOWN" ]]; then
    eol_epoch="$(month_end_epoch "$eol")"
    if (( eol_epoch > 0 )); then
      tte="$(diff_ymd "$NOW_EPOCH" "$eol_epoch")"
    else
      eol_epoch=-1
    fi
  fi

  # Printable row (tab separated for column -t)
  row="$(printf "%s\t%s\t%s\t%s\t%s\t%s" "$br" "$status" "$age_str" "$first_rel" "$eol" "$tte")"
  BODY_SORTABLE+=( "$(printf "%s\t%s" "$eol_epoch" "$row")" )

  # Keep ACTIVE list sortable by the same key so picker prefers long-lived branches on top
  if [[ "$status" == "ACTIVE" ]]; then
    ACTIVE_SORTABLE+=( "$(printf "%s\t%s" "$eol_epoch" "$br")" )
  fi
done

# Sort body by eol_epoch descending, drop the sort key, prepend header, then align
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

# Inject colors only if enabled, skip the header line
if [[ -n "${GREEN}${RED}${RESET}" ]]; then
  out="$(printf "%s\n" "$out" | sed -E "1! s/ACTIVE/${GREEN}&${RESET}/g; 1! s/STALE/${RED}&${RESET}/g")"
fi

printf "%s\n" "$out"

# Interactive pick of an ACTIVE branch, preferring longer EOL first
if ((${#ACTIVE[@]}==0)); then
  echo
  echo "No ACTIVE branches under the current threshold ($THRESHOLD_DAYS days)."
  exit 0
fi

echo
echo "Pick an ACTIVE branch:"
choice=""
# Build the sorted ACTIVE list
ACTIVE_LIST_SORTED="$(
  printf "%s\n" "${ACTIVE_SORTABLE[@]}" \
  | sort -t $'\t' -k1,1nr -k2,2 \
  | cut -f2-
)"

if need_cmd fzf; then
  # feed sorted names to fzf, top is the longest remaining EOL
  choice="$(printf "%s\n" "$ACTIVE_LIST_SORTED" | fzf --prompt="SLTS> " --height=10 --reverse)" || true
else
  # Bash select shows items in the given order
  PS3="Select branch> "
  # shellcheck disable=SC2207
  ACTIVE_ARR=( $(printf "%s\n" "$ACTIVE_LIST_SORTED") )
  select br in "${ACTIVE_ARR[@]}"; do choice="$br"; break; done
fi

[[ -n "${choice:-}" ]] && echo "You selected: $choice"

# Clone only the chosen branch from kernel.org, into a sanitized folder name
clone_selected_branch() {
  local br="$1"
  need_cmd git || { echo "git is required to clone."; return 1; }
  local dest="${2:-$(printf '%s' "$br" | sed 's@[^A-Za-z0-9._-]@-@g')}"
  if [[ -e "$dest" ]]; then
    echo "Destination '$dest' already exists. Aborting."
    return 1
  fi
  echo
  echo "Cloning '$br' into './$dest' (single branch)..."
  git clone --single-branch --branch "$br" "$CLONE_URL" "$dest"
  echo "Done. Repository at ./$dest"
}

if [[ -n "${choice:-}" ]]; then
  clone_selected_branch "$choice"
fi
