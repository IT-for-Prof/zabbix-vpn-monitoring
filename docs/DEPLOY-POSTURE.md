# Deploying the MTU posture check to a host

The **MTU posture** check (part of the `VPN Tunnel MTU by Zabbix agent` template) is config-plane only —
per WireGuard tunnel it reports `mtu` / `fwd` / `clamp`; the template pages **Warning** when
`mtu > {$VPN.MTU.MAX}` (default 1420) and notes **Information** when a tunnel forwards transit without an
MSS clamp. No probing, so it never false-fires on a lost connection or a link flap.

Collector: `collectors/posture/vpn_posture.sh` — POSIX sh, runs under Linux dash/bash and FreeBSD/pfSense
`/bin/sh`. WireGuard/AmneziaWG only (OpenVPN/ZeroTier have a different MTU model and are excluded).

## Find hosts that still need it

A WireGuard host needs onboarding if it isn't linked to the template yet. List candidates from Zabbix
(hosts with a `net.if[...wg...]` interface but not linked), or just enumerate your VPN routers.

## Linux host

1. **Deploy the collector** — idempotent installer (full set) or surgical (posture only):
   ```sh
   # full (also (re)installs the active probe — idempotent):
   tar c collectors lib installers tests | ssh <host> 'mkdir -p /tmp/zvm && tar x -C /tmp/zvm && cd /tmp/zvm && bash installers/install.sh'

   # OR surgical (posture only):
   scp collectors/posture/vpn_posture.sh <host>:/etc/zabbix/scripts/vpn_posture.sh
   scp collectors/posture/posture.conf  <host>:/etc/zabbix/zabbix_agent2.d/posture.conf
   ssh <host> 'chmod 0755 /etc/zabbix/scripts/vpn_posture.sh
     P=/etc/sudoers.d/zabbix-posture; : > $P.tmp
     I=$(command -v iptables-save) && printf "zabbix ALL=(root) NOPASSWD: %s \"\"\n" "$I" >> $P.tmp
     N=$(command -v nft)           && printf "zabbix ALL=(root) NOPASSWD: %s list ruleset\n" "$N" >> $P.tmp
     chmod 0440 $P.tmp
     visudo -cf $P.tmp && mv $P.tmp $P && systemctl reload zabbix-agent2 || rm -f $P.tmp'
   ```
   Two details worth keeping if you adapt this: stage to `$P.tmp` and only `mv` it into place
   **after** `visudo -cf` passes — writing `/etc/sudoers.d/` directly means a typo locks the host
   out of sudo. And the trailing `""` pins the grant to zero arguments; without it sudoers allows
   any, and `iptables-save -M <path>` execs that path as root (`-f <path>` writes as root), which
   turns a "read-only" grant into a root escalation from the `zabbix` account.

   To revoke: `rm -f /etc/sudoers.d/zabbix-posture /etc/zabbix/scripts/vpn_posture.sh
   /etc/zabbix/zabbix_agent2.d/posture.conf`, or just run `installers/uninstall.sh`.
2. **Verify on the host** (data comes through the real agent):
   ```sh
   ssh <host> 'zabbix_agent2 -t vpn.posture.discovery; zabbix_agent2 -t "vpn.posture.mtu[<iface>]"'
   ```
3. **Link the host to the template** (server-side, append-only).

## FreeBSD / pfSense host

The agent runs **as root** (no sudo needed) and `install.sh` does **not** support FreeBSD. Per host:

1. `scp collectors/posture/vpn_posture.sh <host>:/root/scripts/vpn_posture.sh` (then `chmod 0755`).
2. **pfSense GUI → Services → Zabbix Agent (LTS) → "User Parameters"** — append (these survive GUI saves;
   editing `zabbix_agentd.conf` directly does **not** — a GUI save regenerates it):
   ```
   UserParameter=vpn.posture.discovery,/bin/sh /root/scripts/vpn_posture.sh discover
   UserParameter=vpn.posture.mtu[*],/bin/sh /root/scripts/vpn_posture.sh mtu "$1"
   UserParameter=vpn.posture.fwd[*],/bin/sh /root/scripts/vpn_posture.sh fwd "$1"
   UserParameter=vpn.posture.clamp[*],/bin/sh /root/scripts/vpn_posture.sh clamp "$1"
   UserParameter=wg.count,( wg show interfaces 2>/dev/null; awg show interfaces 2>/dev/null ) | wc -w
   ```
   Save (regenerates the conf). `wg.count` is required — it backs the `nodata(wg.count,30m)` watchdog the
   posture triggers depend on.
3. **Link to the template**, then **disable the probe family it can't run** (FreeBSD; otherwise they sit
   UNSUPPORTED): set host-level `status=disabled` on item `wg.probe.ok` and on the LLD rules
   `wg.discovery`, `openvpn.discovery`, `zerotier.discovery`. (The clean alternative is a posture-only
   template that omits the probe items for FreeBSD/posture-only hosts.)

## Macros

- `{$VPN.MTU.MAX}` — safe MTU ceiling (default **1420** for WireGuard over a ~1500 internet underlay).
  Override per host/context where a tunnel must be lower. Sub-ceiling cross-host asymmetry (e.g. 1400
  where 1340 is needed) is out of scope — it needs a cross-host (pubkey-join) comparison, not shipped here.

- `{$VPN.HYST.WINDOW}` — hysteresis window (default **25m**). A trigger fires only if *every* sample in
  this window agrees, so one bad read never pages. Deliberately time-based, not count-based (`#N`): a host
  whose agent writes the same value twice per poll — proxy-group / dual-`ServerActive` setups do — makes
  `#2` span a single poll and silently disables the hysteresis. **If you raise `{$VPN.PROBE.INTERVAL}` on a
  host, raise this on the same host to >=2x the new value**, or the window holds one sample again and the
  hysteresis is gone. Nothing checks that for you — `tests/test-template-triggers.sh` validates template
  defaults, never per-host overrides.

## What auto-discovers, what does not

- **A new tunnel on an already-onboarded host** → **automatic** (the `vpn.posture.discovery` LLD finds it).
- **A new host** → **not** automatic: deploy the collector + link the template. (Can be wired via a Zabbix
  autoregistration action — but that links the *whole* template, including the FreeBSD-incompatible probe.)
- **Tunnel pairing between two hosts** → **not** discovered. The check is single-ended.

## Verify after rollout

```
item.get   search vpn.posture.mtu     -> one item per discovered tunnel, lastvalue = its MTU
problem.get                           -> "MTU too high" only where mtu > {$VPN.MTU.MAX}
```
Connection-down safety holds by construction (config-plane): a lost handshake / link flap leaves the
values unchanged; a removed interface drops the LLD item (nodata), never read as MTU 0.
