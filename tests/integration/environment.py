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

"""Integration-test environment: deploy helpers plus a manual standup/teardown CLI.

You can run this module directly to stand up the black-box environment (a
server plus an allowed and a blocked client, with the firewall applied) in a
persistent Juju model and leave it running for manual testing:

    python tests/integration/environment.py standup     # deploy and leave it up
    python tests/integration/environment.py teardown    # destroy it

By default the locally packed .charm is deployed (found via CHARM_PATH); pass
'standup --channel latest/edge' (or set CHARM_CHANNEL) to deploy the published
charm from Charmhub instead. CHARM_PATH, TEST_BASE and CHARM_CHANNEL work the
same way as when running the tests.
"""

import argparse
import glob
import os
import pathlib

import jubilant

APP = "nftables-operator"
PRINCIPAL = "ubuntu"
PRINCIPAL_UNIT = "ubuntu/0"
# The base to deploy on; CI runs the suite once per supported base via TEST_BASE.
BASE = os.environ.get("TEST_BASE", "ubuntu@24.04")
# Charmhub channel to deploy the published charm from (e.g. "latest/edge"). When
# unset, the locally packed .charm is deployed instead.
CHANNEL = os.environ.get("CHARM_CHANNEL")
SERVER_PORT = 8000
DEFAULT_MODEL = "nftables-blackbox"


class CharmNotFoundError(Exception):
    """No packed charm matches the requested base."""


def charm_path() -> str:
    """Locate the packed charm for BASE.

    'charmcraft pack' emits one file per platform (e.g. ...ubuntu@24.04...), so we
    select the one matching the base we deploy on. CHARM_PATH may point at a
    specific .charm file (used as-is) or a directory to search; it defaults to the
    repo root. Raises CharmNotFoundError if nothing matches.
    """
    env = os.environ.get("CHARM_PATH")
    if env and os.path.isfile(env):
        return env
    search_dir = env if env and os.path.isdir(env) else str(pathlib.Path(__file__).parents[2])
    version = BASE.split("@", 1)[1]  # e.g. "24.04"
    matches = sorted(glob.glob(os.path.join(search_dir, f"{APP}_*{version}*.charm")))
    if not matches:
        raise CharmNotFoundError(f"no {version} charm in {search_dir}; run 'charmcraft pack'")
    return matches[0]


def deploy_operator(juju: jubilant.Juju, channel: str | None = None) -> None:
    """Deploy the nftables-operator subordinate.

    With a channel, deploy the published charm from Charmhub; otherwise deploy the
    locally packed .charm (see charm_path). Either way the subordinate deploys
    without units; they arrive via the relation.
    """
    if channel:
        juju.deploy(APP, channel=channel, base=BASE)
    else:
        juju.deploy(charm_path(), base=BASE)


def unit_ip(juju: jubilant.Juju, unit: str) -> str:
    """Return a unit's IP address."""
    app = unit.split("/")[0]
    info = juju.status().apps[app].units[unit]
    return info.public_address or info.address


def connect_cmd(ip: str, port: int, timeout: int) -> str:
    """Shell command that exits 0 iff a TCP connection to ip:port succeeds."""
    py = f"import socket; socket.create_connection(('{ip}', {port}), timeout={timeout})"
    return f'python3 -c "{py}"'


def can_connect(juju: jubilant.Juju, from_unit: str, server_ip: str) -> bool:
    """Whether from_unit can open a TCP connection to the server port.

    A dropped SYN makes the probe time out and exit non-zero, which jubilant
    surfaces as TaskError; that is the 'blocked' outcome.
    """
    try:
        juju.exec(connect_cmd(server_ip, SERVER_PORT, 8), unit=from_unit)
        return True
    except jubilant.TaskError:
        return False


