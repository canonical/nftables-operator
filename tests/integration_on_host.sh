#!/usr/bin/env bash
# Pack the charm if needed and run the integration tests against the Juju
# controller already bootstrapped on this host. Extra arguments pass through to
# pytest. For an isolated run that leaves the host untouched, use
# tests/integration_in_vm.sh instead.
#
#   tests/integration_on_host.sh                 # run all integration tests
#   tests/integration_on_host.sh -k firewall     # run a subset
#   REPACK=1 tests/integration_on_host.sh        # force a fresh charmcraft pack
#
# Prerequisites (see DEVELOPMENT.md): charmcraft, a Juju controller on LXD, and
# the dev dependencies installed (pip install -e '.[dev]').
set -euo pipefail

cd "$(dirname "$0")/.."

APP=nftables-operator

for cmd in charmcraft juju; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: '$cmd' is not installed (see DEVELOPMENT.md)" >&2
        exit 1
    fi
done

if ! juju whoami >/dev/null 2>&1; then
    echo "error: no Juju controller found; run 'juju bootstrap localhost lxd' first" >&2
    exit 1
fi

# Packing is slow, so reuse an existing artifact unless REPACK is set.
shopt -s nullglob
charms=("${APP}"_*.charm)
shopt -u nullglob
if [ ${#charms[@]} -eq 0 ] || [ -n "${REPACK:-}" ]; then
    echo "packing charm (this can take a few minutes)..."
    charmcraft pack
    charms=("${APP}"_*.charm)
fi

# Pass the directory (charmcraft emits one .charm per base); the tests pick the
# file matching the base they deploy on.
export CHARM_PATH="$(pwd)"
echo "using charms in ${CHARM_PATH}: ${charms[*]}"

exec python -m pytest tests/integration "$@"
