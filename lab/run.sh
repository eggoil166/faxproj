#!/usr/bin/env bash
set -euo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
state=${FAXLAB_STATE:-$lab}
export TORFAX_STATION=${TORFAX_STATION:-0001}
prefix=$(dirname "$(dirname "$(readlink -f "$(command -v asterisk)")")")
mod=$prefix/lib/asterisk/modules

mkdir -p "$state"/etc "$state"/var/{lib,log/cdr-csv,run} "$state"/var/spool/{outgoing,tmp,fax/incoming,fax/outgoing}
cp -n --no-preserve=mode "$prefix"/etc/asterisk/*.conf "$state/etc/" 2>/dev/null || true
cp -rn --no-preserve=mode "$prefix"/var/lib/asterisk/. "$state/var/lib/" 2>/dev/null || true
chmod -R u+w "$state/etc" "$state/var"
ln -sf "$lab"/conf/*.conf "$state/etc/"

sed -e "s|@LAB@|$state|g" -e "s|@MOD@|$mod|g" -e "s|@SBIN@|$prefix/sbin|g" "$lab/asterisk.conf.in" > "$state/etc/asterisk.conf"

# hub<->vm calls ride the WireGuard tunnel; warn early instead of failing silently
if ! ip link show wg0 >/dev/null 2>&1; then
  role=hub; [ "$(hostname)" = labvm ] && role=vm
  echo "warning: wg0 is down; calls to the other side will fail." >&2
  echo "         sudo wg-quick up $lab/wg/$role/wg0.conf" >&2
fi

if [ "${1:-}" = bg ]; then
  conf=$state/etc/asterisk.conf
  asterisk -F -C "$conf"
  # 'core show version' answers before modules finish loading (slow under TCG);
  # a call file dropped before res_pjsip is up never gets dialed.
  for _ in $(seq 1 300); do
    asterisk -r -C "$conf" -x 'core waitfullybooted' >/dev/null 2>&1 && break
    sleep 1
  done
  if ! asterisk -r -C "$conf" -x 'pjsip show transports' 2>/dev/null | grep -q transport-udp; then
    echo "error: asterisk started but PJSIP transport-udp is not up" >&2
    exit 1
  fi
  echo "asterisk running in background (station $TORFAX_STATION)"
  echo "attach:  asterisk -rvvv -C $state/etc/asterisk.conf     (Ctrl-C detaches)"
else
  exec asterisk -f -c -C "$state/etc/asterisk.conf" "$@"
fi
