#!/usr/bin/env bash
# Liveness gate for OpenVPN (community AND OpenVPN Access Server). Usage: gate_openvpn.sh <iface> <target>
# Prints a unix epoch when the target is live, else nothing/0. vpn_pmtu.sh owns the staleness verdict
# (epoch 0 / stale => -2 offline). KEY-FREE: status/socket/sacli-status only, never the key/cert.
#
# Liveness model per source:
#   - status-version 3 file (TAB) and OpenVPN Access Server (`sacli VPNStatus` JSON): the ROUTING_TABLE
#     is a *live* view (entries vanish on disconnect), so it's BINARY — target present => emit `now`
#     (live, like ZeroTier); absent => `0` (=> -2). We do NOT age the row's "Last Ref", because that only
#     advances on traffic and would falsely offline a connected-but-idle client when keepalive > FRESH.
#   - status-version 1 file (comma): a client-side file that PERSISTS after the client dies, so its
#     whole-tunnel "Updated,<date>" timestamp IS the liveness signal — emit it and let vpn_pmtu age it.
#   - management socket: `status 3` -> same TAB schema as v3.
# Test hooks: OPENVPN_STATUS_FILE=<path> | OPENVPN_STATUS_CMD=<cmd> inject a status source directly.
set -u
ifc=${1:?usage: gate_openvpn.sh <iface> <target>}; tgt=${2:-}

status_text() {   # emit the raw status text (TAB/comma/JSON) for this iface's instance, or nothing
  [ -n "${OPENVPN_STATUS_FILE:-}" ] && { cat "$OPENVPN_STATUS_FILE" 2>/dev/null; return; }
  [ -n "${OPENVPN_STATUS_CMD:-}" ]  && { eval "$OPENVPN_STATUS_CMD" 2>/dev/null; return; }
  local dir cfg sfile sock
  for dir in /etc/openvpn /etc/openvpn/server /etc/openvpn/client /var/etc/openvpn /var/etc/openvpn/*; do
    [ -d "$dir" ] || continue
    for cfg in "$dir"/*.conf "$dir"/*.ovpn; do
      [ -f "$cfg" ] || continue
      grep -qiE "^[[:space:]]*dev([[:space:]]+|-node[[:space:]]+/dev/)$ifc([[:space:]]|\$)" "$cfg" 2>/dev/null || continue
      sfile=$(awk 'tolower($1)=="status"{print $2; exit}' "$cfg" 2>/dev/null)
      if [ -n "$sfile" ]; then { cat "$sfile" 2>/dev/null || sudo -n cat "$sfile" 2>/dev/null; }; return; fi
      sock=$(awk 'tolower($1)=="management"{print $2; exit}' "$cfg" 2>/dev/null)
      if [ -n "$sock" ] && [ -S "$sock" ]; then
        printf 'status 3\nquit\n' | { socat - "UNIX-CONNECT:$sock" 2>/dev/null || sudo -n socat - "UNIX-CONNECT:$sock" 2>/dev/null; }; return
      fi
    done
  done
  # OpenVPN Access Server: no flat configs/status files — query sacli (its VPNStatus is JSON).
  local sa=/usr/local/openvpn_as/scripts/sacli
  [ -x "$sa" ] || sa=$(command -v sacli 2>/dev/null) || return
  [ -n "$sa" ] && { "$sa" VPNStatus 2>/dev/null || sudo -n "$sa" VPNStatus 2>/dev/null; }
}

data=$(status_text)
[ -n "$data" ] || exit 0                          # unreadable/empty -> fail-safe (probe ungated)
printf '%s' "$data" | python3 -c '
import sys, re, json, subprocess, time
tgt = sys.argv[1]; data = sys.stdin.read()
if not data.strip():
    sys.exit(0)
if data.lstrip()[:1] == "{":                      # OpenVPN Access Server: sacli VPNStatus JSON (BINARY)
    try: d = json.loads(data)
    except Exception: sys.exit(0)
    # Scan every daemon (the iface arg is not in the JSON); AS vaddr pools are unique per server.
    for info in d.values():
        if not isinstance(info, dict): continue
        va = (info.get("routing_table_header") or {}).get("Virtual Address", 0)
        for row in (info.get("routing_table") or []):
            try:
                if row[va] == tgt: print(int(time.time())); sys.exit(0)   # connected => live
            except (IndexError, TypeError): pass
    print(0); sys.exit(0)                          # not connected => -2
if "ROUTING_TABLE" in data:                       # community status-version 3, TAB (BINARY)
    for ln in data.splitlines():
        f = ln.split("\t")
        if len(f) >= 2 and f[0] == "ROUTING_TABLE" and f[1] == tgt:
            print(int(time.time())); sys.exit(0)   # present in the live routing table => live
    print(0); sys.exit(0)                          # not connected => -2
m = re.search(r"^Updated,(.+)$", data, re.M)      # community status-version 1, comma (AGED)
if m:
    try: print(int(subprocess.check_output(["date", "-d", m.group(1).strip(), "+%s"], stderr=subprocess.DEVNULL).strip()))
    except Exception: pass
' "$tgt"
