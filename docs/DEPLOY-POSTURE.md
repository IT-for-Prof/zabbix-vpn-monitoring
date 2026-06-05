# Deploy prompt — VPN MTU posture check to a new host

Self-contained runbook (works as an agent prompt) for extending the **MTU posture** check
(part of Zabbix template **14009**) to a WireGuard host. The posture check is config-plane only —
per tunnel it reports `mtu` / `fwd` / `clamp`; the template pages **Warning** when `mtu > {$VPN.MTU.MAX}`
(default 1420) and notes **Information** when a tunnel forwards transit without an MSS clamp. No probing,
so it never false-fires on a lost connection or a link flap.

Collector: `collectors/posture/vpn_posture.sh` (POSIX sh — runs under Linux dash/bash and FreeBSD/pfSense `/bin/sh`).

## Which hosts still need it (as of 2026-06-05)

WireGuard hosts present in Zabbix but **not yet on template 14009**:

| host | hostid | OS | agent | action |
|---|---|---|---|---|
| GP-VPS01 | 13926 | Linux | up | deploy + link — **needs SSH access** |
| GP-VPS02 | 13940 | Linux | up | deploy + link — **needs SSH access** |
| GP-VPS03 | 13941 | Linux | **down** | bring agent up, then deploy + link |
| IFP-VPS16 | 13983 | Linux | **down** | bring agent up, then deploy + link (this is the peer of pf03 `tun_wg6`) |
| IFP-VPS09 | 13889 | — | disabled | **SKIP** — host is disabled in Zabbix |

Already covered (do nothing): the 8 Linux WG hosts (ET-VPS01/02, SR-VPS01, IFP-VPS02/11/12/14/15) + both
pfSense firewalls **IFP-VM-PF03** (10548) and **ET-VM-PF01** (13734, ssh alias `et-vm-pf03`).

## Linux host — install / configure

1. **Deploy the collector.** Either the idempotent installer (full set) or surgical (posture only):
   ```sh
   # full (also (re)installs the active probe — fine, idempotent):
   tar c collectors lib installers tests | ssh <host> 'mkdir -p /tmp/zvm && tar x -C /tmp/zvm && cd /tmp/zvm && bash installers/install.sh'

   # OR surgical (posture only):
   scp collectors/posture/vpn_posture.sh <host>:/etc/zabbix/scripts/vpn_posture.sh
   scp collectors/posture/posture.conf  <host>:/etc/zabbix/zabbix_agent2.d/posture.conf
   ssh <host> 'chmod 0755 /etc/zabbix/scripts/vpn_posture.sh
     P=/etc/sudoers.d/zabbix-posture; : > $P
     I=$(command -v iptables-save) && printf "zabbix ALL=(root) NOPASSWD: %s\n" "$I" >> $P
     N=$(command -v nft)           && printf "zabbix ALL=(root) NOPASSWD: %s list ruleset\n" "$N" >> $P
     chmod 0440 $P; visudo -cf $P && systemctl reload zabbix-agent2'
   ```
2. **Verify on the host** (data comes through the real agent):
   ```sh
   ssh <host> 'zabbix_agent2 -t vpn.posture.discovery; zabbix_agent2 -t "vpn.posture.mtu[<iface>]"'
   ```
3. **Link to template 14009** (server-side, append-only): `host.massadd { hosts:[{hostid}], templates:[{templateid:"14009"}] }`.

## FreeBSD / pfSense host — install / configure (different!)

The agent runs **as root** (no sudo needed) and `install.sh` does **not** support FreeBSD. Per host:

1. `scp collectors/posture/vpn_posture.sh <host>:/root/scripts/vpn_posture.sh` (then `chmod 0755`).
2. **pfSense GUI → Services → Zabbix Agent LTS → "User Parameters"** — append (these survive GUI saves;
   editing `zabbix_agentd.conf` directly does **not** — a GUI save regenerates it):
   ```
   UserParameter=vpn.posture.discovery,/bin/sh /root/scripts/vpn_posture.sh discover
   UserParameter=vpn.posture.mtu[*],/bin/sh /root/scripts/vpn_posture.sh mtu "$1"
   UserParameter=vpn.posture.fwd[*],/bin/sh /root/scripts/vpn_posture.sh fwd "$1"
   UserParameter=vpn.posture.clamp[*],/bin/sh /root/scripts/vpn_posture.sh clamp "$1"
   UserParameter=wg.count,( wg show interfaces 2>/dev/null; awg show interfaces 2>/dev/null ) | wc -w
   ```
   Save (regenerates the conf). `wg.count` is required — it backs the `nodata(wg.count,30m)` watchdog the posture triggers depend on.
3. **Link to 14009**, then **disable the probe family it can't run** (FreeBSD; otherwise they sit UNSUPPORTED):
   set host-level `status=1` on item `wg.probe.ok` and on LLD rules `wg.discovery`, `openvpn.discovery`, `zerotier.discovery`.

## Macros

- `{$VPN.MTU.MAX}` — safe MTU ceiling (default **1420**). Override per host/context where a tunnel must be lower
  (e.g. SR-VPS01 → 1340). Sub-ceiling cross-host asymmetry (1400 where 1340 is needed) is out of scope — it needs
  the deferred pubkey-join reconciler.

## What auto-discovers, what does not

- **New tunnel on an already-onboarded host** → **automatic** (the `vpn.posture.discovery` LLD finds it).
- **A new host** → **not** automatic: deploy the collector + link the template. (Could be wired via a Zabbix
  autoregistration action — but that links the *whole* 14009, including the FreeBSD-incompatible probe.)
- **Tunnel pairing between two hosts** ("which tunnel ↔ which host") → **not** discovered. The check is single-ended;
  the cross-host pubkey-join reconciler is deferred.

## Verify in Zabbix after rollout

```
item.get   search vpn.posture.mtu        -> one item per discovered tunnel, lastvalue = its MTU
problem.get                              -> "MTU too high" only where mtu > {$VPN.MTU.MAX}
```
Connection-down safety is guaranteed by construction (config-plane): a lost handshake / link flap leaves the
values unchanged; a removed interface drops the LLD item (nodata), never read as MTU 0.
