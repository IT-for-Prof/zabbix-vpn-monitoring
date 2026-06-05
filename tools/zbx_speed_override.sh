#!/usr/bin/env bash
# Re-applies the "No link speed on virtual interfaces" LLD override to the stock
# Linux templates' net.if.discovery rule. Idempotent: re-run after any Zabbix
# vendor-template re-import (which wipes overrides and regenerates rule IDs).
#
# Why: the stock speed item prototype (vfs.file.contents[/sys/class/net/{#IFNAME}/speed])
# is unsupported on virtual ifaces (wg/zt/tun/tap/vmbr/fw*), spamming agent logs every
# poll. This override sets the Speed prototype to "do not discover" for those ifaces
# only, keeping their traffic/error items (reused by the VPN-MTU template).
#
# Runs LOCALLY against the Zabbix API (not over SSH); changes server-side config.
# Reads URL + token + verify_ssl from [zabbix.production] in the MCP config; no secrets in repo.
# Needs: bash, curl, python3 >= 3.11 (tomllib).
set -euo pipefail

CFG="${ZBX_CFG:-/opt/zabbix-mcp/config.toml}"
TEMPLATES=("Linux by Zabbix agent" "Linux by Zabbix agent active")
# Left-anchored NAME-prefix match against {#IFNAME}. Physical NICs (eth*/en*/wlan*)
# never match. Keep this regex JSON-safe: no double-quotes, backslashes, or $.
IFACE_RE='^(wg|zt|tun|tap|veth|docker|br-|vmbr|fwbr|fwpr|fwln)'

die() { echo "ERROR: $*" >&2; exit 1; }

python3 -c 'import tomllib' 2>/dev/null || die "need Python 3.11+ (tomllib) to parse $CFG"
[ -r "$CFG" ] || die "cannot read config $CFG"

read -r URL TOKEN VERIFY < <(python3 - "$CFG" <<'PY'
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))["zabbix"]["production"]
print(c["url"], c["api_token"], str(c.get("verify_ssl", True)).lower())
PY
) || die "failed to parse [zabbix.production] from $CFG"
[ -n "${URL:-}" ] && [ -n "${TOKEN:-}" ] || die "url/api_token missing in [zabbix.production]"
# Honour the config: only skip TLS verification when verify_ssl = false.
INSECURE=(); [ "$VERIFY" = "false" ] && INSECURE=(-k)

# call <method> <params-json> -> prints the JSON-RPC "result"; dies cleanly on any error.
call() {
  local resp
  resp=$(curl -fsS "${INSECURE[@]}" -X POST "$URL/api_jsonrpc.php" \
           -H "Content-Type: application/json" \
           -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1,\"auth\":\"$TOKEN\"}") \
    || die "$1: HTTP request failed (URL/TLS/connectivity/auth)"
  printf '%s' "$resp" | python3 -c '
import sys, json
m = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.exit("%s: invalid JSON response: %s" % (m, e))
if "error" in d:
    sys.exit("%s: API error: %s" % (m, d["error"].get("data") or d["error"]))
json.dump(d["result"], sys.stdout)
' "$1"
}

for tpl in "${TEMPLATES[@]}"; do
  tid=$(call template.get "{\"output\":[\"templateid\"],\"filter\":{\"host\":[\"$tpl\"]}}" \
        | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0]['templateid'] if r else '')")
  [ -n "$tid" ] || die "template '$tpl' not found"
  rid=$(call discoveryrule.get "{\"output\":[\"itemid\"],\"hostids\":\"$tid\",\"filter\":{\"key_\":\"net.if.discovery\"}}" \
        | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0]['itemid'] if r else '')")
  [ -n "$rid" ] || die "'$tpl' has no net.if.discovery rule"

  call discoveryrule.update "{
    \"itemid\":\"$rid\",
    \"overrides\":[{
      \"name\":\"No link speed on virtual interfaces\",
      \"step\":\"1\",\"stop\":\"0\",
      \"filter\":{\"evaltype\":\"0\",\"conditions\":[
        {\"macro\":\"{#IFNAME}\",\"operator\":\"8\",\"value\":\"$IFACE_RE\"}]},
      \"operations\":[{
        \"operationobject\":\"0\",\"operator\":\"8\",\"value\":\": Speed\",
        \"opdiscover\":{\"discover\":\"1\"}}]
    }]
  }" >/dev/null
  echo "OK   $tpl rule $rid"
done

echo "Done. Effect lands on each host's next net.if.discovery run (active LLD, ~1h)."
