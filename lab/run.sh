#!/usr/bin/env bash
set -euo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
prefix=$(dirname "$(dirname "$(command -v asterisk)")")
mod=$prefix/lib/asterisk/modules

mkdir -p "$lab"/etc "$lab"/var/{lib,log,run} "$lab"/var/spool/{outgoing,tmp,fax/incoming,fax/outgoing}

cp -n --no-preserve=mode "$prefix"/etc/asterisk/*.conf "$lab/etc" 2>/dev/null || true
cp -rn --no-preserve=mode "$prefix"/var/lib/asterisk/. "$lab/var/lib/" 2>/dev/null || true
sed -e "s|@LAB@|$lab|g" -e "s|@MOD@|$mod|g" -e "s|@SBIN@|$prefix/sbin|g" "$lab/asterisk.conf.in" > "$lab/etc/asterisk.conf"
exec asterisk -f -c -C "$lab/etc/asterisk.conf" "$@"
