#!/usr/bin/env bash
# Fixture test for lib/gate_openvpn.sh — injects status sources via OPENVPN_STATUS_FILE/CMD.
# No OpenVPN/kernel needed. Covers status-v3 (server, per-client), status-v1 (client, whole-tunnel),
# the management-socket transcript, and the fail-safe paths.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
GATE="$REPO/lib/gate_openvpn.sh"
fail(){ echo "FAIL: $*"; exit 1; }
recent(){ [ "$1" -ge $((now-3)) ] 2>/dev/null && [ "$1" -le $((now+3)) ] 2>/dev/null; }  # binary "live" => ~now
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
now=$(date +%s)

# --- status-version 3 fixture (TAB-separated), one connected client 10.16.13.6 ---
{ printf 'TITLE\tOpenVPN 2.6.14\n'
  printf 'TIME\t2026-05-21 00:00:00\t%s\n' "$now"
  printf 'HEADER\tROUTING_TABLE\tVirtual Address\tCommon Name\tReal Address\tLast Ref\tLast Ref (time_t)\n'
  printf 'ROUTING_TABLE\t10.16.13.6\tclient1\t1.2.3.4:55\tThu May 21\t%s\n' "$now"
  printf 'END\n'; } > "$TMP/v3.status"

# 1) v3: connected target -> live (binary: present in the routing table => ~now)
v=$(OPENVPN_STATUS_FILE="$TMP/v3.status" bash "$GATE" tun0 10.16.13.6)
recent "$v" || fail "v3 connected: expected ~$now, got [$v]"
# 2) v3: target NOT in ROUTING_TABLE -> 0 (=> -2 offline)
v=$(OPENVPN_STATUS_FILE="$TMP/v3.status" bash "$GATE" tun0 10.16.13.99)
[ "$v" = "0" ] || fail "v3 absent target: expected 0, got [$v]"

# --- status-version 1 fixture (comma), whole-tunnel Updated line ---
upd=$(date -d "@$now" '+%a %b %e %T %Y')
{ printf 'OpenVPN STATISTICS\n'; printf 'Updated,%s\n' "$upd"; printf 'TUN/TAP read bytes,123\n'; printf 'END\n'; } > "$TMP/v1.status"
# 3) v1: prints the Updated date parsed to epoch (~now)
v=$(OPENVPN_STATUS_FILE="$TMP/v1.status" bash "$GATE" tun0 192.168.0.1)
exp=$(date -d "$upd" +%s)
[ "$v" = "$exp" ] || fail "v1 Updated: expected $exp, got [$v]"

# 4) empty / unparseable -> nothing (fail-safe -> probe ungated)
v=$(OPENVPN_STATUS_FILE=/dev/null bash "$GATE" tun0 10.16.13.6); [ -z "$v" ] || fail "empty: expected nothing, got [$v]"
echo "garbage no markers" > "$TMP/junk"; v=$(OPENVPN_STATUS_FILE="$TMP/junk" bash "$GATE" tun0 10.16.13.6); [ -z "$v" ] || fail "garbage: expected nothing, got [$v]"

# 5) management-socket transcript (status 3 over the socket) -> same v3 parse
v=$(OPENVPN_STATUS_CMD="printf 'TITLE\tOpenVPN\nROUTING_TABLE\t10.16.16.5\tc\t9.9.9.9:1\tnow\t$now\nEND\n'" bash "$GATE" ovpns1 10.16.16.5)
recent "$v" || fail "mgmt-socket v3: expected ~$now, got [$v]"

# 6) OpenVPN Access Server: sacli VPNStatus JSON — present in routing_table => live (binary, ~now)
cat > "$TMP/as.json" <<JSON
{"openvpn_0":{"routing_table":[["198.51.100.17","buh4","203.0.113.31:60586","Thu May 21 17:42:21 2026","$now"]],
 "routing_table_header":{"Virtual Address":0,"Common Name":1,"Real Address":2,"Last Ref":3,"Last Ref (time_t)":4}},
 "openvpn_1":{"routing_table":[],"routing_table_header":{"Virtual Address":0,"Last Ref (time_t)":4}}}
JSON
v=$(OPENVPN_STATUS_FILE="$TMP/as.json" bash "$GATE" as0t0 198.51.100.17)
recent "$v" || fail "AS connected client: expected ~$now, got [$v]"
v=$(OPENVPN_STATUS_FILE="$TMP/as.json" bash "$GATE" as0t0 10.30.13.99)
[ "$v" = "0" ] || fail "AS disconnected target: expected 0, got [$v]"

# 7) v3: a connected-but-idle client (Last Ref far in the past) is still LIVE — binary, not aged.
#    This is the idle-client regression the binary model fixes (was: aged out to -2 under FRESH).
{ printf 'TITLE\tOpenVPN\n'
  printf 'ROUTING_TABLE\t10.16.13.8\tidle\t1.2.3.4:9\told\t%s\n' "$((now-99999))"
  printf 'END\n'; } > "$TMP/v3idle.status"
v=$(OPENVPN_STATUS_FILE="$TMP/v3idle.status" bash "$GATE" tun0 10.16.13.8)
recent "$v" || fail "v3 idle-but-connected: expected ~$now (live), got [$v]"

echo "PASS: gate_openvpn — v3/AS binary present=live, idle-client live, v1 aged, mgmt-socket, fail-safe"
