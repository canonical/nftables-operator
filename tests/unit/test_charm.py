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

import contextlib
import shutil
import subprocess

import ops
import pytest
from ops import testing

import charm
import nftables

RULES = 'flush ruleset\ntable inet filter { chain input { comment "marker" } }\n'


class FakeRun:
    """Records nft/apt/systemctl calls; fails 'nft -c'/'nft -f' if *_error is set."""

    def __init__(self):
        self.calls = []
        self.check_error: None | str = None
        self.apply_error: None | str = None

    def __call__(self, cmd, stdin=None):
        self.calls.append((cmd, stdin))
        error = None
        if cmd[:2] == ["nft", "-c"]:
            error = self.check_error
        elif cmd[:2] == ["nft", "-f"]:
            error = self.apply_error
        return subprocess.CompletedProcess(cmd, 1 if error else 0, "", error or "")

    def ran(self, *prefix):
        """Return the (cmd, stdin) calls whose command starts with prefix."""
        return [(cmd, stdin) for cmd, stdin in self.calls if cmd[: len(prefix)] == list(prefix)]


class FakeConfigFile:
    """In-memory /etc/nftables.conf; contents is None when the file is absent."""

    def __init__(self, contents=None):
        self.contents = contents
        self.writes = []

    def read(self):
        return self.contents

    def write(self, rules):
        self.contents = rules
        self.writes.append(rules)


@contextlib.contextmanager
def charm_context(nft_present=True, config=None):
    """Yield (ctx, run, conf) with the nftables system boundary replaced by fakes."""
    run = FakeRun()
    conf = FakeConfigFile(config)
    saved = (nftables._run, nftables.read_config, nftables.write_config, shutil.which)

    def which(name, *args, **kwargs):
        # Control only 'nft'; defer other lookups (ops needs them) to the real one.
        if name == "nft":
            return "/usr/sbin/nft" if nft_present else None
        return saved[3](name, *args, **kwargs)

    nftables._run, nftables.read_config, nftables.write_config, shutil.which = (
        run,
        conf.read,
        conf.write,
        which,
    )
    try:
        yield testing.Context(charm.NftablesOperatorCharm), run, conf
    finally:
        nftables._run, nftables.read_config, nftables.write_config, shutil.which = saved


def test_install_installs_nftables_and_blocks_without_rules():
    with charm_context(nft_present=False) as (ctx, run, conf):
        out = ctx.run(ctx.on.install(), testing.State())
    assert run.ran("apt-get", "install")
    assert run.ran("systemctl", "enable", "--now", "nftables")
    assert conf.writes == []
    assert out.unit_status == ops.BlockedStatus("no rules configured")


def test_valid_rules_are_checked_applied_and_persisted():
    with charm_context() as (ctx, run, conf):
        out = ctx.run(ctx.on.config_changed(), testing.State(config={"rules": RULES}))
    assert run.ran("nft", "-c", "-f", "-")[0][1] == RULES  # validated on stdin
    assert run.ran("nft", "-f", "-")[0][1] == RULES  # applied on stdin
    assert conf.writes == [RULES]  # persisted after a successful apply
    assert out.unit_status == ops.ActiveStatus()


def test_up_to_date_config_is_not_reapplied():
    with charm_context(config=RULES) as (ctx, run, conf):
        out = ctx.run(ctx.on.config_changed(), testing.State(config={"rules": RULES}))
    assert run.ran("nft", "-f") == []
    assert conf.writes == []
    assert out.unit_status == ops.ActiveStatus()


def test_blank_rules_block_without_touching_nftables():
    for rules in ("", "   \n\t\n"):
        with charm_context() as (ctx, run, conf):
            out = ctx.run(ctx.on.config_changed(), testing.State(config={"rules": rules}))
        assert run.ran("nft") == []
        assert conf.writes == []
        assert out.unit_status == ops.BlockedStatus("no rules configured")


def test_invalid_rules_block_without_applying():
    with charm_context() as (ctx, run, conf):
        run.check_error = "Error: syntax error, unexpected string"
        out = ctx.run(ctx.on.config_changed(), testing.State(config={"rules": "bad"}))
    assert run.ran("nft", "-f") == []
    assert conf.writes == []
    assert isinstance(out.unit_status, ops.BlockedStatus)
    assert "invalid rules" in out.unit_status.message
    assert "syntax error" in out.unit_status.message


def test_apply_failure_blocks_and_does_not_persist():
    with charm_context() as (ctx, run, conf):
        run.apply_error = "Error: Operation not permitted"
        out = ctx.run(ctx.on.config_changed(), testing.State(config={"rules": RULES}))
    assert run.ran("nft", "-f", "-")  # apply was attempted
    assert conf.writes == []  # but nothing was persisted
    assert isinstance(out.unit_status, ops.BlockedStatus)
    assert "apply failed" in out.unit_status.message


def test_periodic_and_upgrade_events_reapply_after_drift():
    # File absent (drift), so these reconcile events re-apply and persist.
    for make_event in (lambda ctx: ctx.on.update_status(), lambda ctx: ctx.on.upgrade_charm()):
        with charm_context() as (ctx, run, conf):
            out = ctx.run(make_event(ctx), testing.State(config={"rules": RULES}))
        assert conf.writes == [RULES]
        assert out.unit_status == ops.ActiveStatus()


def test_reapply_action_forces_apply_even_when_up_to_date():
    with charm_context(config=RULES) as (ctx, run, conf):
        out = ctx.run(ctx.on.action("reapply"), testing.State(config={"rules": RULES}))
    assert run.ran("nft", "-f", "-")[0][1] == RULES
    assert conf.writes == [RULES]
    assert ctx.action_results == {"result": "nftables ruleset reapplied"}
    assert out.unit_status == ops.ActiveStatus()


def test_reapply_action_fails_without_rules():
    with charm_context() as (ctx, run, conf):
        with pytest.raises(testing.ActionFailed) as caught:
            ctx.run(ctx.on.action("reapply"), testing.State(config={"rules": ""}))
        assert "no rules configured" in caught.value.message
        assert conf.writes == []
