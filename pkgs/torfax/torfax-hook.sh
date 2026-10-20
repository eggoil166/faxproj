log() { logger -t torfax -- "$*" || true; }

valid_job() { [[ $1 =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]]; }

hook_rx() {
  local from=${1:-} to=${2:-} status=${3:-} mode=${4:-} pages=${5:-} rate=${6:-}
  local remote=${7:-} error=${8:-} tif=${9:-}
  local inbox=${cfg[state]}/inbox id name pdf=""
  [[ -n $tif ]] || exit 0 # hung up before the fax was answered
  [[ $tif == "${cfg[spool]}"/fax/incoming/*.tif && $tif != */../* ]] || die "rx: unexpected file $tif"
  id=$(basename "$tif" .tif)
  [[ $from == self ]] && from=${cfg[station]}
  name=$(lookup_name "$from") || name=""
  if [[ -s $tif ]]; then
    if tiff2pdf -o "$inbox/.$id.pdf" "$tif" 2>/dev/null; then
      chmod 0640 "$inbox/.$id.pdf"
      mv -f "$inbox/.$id.pdf" "$inbox/$id.pdf"
      pdf=$id.pdf
      rm -f "$tif"
    else
      rm -f "$inbox/.$id.pdf"
      log "rx $id: tiff2pdf failed, TIFF kept at $tif"
    fi
  fi
  write_meta "$inbox/$id.meta" \
    "id=$id" "received=$(date -Is)" "from=$from" "from_name=$name" "to=$to" \
    "remote_id=$remote" "status=${status:-FAILED}" "mode=$mode" "pages=${pages:-0}" \
    "rate=$rate" "error=$error" "pdf=$pdf"
  log "rx $id from $from: status=${status:-FAILED} mode=$mode pages=${pages:-0} rate=$rate $error"
}

hook_tx() {
  local job=${1:-} status=${2:-} mode=${3:-} pages=${4:-} rate=${5:-} remote=${6:-} error=${7:-}
  local f=${cfg[state]}/outbox/$job.meta
  valid_job "$job" && [[ -f $f ]] || {
    log "tx $job: no outbox entry"
    exit 0
  }
  read_meta "$f"
  update_meta "$f" "status=${status:-FAILED}" "mode=$mode" "pages_sent=${pages:-0}" \
    "rate=$rate" "remote_id=$remote" "error=${error:-no fax result}" \
    "attempts=$((${meta[attempts]:-0} + 1))" "finished=$(date -Is)"
  log "tx $job to ${meta[to]:-?}: status=${status:-FAILED} mode=$mode pages=${pages:-0} rate=$rate $error"
}

hook_txfail() {
  local job=${1:-} reason=${2:-} why status=RETRYING attempts
  local f=${cfg[state]}/outbox/$job.meta
  valid_job "$job" && [[ -f $f ]] || {
    log "txfail $job: no outbox entry"
    exit 0
  }
  case $reason in
  1) why="hung up" ;;
  3) why="no answer" ;;
  5) why="busy" ;;
  8) why="congestion" ;;
  *) why="unreachable" ;;
  esac
  read_meta "$f"
  attempts=$((${meta[attempts]:-0} + 1))
  ((attempts < ${meta[tries]:-1})) || status=FAILED
  update_meta "$f" "status=$status" "attempts=$attempts" "error=$why" "finished=$(date -Is)"
  log "tx $job to ${meta[to]:-?}: call attempt $attempts failed: $why"
}

load_config
case ${1:-} in
rx)
  shift
  hook_rx "$@"
  ;;
tx)
  shift
  hook_tx "$@"
  ;;
txfail)
  shift
  hook_txfail "$@"
  ;;
*) die "usage: torfax-hook rx|tx|txfail ARGS..." ;;
esac
