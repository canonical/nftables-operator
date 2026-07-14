#!/usr/bin/env python3
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

"""Manage nftables on a charm unit.

Every function here wraps a subprocess or file operation. Expected failures are
returned as an error message string rather than raised, so the charm can turn
them into unit status without exception handling.
"""

import shutil
import subprocess

NFTABLES_CONF = "/etc/nftables.conf"


def _run(cmd: list[str], stdin: str | None = None) -> subprocess.CompletedProcess:
    """Run a command, capturing output and never raising on a non-zero exit."""
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)


def _first_line(text: str) -> str:
    """Return the first non-empty line of text, or the whole thing if none."""
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return text.strip()


def ensure_installed() -> None:
    """Ensure the nftables package is installed and its service is enabled."""
    if shutil.which("nft") is None:
        _run(["apt-get", "install", "-y", "nftables"])
    _run(["systemctl", "enable", "--now", "nftables"])


def check(rules: str) -> str | None:
    """Validate a ruleset with 'nft -c' without applying it.

    Return None if the ruleset is valid, otherwise the nft error message.
    """
    result = _run(["nft", "-c", "-f", "-"], stdin=rules)
    if result.returncode == 0:
        return None
    return _first_line(result.stderr)


def read_config() -> str | None:
    """Return the current contents of /etc/nftables.conf, or None if absent."""
    try:
        with open(NFTABLES_CONF) as conf:
            return conf.read()
    except FileNotFoundError:
        return None


def write_config(rules: str) -> None:
    """Write the ruleset verbatim to /etc/nftables.conf."""
    with open(NFTABLES_CONF, "w") as conf:
        conf.write(rules)


def apply(rules: str) -> str | None:
    """Apply a ruleset with 'nft -f', reading it from stdin.

    Return None on success, otherwise the nft error message. The ruleset is not
    written to /etc/nftables.conf here; the caller persists it only after a
    successful apply.
    """
    result = _run(["nft", "-f", "-"], stdin=rules)
    if result.returncode == 0:
        return None
    return _first_line(result.stderr)
