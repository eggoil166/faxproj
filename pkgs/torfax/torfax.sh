usage() {
  cat <<EOF
usage: torfax send <file.pdf> <number>   fax a PDF to a station
       torfax inbox                      list received faxes
       torfax outbox                     list sent faxes and their status
       torfax phonebook                  list stations
EOF
}

need_dir() {
  [[ -r $1 && -x $1 ]] || die "cannot read $1 (add your user to services.torfax.users, then log in again)"
}

cmd_send() {
  [[ $# -eq 2 ]] || {
    usage >&2
    exit 2
  }
  local src=$1 number=$2 name endpoint job pages tif tmp tries
  local outbox=${cfg[state]}/outbox staging=${cfg[spool]}/torfax-staging
  [[ -r $src ]] || die "cannot read $src"
  [[ $number =~ ^[0-9]{4}$ ]] || die "fax numbers are 4 digits, got '$number'"
  name=$(lookup_name "$number") || die "$number is not in the phonebook (see: torfax phonebook)"
  if [[ $number == "${cfg[station]}" ]]; then endpoint=self; else endpoint=$number; fi
  [[ -w $outbox && -w $staging ]] ||
    die "no write access to $outbox or $staging (add your user to services.torfax.users, then log in again)"

  job=$(date -u +%Y%m%d-%H%M%S)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" EXIT

  gs -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=tiffg3 -r204x196 -g1728x2156 \
    -dFIXEDMEDIA -dPDFFitPage -sOutputFile="$tmp/fax.tif" -f "$src" ||
    die "ghostscript could not convert $src"
  pages=$(tiffinfo "$tmp/fax.tif" 2>/dev/null | grep -c '^TIFF Directory') || true
  [[ $pages -gt 0 ]] || die "converting $src produced no pages"

  tif=$outbox/$job.tif
  install -m 0640 "$tmp/fax.tif" "$tif"
  tries=$((${cfg[max_retries]:-3} + 1))
  write_meta "$outbox/$job.meta" \
    "job=$job" "to=$number" "to_name=$name" "source=$(basename "$src")" "pages=$pages" \
    "queued=$(date -Is)" "status=QUEUED" "attempts=0" "tries=$tries"

  cat >"$staging/$job.call" <<EOF
Channel: PJSIP/$number@$endpoint
Callerid: <${cfg[station]}>
WaitTime: ${cfg[wait_time]:-90}
MaxRetries: ${cfg[max_retries]:-3}
RetryTime: ${cfg[retry_time]:-120}
Context: torfax-outbound
Extension: $number
Priority: 1
Setvar: FAXFILE=$tif
Setvar: TORFAX_JOB=$job
EOF
  chmod 0660 "$staging/$job.call"
  mv -T "$staging/$job.call" "${cfg[spool]}/outgoing/$job.call"
  echo "queued $job: $pages page(s) to $number ($name)"
}

cmd_inbox() {
  local dir=${cfg[state]}/inbox f
  need_dir "$dir"
  printf '%-25s  %-4s  %-16s  %5s  %-7s  %s\n' RECEIVED FROM NAME PAGES STATUS PDF
  for f in "$dir"/*.meta; do
    [[ -e $f ]] || continue
    read_meta "$f"
    printf '%-25s  %-4s  %-16s  %5s  %-7s  %s\n' "${meta[received]:-?}" "${meta[from]:-?}" \
      "${meta[from_name]:--}" "${meta[pages]:-0}" "${meta[status]:-?}" "${meta[pdf]:+$dir/${meta[pdf]}}"
  done
}

cmd_outbox() {
  local dir=${cfg[state]}/outbox f detail
  need_dir "$dir"
  printf '%-22s  %-4s  %-16s  %5s  %-8s  %s\n' JOB TO NAME PAGES STATUS DETAIL
  for f in "$dir"/*.meta; do
    [[ -e $f ]] || continue
    read_meta "$f"
    case ${meta[status]:-} in
    SUCCESS) detail="${meta[mode]:-} ${meta[rate]:-}bps, ${meta[pages_sent]:-0} sent" ;;
    QUEUED) detail="queued ${meta[queued]:-}" ;;
    *) detail="${meta[error]:-} (attempt ${meta[attempts]:-0}/${meta[tries]:-?})" ;;
    esac
    printf '%-22s  %-4s  %-16s  %5s  %-8s  %s\n' "${meta[job]:-?}" "${meta[to]:-?}" \
      "${meta[to_name]:--}" "${meta[pages]:-0}" "${meta[status]:-?}" "$detail"
  done
}

cmd_phonebook() {
  printf '%-6s  %-16s  %-12s  %s\n' NUMBER NAME ADDRESS ROLE
  awk -F'\t' -v me="${cfg[station]}" -v hub="${cfg[hub]:-}" '{
    role = ($1 == hub) ? "hub" : "spoke"
    if ($1 == me) role = role " (you)"
    printf "%-6s  %-16s  %-12s  %s\n", $1, $2, $3, role
  }' "${cfg[phonebook]}"
}

case ${1:-} in
-h | --help | help)
  usage
  exit 0
  ;;
esac
load_config
case ${1:-} in
send)
  shift
  cmd_send "$@"
  ;;
inbox) cmd_inbox ;;
outbox) cmd_outbox ;;
phonebook) cmd_phonebook ;;
*)
  usage >&2
  exit 2
  ;;
esac
