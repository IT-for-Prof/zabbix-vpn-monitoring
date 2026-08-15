#!/usr/bin/env bash
# Liveness gate for WireGuard / AmneziaWG.
# Usage: gate_wireguard.sh <iface> <target_ip>
# Output: the target peer's latest-handshake epoch (seconds; 0 = never connected),
#         or NOTHING if the target isn't an exact /32 of any peer or state is unreadable.
# vpn_pmtu.sh owns the staleness verdict (0/stale => offline); this gate only reports.
#
# Key-free: uses only `{wg,awg} show all allowed-ips` + `... latest-handshakes`.
# `... dump`/`private-key` are NEVER called (dump's first field is the interface key).
# Tries a direct call first (root, e.g. the netns test) then `sudo -n` (prod: the
# unprivileged `zabbix` user, granted ONLY those two reads). If state cannot be read,
# prints nothing -> the probe fail-safes to a plain measurement (Phase-1 behaviour).
#
# `all`, not `<iface>`, ON PURPOSE. A per-interface call forces the sudoers rule to wildcard
# the interface name (`wg show * allowed-ips`), and sudo's `*` spans whitespace — so that rule
# also permits `wg show all dump allowed-ips`, i.e. the key-exposing subcommand smuggled in
# ahead of the allowed one. Only wg's own "no 4th argument" check stops it, which is a
# third-party binary's argument validation standing in for our access policy. Asking for `all`
# lets the grant be fully literal with no wildcard at all; we filter to $ifc here instead.
set -u
ifc=${1:?usage: gate_wireguard.sh <iface> <target_ip>}; tgt=${2:?}
bin=wg; case "$ifc" in awg*) bin=awg;; esac          # AmneziaWG mirrors wg's CLI
command -v "$bin" >/dev/null 2>&1 || bin=wg          # fall back if awg absent
# direct first; sudo -n ONLY if the binary exists (never sudo an absent cmd -> no failed-sudo noise)
show() { "$bin" show all "$1" 2>/dev/null || { command -v "$bin" >/dev/null 2>&1 && sudo -n "$bin" show all "$1" 2>/dev/null; }; }
# allowed-ips (all): "<iface>\t<pubkey>\t<ip> [ip ...]" -> peer on THIS iface owning <target>/32.
# The $1==i guard is load-bearing: the same /32 can exist on several interfaces.
pk=$(show allowed-ips | awk -v i="$ifc" -v t="$tgt/32" '$1==i { for (n=3;n<=NF;n++) if ($n==t) { print $2; exit } }')
[ -n "$pk" ] || exit 0                               # target not a /32 peer -> let probe run
# latest-handshakes (all): "<iface>\t<pubkey>\t<epoch>" (0 = never)
show latest-handshakes | awk -v i="$ifc" -v p="$pk" '$1==i && $2==p { print $3; exit }'
