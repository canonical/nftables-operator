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

"""A subordinate charm that applies an operator-provided nftables ruleset."""

import logging

import ops

import nftables

logger = logging.getLogger(__name__)


class NftablesOperatorCharm(ops.CharmBase):
    """Apply the configured nftables ruleset to the unit."""

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.install, self._on_install)
        self.framework.observe(self.on.config_changed, self._reconcile)
        self.framework.observe(self.on.upgrade_charm, self._reconcile)
        # update-status fires periodically; use it to re-converge on drift.
        self.framework.observe(self.on.update_status, self._reconcile)
        self.framework.observe(self.on.reapply_action, self._on_reapply)

    def _on_install(self, event: ops.EventBase) -> None:
        """Install nftables, then apply whatever rules are configured."""
        self.unit.status = ops.MaintenanceStatus("installing nftables")
        nftables.ensure_installed()
        self._reconcile(event)

    def _reconcile(self, _: ops.EventBase) -> None:
        """Converge the firewall toward the configured ruleset."""
        self._apply(force=False)

    def _on_reapply(self, event: ops.ActionEvent) -> None:
        """Re-apply the ruleset even if /etc/nftables.conf already matches.

        This heals the case where the live ruleset was changed out of band, which
        the periodic reconcile deliberately ignores.
        """
        error = self._apply(force=True)
        if error is not None:
            event.fail(error)
        else:
            event.set_results({"result": "nftables ruleset reapplied"})

    def _apply(self, force: bool) -> str | None:
        """Validate and apply the configured ruleset, setting unit status.

        Return None when the ruleset is in force, otherwise the reason the unit is
        blocked. When force is False and /etc/nftables.conf already matches the
        desired rules, re-applying is skipped to avoid flushing the live ruleset
        (which would wipe runtime state such as dynamic sets and counters).
        """
        nftables.ensure_installed()

        rules = self.config.get("rules")
        if not isinstance(rules, str) or not rules.strip():
            self.unit.status = ops.BlockedStatus("no rules configured")
            return "no rules configured"

        # /etc/nftables.conf is written verbatim only after a successful apply, so
        # if it already matches the desired rules they are already in force.
        if not force and nftables.read_config() == rules:
            self.unit.status = ops.ActiveStatus()
            return None

        error = nftables.check(rules)
        if error is not None:
            logger.warning("rejecting invalid nftables ruleset: %s", error)
            self.unit.status = ops.BlockedStatus(f"invalid rules: {error}")
            return f"invalid rules: {error}"

        error = nftables.apply(rules)
        if error is not None:
            logger.error("failed to apply nftables ruleset: %s", error)
            self.unit.status = ops.BlockedStatus(f"apply failed: {error}")
            return f"apply failed: {error}"

        # Persist only if we successfully applied, so the file stays a truthful
        # marker and nftables.service reloads the same rules on reboot.
        nftables.write_config(rules)
        self.unit.status = ops.ActiveStatus()
        return None


if __name__ == "__main__":  # pragma: nocover
    ops.main(NftablesOperatorCharm)
