#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes intentional: stub script emitted verbatim
# Fixture test for collectors/openvpn/openvpn_discovery.sh. Stubs configs/status/ip; no OpenVPN needed.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
DISC="$REPO/collectors/openvpn/openvpn_discovery.sh"
fail(){ echo "FAIL: $*"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/conf"; mkdir -p "$CFG" "$TMP/bin"

# client instance (explicit dev tun0)
{ echo client; echo "dev tun0"; echo "remote 1.2.3.4 1194"; } > "$CFG/client1.conf"
# server instance (dev ovpns1) + status-v3 with two connected clients
ST="$TMP/server.status"
{ printf 'TITLE\tOpenVPN\n'
  printf 'HEADER\tROUTING_TABLE\tVirtual Address\tCommon Name\tReal Address\tLast Ref\tLast Ref (time_t)\n'
  printf 'ROUTING_TABLE\t10.16.16.6\tc1\t9.9.9.9:1\tx\t111\n'
  printf 'ROUTING_TABLE\t10.16.16.7\tc2\t8.8.8.8:2\ty\t222\n'
  printf 'END\n'; } > "$ST"
{ echo "dev ovpns1"; echo "server 10.16.16.0 255.255.255.0"; echo "status $ST"; } > "$CFG/server1.conf"
# bare `dev tun` (runtime-assigned) -> must be skipped
{ echo client; echo "dev tun"; echo "remote 5.6.7.8 1194"; } > "$CFG/bare.conf"

# stub ip: only answers the tun0 PtP peer
cat >"$TMP/bin/ip" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" route get 198.51.100.17 "*) echo "198.51.100.17 dev as0t0 src 10.30.13.1 uid 0";;
  *" dev tun0 "*)               echo "5: tun0    inet 10.8.0.6 peer 10.8.0.1/32 scope global tun0";;
esac
EOF
chmod +x "$TMP/bin/ip"
run(){ PATH="$TMP/bin:$PATH" OPENVPN_CONF_DIRS="$CFG" bash "$DISC" "$@"; }

# Case 1: no override
out=$(run "")
echo "$out" | grep -qF '"{#VPN_IFACE}":"tun0","{#VPN_TARGET}":"10.8.0.1","{#VPN_TECH}":"openvpn"'   || fail "client tun0 PtP peer (got: $out)"
echo "$out" | grep -qF '"{#VPN_IFACE}":"ovpns1","{#VPN_TARGET}":"10.16.16.6","{#VPN_TECH}":"openvpn"' || fail "server client1 (got: $out)"
echo "$out" | grep -qF '"{#VPN_IFACE}":"ovpns1","{#VPN_TARGET}":"10.16.16.7","{#VPN_TECH}":"openvpn"' || fail "server client2 (got: $out)"
echo "$out" | grep -qF '"{#VPN_IFACE}":"tun"' && fail "bare 'dev tun' must be skipped (got: $out)"
python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" || fail "invalid JSON ($out)"

# Case 2: override for ovpns1 replaces its status-derived clients
out=$(run "ovpns1=10.16.16.99")
echo "$out" | grep -qF '"{#VPN_IFACE}":"ovpns1","{#VPN_TARGET}":"10.16.16.99"' || fail "ovpns1 override (got: $out)"
echo "$out" | grep -qF '10.16.16.6' && fail "override must replace status clients (got: $out)"

# Case 3: OpenVPN Access Server — sacli VPNStatus JSON -> per-client row, iface from route get
cat > "$TMP/as.json" <<'JSON'
{"openvpn_0":{"routing_table":[["198.51.100.17","buh4","203.0.113.31:60586","Thu","1779385341"]],
 "routing_table_header":{"Virtual Address":0,"Last Ref (time_t)":4}},
 "openvpn_1":{"routing_table":[],"routing_table_header":{"Virtual Address":0}}}
JSON
out=$(PATH="$TMP/bin:$PATH" OPENVPN_AS_VPNSTATUS="$TMP/as.json" bash "$DISC" "")
echo "$out" | grep -qF '"{#VPN_IFACE}":"as0t0","{#VPN_TARGET}":"198.51.100.17","{#VPN_TECH}":"openvpn"' || fail "AS client row (got: $out)"
python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" || fail "AS invalid JSON ($out)"

# Case 4: a malformed vaddr (would break the JSON string) is dropped; the good row + valid JSON survive.
cat > "$TMP/asbad.json" <<'JSON'
{"openvpn_0":{"routing_table":[["198.51.100.17","ok","x:1","Thu","1"],["1.2.3.4\" evil","bad","x:2","Thu","2"]],
 "routing_table_header":{"Virtual Address":0,"Last Ref (time_t)":4}}}
JSON
out=$(PATH="$TMP/bin:$PATH" OPENVPN_AS_VPNSTATUS="$TMP/asbad.json" bash "$DISC" "")
python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" || fail "malformed vaddr broke JSON ($out)"
echo "$out" | grep -qF 'evil' && fail "malformed vaddr must be dropped (got: $out)"
echo "$out" | grep -qF '"{#VPN_TARGET}":"198.51.100.17"' || fail "good row should survive a bad sibling (got: $out)"

echo "PASS: openvpn discovery — community + Access Server + malformed-vaddr drop + valid JSON"
