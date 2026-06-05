#!/usr/bin/env bash
# Unit/fixture tests for vpn_posture.sh pure parsers. No root, no network, CI-able.
# Sources the collector and feeds canned Linux/FreeBSD command output to each parser.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
VPN_POSTURE_LIB=1 . "$DIR/collectors/posture/vpn_posture.sh"

pass=0; fail=0
check() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s : expected[%s] got[%s]\n' "$1" "$2" "$3"; fi
}

echo "== parse_has_routed_prefix =="
check "wg host-only /32 -> 0"      0 "$(printf 'KEY\t192.168.255.12/32\n'      | parse_has_routed_prefix)"
check "wg exit 0.0.0.0/0 -> 1"     1 "$(printf 'KEY\t0.0.0.0/0\n'              | parse_has_routed_prefix)"
check "wg subnet /24 -> 1"         1 "$(printf 'KEY\t10.60.0.0/24,10.99.0.2/32\n' | parse_has_routed_prefix)"
check "route default -> 1"         1 "$(printf 'default via 10.0.0.1 dev wg0\n' | parse_has_routed_prefix)"
check "bare /32 host route -> 0"   0 "$(printf '192.168.255.12 dev wg0\n'      | parse_has_routed_prefix)"
check "v6 host /128 -> 0"          0 "$(printf 'KEY\tfd00::2/128\n'            | parse_has_routed_prefix)"

echo "== parse_clamp_linux =="
IPT_SETMSS='-A FORWARD -o wg0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360'
IPT_CLAMP='-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
NFT_RULE='oifname "wg0" tcp flags syn / syn,rst tcp option maxseg size set rt mtu'
check "iptables set-mss on wg0 -> 1"     1 "$(printf '%s\n' "$IPT_SETMSS" | parse_clamp_linux wg0)"
check "iptables set-mss wg0, ask wg1 ->0" 0 "$(printf '%s\n' "$IPT_SETMSS" | parse_clamp_linux wg1)"
check "iptables generic clamp -> 1"      1 "$(printf '%s\n' "$IPT_CLAMP"  | parse_clamp_linux wg9)"
check "nft maxseg oifname wg0 -> 1"      1 "$(printf '%s\n' "$NFT_RULE"   | parse_clamp_linux wg0)"
check "iface as last token on line -> 1" 1 "$(printf 'tcp option maxseg size set rt mtu oif wg0\n' | parse_clamp_linux wg0)"
check "iface substring not matched (wg00)" 0 "$(printf '%s\n' "$IPT_SETMSS" | parse_clamp_linux wg)"
check "empty ruleset -> 0"               0 "$(printf '' | parse_clamp_linux wg0)"

echo "== parse_clamp_freebsd (FreeBSD pfctl sample) =="
PFCTL='scrub on tun_wg0 inet all no-df fragment reassemble
scrub on tun_wg2 inet all no-df max-mss 1380 fragment reassemble
scrub on tun_wg3 inet all no-df max-mss 1380 fragment reassemble
scrub on tun_wg4 inet all no-df fragment reassemble'
check "tun_wg3 has max-mss -> 1"  1 "$(printf '%s\n' "$PFCTL" | parse_clamp_freebsd tun_wg3)"
check "tun_wg0 no max-mss  -> 0"  0 "$(printf '%s\n' "$PFCTL" | parse_clamp_freebsd tun_wg0)"
check "tun_wg4 no max-mss  -> 0"  0 "$(printf '%s\n' "$PFCTL" | parse_clamp_freebsd tun_wg4)"
check "tun_wg2 substring not matching tun_wg2x" 1 "$(printf '%s\n' "$PFCTL" | parse_clamp_freebsd tun_wg2)"
check "direction-qualified 'scrub in on' -> 1" 1 "$(printf 'scrub in on tun_wg7 all max-mss 1400 fragment reassemble\n' | parse_clamp_freebsd tun_wg7)"
check "direction 'scrub out on' -> 1"          1 "$(printf 'scrub out on tun_wg8 inet all max-mss 1360\n'          | parse_clamp_freebsd tun_wg8)"

echo "== parse_mtu_freebsd =="
IFC='tun_wg3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> metric 0 mtu 1420
	options=80000<LINKSTATE>
	inet 192.168.255.1 --> 192.168.255.12 netmask 0xffffffff'
check "ifconfig mtu 1420 -> 1420" 1420 "$(printf '%s\n' "$IFC" | parse_mtu_freebsd)"

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
