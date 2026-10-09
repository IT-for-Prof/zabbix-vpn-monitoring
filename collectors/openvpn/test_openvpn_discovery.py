import json
import os
import stat
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "openvpn_discovery.sh"
TEMPLATE = ROOT.parent.parent / "templates" / "vpn-tunnel-mtu.yaml"


def run_discovery(*, status=None, conf_dir=None, route_iface="as0t3"):
    env = os.environ.copy()
    if status is not None:
        status_file = Path(status)
        env["OPENVPN_AS_VPNSTATUS"] = str(status_file)
    else:
        env.pop("OPENVPN_AS_VPNSTATUS", None)
    if conf_dir is not None:
        env["OPENVPN_CONF_DIRS"] = str(conf_dir)

    bin_dir = Path(env.get("TMPDIR", "/tmp")) / f"openvpn-discovery-test-{os.getpid()}"
    bin_dir.mkdir(exist_ok=True)
    ip = bin_dir / "ip"
    ip.write_text(
        "#!/bin/sh\n"
        f"case \"$*\" in *'route get'*) echo 'target dev {route_iface} src 10.0.0.1';; esac\n",
        encoding="utf-8",
    )
    ip.chmod(ip.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    return subprocess.run(
        [str(SCRIPT)], env=env, text=True, capture_output=True, check=False
    )


def test_access_server_rows_are_data_only_dynamic_endpoints(tmp_path):
    status = tmp_path / "vpnstatus.json"
    status.write_text(
        json.dumps(
            {
                "daemon": {
                    "routing_table_header": {"Virtual Address": 0},
                    "routing_table": [["10.30.13.98"]],
                }
            }
        ),
        encoding="utf-8",
    )

    result = run_discovery(status=status)

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {
        "data": [
            {
                "{#VPN_IFACE}": "as0t3",
                "{#VPN_TARGET}": "10.30.13.98",
                "{#VPN_TECH}": "openvpn",
                "{#VPN_DYNAMIC}": "1",
            }
        ]
    }


def test_community_rows_are_static_endpoints(tmp_path):
    conf_dir = tmp_path / "conf"
    conf_dir.mkdir()
    status = tmp_path / "status.log"
    status.write_text("ROUTING_TABLE,10.8.0.2,client,10.8.0.1,1\n", encoding="utf-8")
    (conf_dir / "server.conf").write_text(
        f"dev tun0\nstatus {status}\n", encoding="utf-8"
    )

    result = run_discovery(conf_dir=conf_dir, route_iface="tun0")

    assert result.returncode == 0, result.stderr
    row = json.loads(result.stdout)["data"][0]
    assert row["{#VPN_IFACE}"] == "tun0"
    assert row["{#VPN_TARGET}"] == "10.8.0.2"
    assert row["{#VPN_DYNAMIC}"] == "0"


def test_access_server_empty_status_is_valid_but_failures_are_not_empty_rosters(tmp_path):
    status = tmp_path / "vpnstatus.json"
    status.write_text(
        json.dumps(
            {
                "daemon": {
                    "routing_table_header": {"Virtual Address": 0},
                    "routing_table": [],
                }
            }
        ),
        encoding="utf-8",
    )
    result = run_discovery(status=status)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"data": []}

    for broken in ("{bad", '{"error":"temporarily unavailable"}', "{}"):
        status.write_text(broken, encoding="utf-8")
        result = run_discovery(status=status)
        assert result.returncode != 0
        assert result.stdout == ""


def test_template_suppresses_dynamic_openvpn_alerts_but_keeps_static_alerts():
    template = yaml.safe_load(TEMPLATE.read_text(encoding="utf-8"))["zabbix_export"]["templates"][0]
    rule = next(rule for rule in template["discovery_rules"] if rule["key"].startswith("openvpn.discovery"))
    item = rule["item_prototypes"][0]
    macros = {macro["macro"]: macro.get("value") for macro in template["macros"]}

    assert macros["{$VPN.DYNAMIC.PAGING}"] == "1"
    assert macros['{$VPN.DYNAMIC.PAGING:"1"}'] == "0"
    assert {tag["tag"] for tag in item["tags"]} >= {"vpn_dynamic"}
    assert all(
        '{$VPN.DYNAMIC.PAGING:"{#VPN_DYNAMIC}"}=1' in trigger["expression"]
        for trigger in item["trigger_prototypes"]
    )


if __name__ == "__main__":
    for test in (
        test_access_server_rows_are_data_only_dynamic_endpoints,
        test_community_rows_are_static_endpoints,
        test_access_server_empty_status_is_valid_but_failures_are_not_empty_rosters,
    ):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            test(Path(directory))
    print("PASS: OpenVPN discovery dynamic/static and failure contract")
