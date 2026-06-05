#!/usr/bin/env bash
# WireGuard probe-target discovery -> Zabbix LLD JSON. No privilege.
# Emits one row per (interface, peer /32 host-route via that interface).
# Interfaces with no host route fall back to a per-iface override from $1
# (comma-separated iface=ip list, e.g. "wgB=192.0.2.3,wgC=10.0.0.1"),
# which is passed via the Zabbix macro {$WG.PROBE.TARGETS}.
# If neither a route nor an override exists, emits {#WG_TARGET}="" -> template
# LLD filter drops those rows, leaving those tunnels unprobed.
overrides="${1:-}"

get_override() {
  local iface="$1" entry val
  local IFS=,
  for entry in $overrides; do
    case "$entry" in
      "${iface}="*)
        val="${entry#*=}"
        case "$val" in ''|*[!0-9.]*) return ;; esac   # clean IPv4-ish only; reject junk so the LLD JSON stays valid
        printf '%s' "$val"; return ;;
    esac
  done
}

# Union WireGuard + AmneziaWG interfaces (awg mirrors wg's CLI); awg absent is silently
# empty. Fall back to the kernel link list only when neither tool yields anything.
ifaces=$( { wg show interfaces 2>/dev/null; awg show interfaces 2>/dev/null; } | tr ' ' '\n' | grep -v '^$' | sort -u)
[ -n "$ifaces" ] || ifaces=$(ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}')
sep=""; printf '{"data":['
for ifc in $ifaces; do
  targets=$(ip -o -4 route show dev "$ifc" 2>/dev/null | awk '
    $1=="default" { next }
    $1 ~ /\/32$/  { ip=$1; sub(/\/32$/,"",ip); print ip; next }
    $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1 }' | sort -u)
  if [ -z "$targets" ]; then
    targets=$(get_override "$ifc")
  fi
  if [ -z "$targets" ]; then
    printf '%s{"{#WG_IFACE}":"%s","{#WG_TARGET}":""}' "$sep" "$ifc"; sep=","
  else
    for t in $targets; do
      printf '%s{"{#WG_IFACE}":"%s","{#WG_TARGET}":"%s"}' "$sep" "$ifc" "$t"; sep=","
    done
  fi
done
printf ']}\n'
