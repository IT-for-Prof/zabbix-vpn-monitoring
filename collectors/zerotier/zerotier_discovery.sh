#!/usr/bin/env bash
# ZeroTier probe-target discovery -> Zabbix LLD JSON. Read-only (only `zerotier-cli -j listnetworks`).
# One row per joined ZT network that has an interface (portDeviceName), emitting the uniform contract:
#   {#VPN_IFACE}, {#VPN_TARGET}, {#VPN_TECH}=zerotier
# Target = a per-iface override from $1 ("iface=ip,..." via {$VPN.PROBE.TARGETS}), else a managed-route
# `via` gateway on that iface (prefers the default route). No target -> {#VPN_TARGET}="" (LLD filter drops it).
overrides="${1:-}"

get_override() {
  local iface="$1" entry val
  local IFS=,
  for entry in $overrides; do
    case "$entry" in
      "${iface}="*)
        val="${entry#*=}"
        case "$val" in ''|*[!0-9.]*) return ;; esac   # clean IPv4-ish only; reject junk so JSON stays valid
        printf '%s' "$val"; return ;;
    esac
  done
}

target_for() {   # prefer the default-route via, else the first `via` gateway on the iface
  ip -o -4 route show dev "$1" 2>/dev/null | awk '
    $1=="default" && $2=="via" { def=$3 }
    $2=="via" && first=="" { first=$3 }
    END { print (def!="" ? def : first) }'
}

raw=$( zerotier-cli -j listnetworks 2>/dev/null || { command -v zerotier-cli >/dev/null 2>&1 && sudo -n zerotier-cli -j listnetworks 2>/dev/null; } )  # sudo -n ONLY if zerotier-cli exists -> no failed-sudo on non-ZT hosts
ifaces=$(printf '%s' "$raw" | python3 -c '
import json,sys
try: nets=json.load(sys.stdin)
except Exception: sys.exit(0)
for n in (nets or []):
    if isinstance(n, dict):
        d=n.get("portDeviceName") or ""
        if d: print(d)
' 2>/dev/null)

sep=""; printf '{"data":['
for ifc in $ifaces; do
  t=$(get_override "$ifc"); [ -n "$t" ] || t=$(target_for "$ifc")
  printf '%s{"{#VPN_IFACE}":"%s","{#VPN_TARGET}":"%s","{#VPN_TECH}":"zerotier"}' "$sep" "$ifc" "$t"; sep=","
done
printf ']}\n'
