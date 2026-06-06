#!/usr/bin/env bash
# OpenVPN probe-target discovery -> Zabbix LLD JSON. Read-only. Handles community OpenVPN AND
# OpenVPN Access Server. Uniform contract {#VPN_IFACE},{#VPN_TARGET},{#VPN_TECH}=openvpn; empty target
# -> LLD filter drops the row. Override per-iface via $1 ({$VPN.PROBE.TARGETS}) (community path only).
#
#  Access Server: each connected client from `sacli VPNStatus` -> {iface=as0tN (via route), target=client vaddr}.
#  Community: per instance with an EXPLICIT dev iface (tunN/tapN/ovpnsN; bare `dev tun` is runtime-
#    assigned and unmappable, so skipped) -> server: one row per connected client; client: PtP peer.
# Test hooks: OPENVPN_AS_VPNSTATUS=<json file> (AS), OPENVPN_CONF_DIRS=<dirs> (community).
overrides="${1:-}"
DIRS=${OPENVPN_CONF_DIRS:-/etc/openvpn /etc/openvpn/server /etc/openvpn/client /var/etc/openvpn}

get_override() {
  local iface="$1" e v; local IFS=,
  for e in $overrides; do
    case "$e" in "${iface}="*) v="${e#*=}"; case "$v" in ''|*[!0-9.]*) return ;; esac; printf '%s' "$v"; return ;; esac
  done
}
iface_for() { ip -o -4 route get "$1" 2>/dev/null | grep -oE 'dev [a-zA-Z0-9._-]+' | awk '{print $2}' | head -1; }

sep=""; printf '{"data":['
emit() { printf '%s{"{#VPN_IFACE}":"%s","{#VPN_TARGET}":"%s","{#VPN_TECH}":"openvpn"}' "$sep" "$1" "$2"; sep=","; }

# --- OpenVPN Access Server path (sacli VPNStatus JSON) ---
as_json=""
if [ -n "${OPENVPN_AS_VPNSTATUS:-}" ]; then
  as_json=$(cat "$OPENVPN_AS_VPNSTATUS" 2>/dev/null)
else
  sa=/usr/local/openvpn_as/scripts/sacli; [ -x "$sa" ] || sa=$(command -v sacli 2>/dev/null) || sa=""
  [ -n "$sa" ] && as_json=$("$sa" VPNStatus 2>/dev/null || sudo -n "$sa" VPNStatus 2>/dev/null)
fi
if [ -n "$as_json" ]; then
  vaddrs=$(printf '%s' "$as_json" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for info in d.values():
    if not isinstance(info, dict): continue
    va = (info.get("routing_table_header") or {}).get("Virtual Address", 0)
    for row in (info.get("routing_table") or []):
        try: print(row[va])
        except (IndexError, TypeError): pass')
  for v in $vaddrs; do
    case "$v" in ''|*[!0-9.]*) continue ;; esac            # IPv4-ish only: one bad vaddr must not break the JSON
    ifc=$(iface_for "$v"); emit "${ifc:-openvpn}" "$v"     # connected client (dark client -> probe -1, data-only)
  done
  printf ']}\n'; exit 0
fi

# --- community OpenVPN path ---
# shellcheck disable=SC2086,SC2046  # $DIRS and find output are intentionally word-split
for cfg in $(find $DIRS -maxdepth 2 \( -name '*.conf' -o -name '*.ovpn' \) 2>/dev/null | sort -u); do
  [ -f "$cfg" ] || continue
  ifc=$(awk 'tolower($1)=="dev" && $2 ~ /^(tun|tap|ovpns)[0-9]+$/ {print $2; exit}' "$cfg")
  [ -n "$ifc" ] || continue
  ov=$(get_override "$ifc")
  if [ -n "$ov" ]; then emit "$ifc" "$ov"; continue; fi
  if awk 'tolower($1)=="client"||tolower($1)=="remote"{c=1} END{exit !c}' "$cfg"; then
    peer=$(ip -o -4 addr show dev "$ifc" 2>/dev/null | grep -oE 'peer [0-9.]+' | awk '{print $2}' | head -1)
    emit "$ifc" "${peer:-}"
  else
    sfile=$(awk 'tolower($1)=="status"{print $2; exit}' "$cfg")
    txt=$( [ -n "$sfile" ] && cat "$sfile" 2>/dev/null )   # status file read directly; `cat` isn't in sudoers (sudo'ing it only logged failed-sudo) — make the file group-readable instead
    vlist=$(printf '%s' "$txt" | awk -F'\t' '$1=="ROUTING_TABLE"{print $2}')
    if [ -n "$vlist" ]; then for v in $vlist; do case "$v" in ''|*[!0-9.]*) continue ;; esac; emit "$ifc" "$v"; done
    else emit "$ifc" ""; fi
  fi
done
printf ']}\n'
