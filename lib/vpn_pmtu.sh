#!/usr/bin/env bash
# shellcheck disable=SC1010  # `ping -M do`: 'do' is ping's don't-fragment arg, not a loop keyword
# VPN-agnostic differential PMTU probe with a per-technology liveness gate.
# Usage: vpn_pmtu.sh <iface> <target_ip> <tech>     tech: wireguard|openvpn|zerotier
# Output (single int):
#   -2  = offline: the gate reports the tunnel is down (never/stale liveness; data-only, never paged)
#   -1  = live tunnel but target answers no ICMP (small control ping fails)
#    0  = healthy (a packet at the interface MTU is delivered)
#   >0  = configured_MTU - max_deliverable (silent MTU black-hole gap, bytes)
#
# The gate (lib/gate_<tech>.sh <iface> <target>) prints a liveness epoch or nothing;
# this script owns the universal verdict: epoch 0 or older than VPN_LIVE_FRESH => offline (-2).
# Fail-safe: a missing/non-exec gate, or a gate that prints nothing, falls through to a plain
# measurement (Phase-1) — a sudo/cap fault must never mask a real MTU black hole.
# VPN_LIVE_FRESH (env, default 180s) = max liveness age still treated as "tunnel up"
# (the legacy WG_HS_FRESH name is still honored for back-compat).
set -u
ifc=${1:?usage: vpn_pmtu.sh <iface> <target_ip> <tech>}; tgt=${2:-}
tech=${3:?usage: vpn_pmtu.sh <iface> <target_ip> <tech>}
FRESH=${VPN_LIVE_FRESH:-${WG_HS_FRESH:-180}}
case "$tgt" in ''|*[!0-9.]*) echo -1; exit 0;; esac          # missing / non-IPv4 target (IPv4-only: see README)
case "$ifc" in ''|*[!a-zA-Z0-9._-]*) echo -1; exit 0;; esac  # reject non-interface chars before sysfs/wg/sudo use
mtu=$(cat "/sys/class/net/$ifc/mtu" 2>/dev/null)
[ -n "$mtu" ] || { echo -1; exit 0; }                        # interface gone

# --- liveness gate (per-tech; prints an epoch or nothing) -------------------
here=$(cd "$(dirname "$0")" && pwd)
gate="$here/gate_${tech}.sh"
if [ -x "$gate" ]; then
  age=$("$gate" "$ifc" "$tgt")          # gate prints a unix epoch (or 0/empty)
  case "$age" in *[!0-9]*) age=;; esac  # non-numeric gate output -> blank -> fall-safe to a real measurement (never crash/fabricate)
  if [ -n "$age" ]; then
    [ "$age" = "0" ] && { echo -2; exit 0; }                 # never connected -> offline
    now=$(date +%s)
    [ $(( now - age )) -gt "$FRESH" ] && { echo -2; exit 0; } # stale liveness -> offline
  fi
fi

# --- live tunnel (or gate unavailable): measure PMTU (identical for every tech) ---
# A small DF packet that round-trips proves both reachability AND a known-good lower bound
# (128B IP). The at-MTU check decides healthy vs gap. The gap size is then found by BISECTION,
# not a linear scan: PMTU is a single monotonic threshold (if size S delivers, all smaller do;
# if S fails, all larger fail), so log2 steps suffice. This bounds worst-case runtime to ~12
# pings even at a 65k MTU (a linear -20 scan was ~3262 pings / minutes -> agent-timeout / no page).
ping -M do -s 100 -c2 -W2 "$tgt" >/dev/null 2>&1 || { echo -1; exit 0; }          # reachable at all? (128B IP delivers)
ping -M do -s $((mtu-28)) -c3 -W2 "$tgt" >/dev/null 2>&1 && { echo 0; exit 0; }   # at-MTU delivers => healthy
[ "$mtu" -lt 220 ] && { echo 0; exit 0; }                    # below the 200B probe floor: differential unmeasurable
lo=128; hi=$mtu                                              # invariant: lo delivers (canary), hi does not (at-MTU)
while [ $(( hi - lo )) -gt 20 ]; do                          # converge to 20-byte resolution (matches the old grid)
  mid=$(( (lo + hi) / 2 ))
  if ping -M do -s $((mid-28)) -c1 -W2 "$tgt" >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
done
echo $(( mtu - lo ))                                         # gap = configured MTU - largest deliverable
