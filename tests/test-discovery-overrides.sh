#!/usr/bin/env bash
# Unit test for wg_discovery.sh override logic. No root or real WireGuard needed.
# Stubs wg and ip on PATH to simulate two interfaces:
#   wgA — bare IPv4 host route (172.20.255.1), target from routes
#   wgB — subnet-only route (192.168.252.0/24), no host route; override eligible
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DISCOVERY="$REPO_ROOT/collectors/wireguard/wg_discovery.sh"

fail() { echo "FAIL: $*"; exit 1; }

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Stub: wg show interfaces -> wgA wgB
cat >"$TMPDIR/wg" <<'EOF'
#!/usr/bin/env bash
# stub: only handles "show interfaces"
if [ "${1:-}" = "show" ] && [ "${2:-}" = "interfaces" ]; then
  echo "wgA wgB"
fi
EOF
chmod +x "$TMPDIR/wg"

# Stub: awg show interfaces -> awg0  (AmneziaWG mirrors wg's CLI; discovery unions both)
cat >"$TMPDIR/awg" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "show" ] && [ "${2:-}" = "interfaces" ]; then
  echo "awg0"
fi
EOF
chmod +x "$TMPDIR/awg"

# Stub: ip — handles the two route queries and silently ignores link-list fallback
cat >"$TMPDIR/ip" <<'EOF'
#!/usr/bin/env bash
# Parse args to find: ip -o -4 route show dev <iface>
# Ignore: ip -o link show type wireguard
args=("$@")
dev=""
mode=""
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    route) mode=route ;;
    link)  mode=link  ;;
    dev)   i=$((i+1)); dev="${args[$i]}" ;;
  esac
  i=$((i+1))
done
if [ "$mode" = "route" ]; then
  case "$dev" in
    wgA)  echo "172.20.255.1 scope link" ;;
    wgB)  echo "192.168.252.0/24 proto kernel scope link src 192.168.252.2" ;;
    awg0) echo "10.77.0.1 scope link" ;;
  esac
fi
# link-list: print nothing (wg stub is used first)
EOF
chmod +x "$TMPDIR/ip"

export PATH="$TMPDIR:$PATH"

# ── Case 1: override for wgB ──────────────────────────────────────────────────
out=$(bash "$DISCOVERY" "wgB=192.0.2.3")
echo "$out" | grep -qF '"{#WG_IFACE}":"wgA","{#WG_TARGET}":"172.20.255.1"' \
  || fail "case1: wgA route target missing (got: $out)"
echo "$out" | grep -qF '"{#WG_IFACE}":"wgB","{#WG_TARGET}":"192.0.2.3"' \
  || fail "case1: wgB override target missing (got: $out)"

# ── Case 2: no overrides — wgB emits empty target ────────────────────────────
out=$(bash "$DISCOVERY" "")
echo "$out" | grep -qF '"{#WG_IFACE}":"wgA","{#WG_TARGET}":"172.20.255.1"' \
  || fail "case2: wgA route target missing (got: $out)"
echo "$out" | grep -qF '"{#WG_IFACE}":"wgB","{#WG_TARGET}":""' \
  || fail "case2: wgB should emit empty target (got: $out)"

# ── Case 3: override for unrelated iface wgZ — wgB still emits empty ─────────
out=$(bash "$DISCOVERY" "wgZ=10.0.0.9")
echo "$out" | grep -qF '"{#WG_IFACE}":"wgA","{#WG_TARGET}":"172.20.255.1"' \
  || fail "case3: wgA route target missing (got: $out)"
echo "$out" | grep -qF '"{#WG_IFACE}":"wgB","{#WG_TARGET}":""' \
  || fail "case3: wgZ override must not leak to wgB (got: $out)"

# ── Case 4: malformed override value (junk) — rejected, wgB emits empty, JSON valid ──
out=$(bash "$DISCOVERY" 'wgB=1.2.3.4"')
echo "$out" | grep -qF '"{#WG_IFACE}":"wgB","{#WG_TARGET}":""' \
  || fail "case4: malformed override must be rejected -> empty target (got: $out)"
python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" \
  || fail "case4: discovery output must stay valid JSON (got: $out)"

# ── Case 5: AmneziaWG interface is discovered via the wg/awg union ───────────
out=$(bash "$DISCOVERY" "")
echo "$out" | grep -qF '"{#WG_IFACE}":"awg0","{#WG_TARGET}":"10.77.0.1"' \
  || fail "case5: awg0 (AmneziaWG) must be discovered with its route target (got: $out)"

echo "PASS: discovery overrides + awg union"
