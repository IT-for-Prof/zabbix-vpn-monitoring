#!/usr/bin/env bash
# Liveness gate for WireGuard / AmneziaWG.
# Usage: gate_wireguard.sh <iface> <target_ip>
# Output: the target peer's latest-handshake epoch (seconds; 0 = never connected),
#         or NOTHING if the target isn't an exact /32 of any peer or state is unreadable.
# vpn_pmtu.sh owns the staleness verdict (0/stale => offline); this gate only reports.
#
# Key-free: uses only `{wg,awg} show <if> allowed-ips` + `... latest-handshakes`.
# `... dump`/`private-key` are NEVER called (dump's first field is the interface key).
# Tries a direct call first (root, e.g. the netns test) then `sudo -n` (prod: the
# unprivileged `zabbix` user, granted ONLY those two reads). If state cannot be read,
# prints nothing -> the probe fail-safes to a plain measurement (Phase-1 behaviour).
set -u
ifc=${1:?usage: gate_wireguard.sh <iface> <target_ip>}; tgt=${2:?}
bin=wg; case "$ifc" in awg*) bin=awg;; esac          # AmneziaWG mirrors wg's CLI
command -v "$bin" >/dev/null 2>&1 || bin=wg          # fall back if awg absent
show() { "$bin" show "$ifc" "$1" 2>/dev/null || sudo -n "$bin" show "$ifc" "$1" 2>/dev/null; }
# allowed-ips: "<pubkey>\t<ip> [ip ...]" per peer -> peer owning <target>/32
pk=$(show allowed-ips | awk -v t="$tgt/32" '{ for (i=2;i<=NF;i++) if ($i==t) { print $1; exit } }')
[ -n "$pk" ] || exit 0                               # target not a /32 peer -> let probe run
# latest-handshakes: "<pubkey>\t<epoch>" per peer (0 = never)
show latest-handshakes | awk -v p="$pk" '$1==p { print $2; exit }'
