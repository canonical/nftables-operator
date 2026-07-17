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

Deployment is expensive, so each test is one ordered scenario inside a single
temporary model. The deploy helpers live in environment.py, which also provides a
CLI to stand the black-box environment up by hand.
"""

import jubilant

from .environment import (
    APP,
    BASE,
    CHANNEL,
    PRINCIPAL,
    PRINCIPAL_UNIT,
    can_connect,
    charm_path,
    deploy_operator,
    stand_up,
)

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


def _require_local_charm() -> None:
    """Fail (do not skip) when deploying a local charm that has not been packed."""
    if CHANNEL:
        return  # deploying the published charm; no local build needed
    charm_path()  # raises CharmNotFoundError, failing the test, if not packed


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


def test_nftables_operator_end_to_end():
    _require_local_charm()
    with jubilant.temp_model() as juju:
        juju.deploy(PRINCIPAL, base=BASE)
        deploy_operator(juju, CHANNEL)
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
    _require_local_charm()
    with jubilant.temp_model() as juju:
        server_ip = stand_up(juju, CHANNEL)
        assert can_connect(juju, "client/0", server_ip)  # allowed by nft
        assert not can_connect(juju, "client/1", server_ip)  # blocked by nft
