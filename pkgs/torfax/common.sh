die() {
  echo "torfax: $*" >&2
  exit 1
}

declare -A cfg=()
load_config() {
  local conf=${TORFAX_CONF:-/etc/torfax/torfax.conf} k v
  [[ -r $conf ]] || die "cannot read $conf (is services.torfax enabled, and are you in the torfax group?)"
  while IFS='=' read -r k v; do
    [[ -z $k || $k == \#* ]] && continue
    cfg[$k]=$v
  done <"$conf"
  for k in station phonebook state spool; do
    [[ -n ${cfg[$k]:-} ]] || die "$conf: missing $k="
  done
}

lookup_name() {
  awk -F'\t' -v n="$1" '$1 == n { print $2; found = 1 } END { exit !found }' "${cfg[phonebook]}"
}

declare -A meta=()
read_meta() {
  local k v
  meta=()
  while IFS='=' read -r k v; do
    [[ -n $k ]] && meta[$k]=$v
  done <"$1"
}

write_meta() {
  local file=$1 tmp
  shift
  tmp=$(mktemp "$(dirname "$file")/.meta.XXXXXX")
  printf '%s\n' "${@//$'\n'/ }" >"$tmp"
  chmod 0660 "$tmp"
  mv -f "$tmp" "$file"
}

update_meta() {
  local file=$1 kv k
  shift
  read_meta "$file"
  for kv in "$@"; do
    meta[${kv%%=*}]=${kv#*=}
  done
  local lines=()
  for k in "${!meta[@]}"; do
    lines+=("$k=${meta[$k]}")
  done
  mapfile -t lines < <(printf '%s\n' "${lines[@]}" | sort)
  write_meta "$file" "${lines[@]}"
}
