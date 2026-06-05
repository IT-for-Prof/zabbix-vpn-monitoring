#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes intentional: stub scripts emitted verbatim
# Fixture test for collectors/zerotier/zerotier_discovery.sh. Stubs zerotier-cli + ip on PATH.
# No ZeroTier/kernel needed.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
DISC="$REPO/collectors/zerotier/zerotier_discovery.sh"
fail(){ echo "FAIL: $*"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# stub: two joined networks -> ztA (has default-route via) and ztB (only a host-route via)
cat >"$TMP/zerotier-cli" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-j" ] && [ "${2:-}" = "listnetworks" ]; then
cat <<'JSON'
[{"portDeviceName":"ztA","status":"OK","mtu":2800},
 {"portDeviceName":"ztB","status":"OK","mtu":2800},
 {"portDeviceName":"","status":"REQUESTING_CONFIGURATION"}]
JSON
fi
EOF
chmod +x "$TMP/zerotier-cli"

# stub: ip routes per zt iface
cat >"$TMP/ip" <<'EOF'
#!/usr/bin/env bash
args=("$@"); dev=""; i=0
while [ $i -lt ${#args[@]} ]; do [ "${args[$i]}" = "dev" ] && { i=$((i+1)); dev="${args[$i]}"; }; i=$((i+1)); done
case "$dev" in
  ztA) echo "default via 192.168.192.5 proto static metric 5000"
       echo "192.168.0.3 via 192.168.192.74 proto static metric 5000" ;;
  ztB) echo "192.168.50.0/24 via 192.168.50.9 proto static metric 5000" ;;
esac
EOF
chmod +x "$TMP/ip"

export PATH="$TMP:$PATH"

# Case 1: no overrides — ztA uses default-route via, ztB uses its only via
out=$(bash "$DISC" "")
echo "$out" | grep -qF '"{#VPN_IFACE}":"ztA","{#VPN_TARGET}":"192.168.192.5","{#VPN_TECH}":"zerotier"' \
  || fail "case1: ztA should pick default-route via 192.168.192.5 (got: $out)"
echo "$out" | grep -qF '"{#VPN_IFACE}":"ztB","{#VPN_TARGET}":"192.168.50.9","{#VPN_TECH}":"zerotier"' \
  || fail "case1: ztB should pick its only via 192.168.50.9 (got: $out)"
python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" || fail "case1: invalid JSON ($out)"

# Case 2: override for ztA wins over the route-derived target
out=$(bash "$DISC" "ztA=10.9.9.9")
echo "$out" | grep -qF '"{#VPN_IFACE}":"ztA","{#VPN_TARGET}":"10.9.9.9","{#VPN_TECH}":"zerotier"' \
  || fail "case2: ztA override must win (got: $out)"

# Case 3: malformed override -> rejected, falls back to route; JSON stays valid
out=$(bash "$DISC" 'ztA=1.2.3.4"')
echo "$out" | grep -qF '"{#VPN_IFACE}":"ztA","{#VPN_TARGET}":"192.168.192.5"' \
  || fail "case3: malformed override must be rejected -> route fallback (got: $out)"
python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" || fail "case3: invalid JSON ($out)"

echo "PASS: zerotier discovery — default-route/first-via targets, override wins, junk rejected, valid JSON"
