#!/usr/bin/env bash
# Compat shim: the WireGuard probe now delegates to the generic vpn_pmtu.sh so the live
# `wg.pmtu[...]` items keep working unchanged (no re-discovery / history loss). The real
# logic — and the key-free handshake gate — lives in vpn_pmtu.sh + gate_wireguard.sh,
# which the installer drops into the same dir as this shim.
# Usage: wg_pmtu.sh <iface> <target_ip>
exec "$(cd "$(dirname "$0")" && pwd)/vpn_pmtu.sh" "${1:-}" "${2:-}" wireguard
