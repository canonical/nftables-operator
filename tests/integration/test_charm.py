# Copyright 2026 Canonical Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""End-to-end tests: deploy the charm on a real machine and check nftables.

Deployment is expensive, so the whole lifecycle is exercised as one ordered
scenario inside a single temporary model rather than split across fixtures.
"""

import glob
import os
import pathlib

import jubilant
import pytest

APP = "nftables-operator"
PRINCIPAL = "ubuntu"
PRINCIPAL_UNIT = "ubuntu/0"
BASE = "ubuntu@24.04"

# Each ruleset starts with 'flush ruleset' (so re-application is idempotent) and
# names its table distinctively so we can recognise it in 'nft list ruleset'.
# 'policy accept' keeps the machine reachable so Juju and SSH keep working.
MARKER_ONE = "charm_marker_one"
MARKER_TWO = "charm_marker_two"


def _ruleset(table: str) -> str:
    return (
        "flush ruleset\n"
        f"table inet {table} {{\n"
        "  chain input {\n"
        "    type filter hook input priority 0; policy accept;\n"
        "  }\n"
        "}\n"
    )


GOOD = _ruleset(MARKER_ONE)
GOOD_UPDATED = _ruleset(MARKER_TWO)
INVALID = "this is definitely not a valid nftables ruleset"


def _charm_path() -> str:
    """Locate the packed charm via CHARM_PATH env var or a glob in the repo root."""
    env = os.environ.get("CHARM_PATH")
    if env:
        return env
    repo_root = pathlib.Path(__file__).parents[2]
    matches = sorted(glob.glob(str(repo_root / f"{APP}_*.charm")))
    if not matches:
        pytest.skip(f"no packed charm in {repo_root}; set CHARM_PATH or run 'charmcraft pack'")
    return matches[0]


def _sub_status(juju: jubilant.Juju):
    """Return the subordinate application's workload StatusInfo."""
    return juju.status().apps[APP].app_status


def _sub_blocked(status: jubilant.Status) -> bool:
    return status.apps[APP].app_status.current == "blocked"


def _ready_unconfigured(status: jubilant.Status) -> bool:
    """Principal is active and the unconfigured subordinate has gone blocked."""
    return status.apps[PRINCIPAL].is_active and status.apps[APP].app_status.current == "blocked"


def _nft_ruleset(juju: jubilant.Juju) -> str:
    """Return the live nftables ruleset on the principal machine."""
    return juju.exec("nft", "list", "ruleset", unit=PRINCIPAL_UNIT).stdout


def _read_file(juju: jubilant.Juju, path: str) -> str:
    return juju.exec("cat", path, unit=PRINCIPAL_UNIT).stdout


def _sub_unit(juju: jubilant.Juju) -> str:
    """Return the subordinate unit name (colocated on the principal unit)."""
    subordinates = juju.status().apps[PRINCIPAL].units[PRINCIPAL_UNIT].subordinates
    return next(iter(subordinates))


# Black-box (network-level) test topology: one server machine running the charm
# plus a plain HTTP server, and two client machines. The ruleset lets only the
# first client reach the server port; everything else to that port is dropped.
SERVER_PORT = 8000


def _server_ruleset(allowed_ip: str) -> str:
    """A ruleset that accepts port SERVER_PORT only from allowed_ip.

    'policy accept' plus an explicit allow-then-drop for the server port keeps
    SSH and Juju working while firewalling just the one service.
    """
    return (
        "flush ruleset\n"
        "table inet filter {\n"
        "  chain input {\n"
        "    type filter hook input priority 0; policy accept;\n"
        "    ct state established,related accept\n"
        "    iif lo accept\n"
        "    tcp dport 22 accept\n"
        f"    tcp dport {SERVER_PORT} ip saddr {allowed_ip} accept\n"
        f"    tcp dport {SERVER_PORT} drop\n"
        "  }\n"
        "}\n"
    )


def _unit_ip(juju: jubilant.Juju, unit: str) -> str:
    app = unit.split("/")[0]
    info = juju.status().apps[app].units[unit]
    return info.public_address or info.address


def _connect_cmd(ip: str, port: int, timeout: int) -> str:
    """Shell command that exits 0 iff a TCP connection to ip:port succeeds."""
    py = f"import socket; socket.create_connection(('{ip}', {port}), timeout={timeout})"
    return f'python3 -c "{py}"'


def _can_connect(juju: jubilant.Juju, from_unit: str, server_ip: str) -> bool:
    """Whether from_unit can open a TCP connection to the server port.

    A dropped SYN makes the probe time out and exit non-zero, which jubilant
    surfaces as TaskError; that is the 'blocked' outcome.
    """
    try:
        juju.exec(_connect_cmd(server_ip, SERVER_PORT, 8), unit=from_unit)
        return True
    except jubilant.TaskError:
        return False