def server_ruleset(allowed_ip: str) -> str:
    """A ruleset that accepts the server port only from allowed_ip.

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


def stand_up(juju: jubilant.Juju, channel: str | None = None) -> str:
    """Deploy the black-box topology, start the server, and apply the firewall.

    One server machine (running the charm plus a plain HTTP server) and two client
    machines. With a channel the published charm is deployed, otherwise the local
    build. Returns the server's IP. client/0 is allowed to reach the server port;
    client/1 is dropped by the ruleset.
    """
    juju.deploy(PRINCIPAL, "server", base=BASE)
    juju.deploy(PRINCIPAL, "client", base=BASE, num_units=2)
    deploy_operator(juju, channel)
    juju.integrate(APP, "server")

    # Wait for the three machines. The subordinate stays blocked (no rules yet),
    # so wait on the principals rather than on all-active.
    juju.wait(
        lambda s: s.apps["server"].is_active and s.apps["client"].is_active,
        error=jubilant.any_error,
        timeout=1200,
    )

    server_ip = unit_ip(juju, "server/0")
    allowed_ip = unit_ip(juju, "client/0")

    # Start a plain HTTP server on the server machine (a transient systemd unit so
    # it outlives the exec) and wait until the port is listening. This happens
    # before any rules are applied, so the firewall is still open.
    juju.exec(
        f"systemd-run --unit=blackbox-httpd python3 -m http.server {SERVER_PORT}",
        unit="server/0",
    )
    probe = connect_cmd("127.0.0.1", SERVER_PORT, 2)
    juju.exec(f"for _ in $(seq 1 15); do {probe} && break; sleep 1; done", unit="server/0")

    # Both clients can reach the server before the firewall is configured.
    if not (can_connect(juju, "client/0", server_ip) and can_connect(juju, "client/1", server_ip)):
        raise RuntimeError("clients cannot reach the server before the firewall is applied")

    # Allow only client/0 to the server port; client/1 (and anyone else) is dropped.
    juju.config(APP, {"rules": server_ruleset(allowed_ip)})
    juju.wait(jubilant.all_active, error=jubilant.any_error, timeout=600)
    return server_ip


def _standup(model: str, channel: str | None) -> None:
    """Deploy for manual tests."""
    if not channel:
        charm_path()  # fail fast (before creating a model) if the charm isn't built
    juju = jubilant.Juju(model=model)
    juju.add_model(model)
    server_ip = stand_up(juju, channel)
    source = f"published charm ({channel})" if channel else "locally packed charm"
    probe = connect_cmd(server_ip, SERVER_PORT, 8)
    print(
        f"\nBlack-box environment ready in model '{model}' ({source}):\n"
        f"  server/0  {server_ip}:{SERVER_PORT} (HTTP)\n"
        f"  client/0  allowed through the firewall\n"
        f"  client/1  blocked by the firewall\n"
        f"  probe:    juju exec -m {model} --unit client/1 -- {probe}\n"
        f"  teardown: python tests/integration/environment.py teardown --model {model}"
    )


def _teardown(model: str) -> None:
    jubilant.Juju().destroy_model(model, destroy_storage=True, force=True)
    print(f"destroyed model '{model}'")


def main() -> None:
    """Stand up or tear down the black-box environment from the command line."""
    parser = argparse.ArgumentParser(description="Manage the black-box integration environment.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    standup = subparsers.add_parser("standup", help="deploy the environment and leave it running")
    standup.add_argument(
        "--model", default=DEFAULT_MODEL, help=f"model name (default: {DEFAULT_MODEL})"
    )
    standup.add_argument(
        "--channel",
        default=CHANNEL,
        help="deploy the published charm from this Charmhub channel (e.g. latest/edge) "
        "instead of the locally packed .charm; defaults to $CHARM_CHANNEL",
    )

    teardown = subparsers.add_parser("teardown", help="destroy the environment")
    teardown.add_argument(
        "--model", default=DEFAULT_MODEL, help=f"model name (default: {DEFAULT_MODEL})"
    )

    args = parser.parse_args()

    try:
        if args.command == "standup":
            _standup(args.model, args.channel)
        else:
            _teardown(args.model)
    except CharmNotFoundError as exc:
        raise SystemExit(f"error: {exc}")


if __name__ == "__main__":
    main()
