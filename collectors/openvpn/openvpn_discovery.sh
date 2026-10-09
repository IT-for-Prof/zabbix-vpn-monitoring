#!/usr/bin/env bash
# OpenVPN probe-target discovery -> Zabbix LLD JSON. Read-only. Handles community OpenVPN AND
# OpenVPN Access Server. Uniform contract {#VPN_IFACE},{#VPN_TARGET},{#VPN_TECH}=openvpn,
# {#VPN_DYNAMIC}=0|1; empty target -> LLD filter drops the row. Override per-iface via $1
# ({$VPN.PROBE.TARGETS}) (community path only).
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

sep=""
emit() {
  printf '%s{"{#VPN_IFACE}":"%s","{#VPN_TARGET}":"%s","{#VPN_TECH}":"openvpn","{#VPN_DYNAMIC}":"%s"}' "$sep" "$1" "$2" "$3"
  sep=","
}

# --- OpenVPN Access Server path (sacli VPNStatus JSON) ---
as_json=""
as_source=0
if [ -n "${OPENVPN_AS_VPNSTATUS:-}" ]; then
  as_source=1
  if ! as_json=$(cat "$OPENVPN_AS_VPNSTATUS" 2>/dev/null); then
    exit 1
  fi
else
  sa=/usr/local/openvpn_as/scripts/sacli; [ -x "$sa" ] || sa=$(command -v sacli 2>/dev/null) || sa=""
  if [ -n "$sa" ]; then
    as_source=1
    if ! as_json=$("$sa" VPNStatus 2>/dev/null); then
      if ! as_json=$(sudo -n "$sa" VPNStatus 2>/dev/null); then
        exit 1
      fi
    fi
  fi
fi
if [ "$as_source" -eq 1 ]; then
  [ -n "$as_json" ] || exit 1
  if ! vaddrs=$(printf '%s' "$as_json" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
if not isinstance(d, dict) or not d: sys.exit(2)
seen = False
for info in d.values():
    if not isinstance(info, dict): continue
    if "routing_table_header" not in info or "routing_table" not in info: continue
    seen = True
    header = info["routing_table_header"]
    rows = info["routing_table"]
    if not isinstance(header, dict) or not isinstance(rows, list): sys.exit(2)
    va = header.get("Virtual Address")
    if not isinstance(va, int): sys.exit(2)
    for row in rows:
        if not isinstance(row, list) or va >= len(row) or not isinstance(row[va], str): sys.exit(2)
        print(row[va])
if not seen: sys.exit(2)')
  then
    exit 1
  fi
  printf '{"data":['
  for v in $vaddrs; do
    case "$v" in ''|*[!0-9.]*) continue ;; esac            # IPv4-ish only: one bad vaddr must not break the JSON
    ifc=$(iface_for "$v"); emit "${ifc:-openvpn}" "$v" 1  # connected Access Server client (data-only)
  done
  printf ']}\n'; exit 0
fi

# --- community OpenVPN path ---
printf '{"data":['
# shellcheck disable=SC2086,SC2046  # $DIRS and find output are intentionally word-split
for cfg in $(find $DIRS -maxdepth 2 \( -name '*.conf' -o -name '*.ovpn' \) 2>/dev/null | sort -u); do
  [ -f "$cfg" ] || continue
  ifc=$(awk 'tolower($1)=="dev" && $2 ~ /^(tun|tap|ovpns)[0-9]+$/ {print $2; exit}' "$cfg")
  [ -n "$ifc" ] || continue
  ov=$(get_override "$ifc")
  if [ -n "$ov" ]; then emit "$ifc" "$ov" 0; continue; fi
  if awk 'tolower($1)=="client"||tolower($1)=="remote"{c=1} END{exit !c}' "$cfg"; then
    peer=$(ip -o -4 addr show dev "$ifc" 2>/dev/null | grep -oE 'peer [0-9.]+' | awk '{print $2}' | head -1)
    emit "$ifc" "${peer:-}" 0
  else
    sfile=$(awk 'tolower($1)=="status"{print $2; exit}' "$cfg")
    # Read the status file directly; it must be group-readable because no file reader is in sudoers.
    vlist=$( [ -n "$sfile" ] && awk -F'\t' '
      $1=="ROUTING_TABLE" { print $2; next }
      /^ROUTING_TABLE,/ { split($0, f, ","); print f[2]; next }
      $0=="ROUTING TABLE" { v1=1; next }
      $0=="GLOBAL STATS"  { v1=0 }
      v1 && $0 !~ /^Virtual Address,/ { split($0, f, ","); print f[1] }' "$sfile" 2>/dev/null)
    if [ -n "$vlist" ]; then for v in $vlist; do case "$v" in ''|*[!0-9.]*) continue ;; esac; emit "$ifc" "$v" 0; done
    else emit "$ifc" "" 0; fi
  fi
done
printf ']}\n'