def test_nftables_operator_end_to_end():
    charm = _charm_path()
    with jubilant.temp_model() as juju:
        juju.deploy(PRINCIPAL, base=BASE)
        juju.deploy(charm, base=BASE, num_units=0)
        juju.integrate(APP, PRINCIPAL)

        # 1. Unconfigured: the subordinate blocks and applies nothing.
        juju.wait(_ready_unconfigured, error=jubilant.any_error, timeout=900)
        assert "no rules configured" in _sub_status(juju).message

        # 2. Valid rules take effect on the live firewall.
        juju.config(APP, {"rules": GOOD})
        juju.wait(jubilant.all_active, error=jubilant.any_error, timeout=600)
        assert MARKER_ONE in _nft_ruleset(juju)

        # 3. Persistence signals: the charm owns the config file and enables the
        #    boot-time service (so the ruleset survives a reboot).
        assert _read_file(juju, "/etc/nftables.conf") == GOOD
        assert (
            "enabled"
            in juju.exec("systemctl", "is-enabled", "nftables", unit=PRINCIPAL_UNIT).stdout
        )

        # 4. Invalid rules block the unit and leave the running firewall intact.
        juju.config(APP, {"rules": INVALID})
        juju.wait(_sub_blocked, error=jubilant.any_error, timeout=600)
        assert "invalid rules" in _sub_status(juju).message
        assert MARKER_ONE in _nft_ruleset(juju)

        # 5. Updating to a different ruleset replaces the old one (flush semantics).
        juju.config(APP, {"rules": GOOD_UPDATED})
        juju.wait(jubilant.all_active, error=jubilant.any_error, timeout=600)
        ruleset = _nft_ruleset(juju)
        assert MARKER_TWO in ruleset
        assert MARKER_ONE not in ruleset

        # 6. Re-applying the same rules is idempotent (no table-exists error).
        juju.config(APP, {"rules": GOOD_UPDATED})
        juju.wait(jubilant.all_active, error=jubilant.any_error, timeout=600)
        assert MARKER_TWO in _nft_ruleset(juju)

        # 7. The reapply action heals out-of-band drift that the periodic
        #    reconcile deliberately ignores (the config file still matches).
        juju.exec("nft", "flush", "ruleset", unit=PRINCIPAL_UNIT)
        assert MARKER_TWO not in _nft_ruleset(juju)
        juju.run(_sub_unit(juju), "reapply")
        assert MARKER_TWO in _nft_ruleset(juju)

        # 8. Clearing the config blocks the unit but leaves the ruleset as-is.
        juju.config(APP, {"rules": ""})
        juju.wait(_sub_blocked, error=jubilant.any_error, timeout=600)
        assert "no rules configured" in _sub_status(juju).message
        assert MARKER_TWO in _nft_ruleset(juju)


def test_firewall_allows_one_source_and_blocks_another():
    """Black box: only the allowed client can reach a server behind the ruleset."""
    charm = _charm_path()
    with jubilant.temp_model() as juju:
        juju.deploy(PRINCIPAL, "server", base=BASE)
        juju.deploy(PRINCIPAL, "client", base=BASE, num_units=2)
        juju.deploy(charm, base=BASE, num_units=0)
        juju.integrate(APP, "server")

        # Wait for the three machines. The subordinate stays blocked (no rules
        # yet), so wait on the principals rather than on all-active.
        juju.wait(
            lambda s: s.apps["server"].is_active and s.apps["client"].is_active,
            error=jubilant.any_error,
            timeout=1200,
        )

        server_ip = _unit_ip(juju, "server/0")
        allowed_ip = _unit_ip(juju, "client/0")

        # Start a plain HTTP server on the server machine (a transient systemd
        # unit so it outlives the exec) and wait until the port is listening.
        # This happens before any rules are applied, so the firewall is still open.
        juju.exec(
            f"systemd-run --unit=blackbox-httpd python3 -m http.server {SERVER_PORT}",
            unit="server/0",
        )
        probe = _connect_cmd("127.0.0.1", SERVER_PORT, 2)
        juju.exec(
            f"for _ in $(seq 1 15); do {probe} && break; sleep 1; done",
            unit="server/0",
        )

        # Both clients can reach the server before the firewall is configured.
        assert _can_connect(juju, "client/0", server_ip)
        assert _can_connect(juju, "client/1", server_ip)

        # Allow only client/0 to the server port; client/1 (and anyone else) is dropped.
        juju.config(APP, {"rules": _server_ruleset(allowed_ip)})
        juju.wait(jubilant.all_active, error=jubilant.any_error, timeout=600)

        assert _can_connect(juju, "client/0", server_ip)  # allowed by nft
        assert not _can_connect(juju, "client/1", server_ip)  # blocked by nft
