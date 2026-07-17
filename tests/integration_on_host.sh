#!/usr/bin/env bash
# Run an integration action against the Juju controller on this host. For an
# isolated run that leaves the host untouched, use tests/integration_in_vm.sh.
#
#   tests/integration_on_host.sh [test] [options] [pytest args...]
#   tests/integration_on_host.sh standup [options] [environment.py args...]
#   tests/integration_on_host.sh teardown [environment.py args...]
#
# Options (these override the same-named environment variables):
#   --base BASE        deploy on this base (default: ubuntu@24.04)
#   --channel CHANNEL  use the published charm from this Charmhub channel
#                      (e.g. latest/edge) instead of a local pack
#   --repack           force a fresh local charmcraft pack
#
# Anything after the options is passed through to pytest (test) or to
# environment.py (standup/teardown), for example:
#   tests/integration_on_host.sh --base ubuntu@26.04 -k firewall
#   tests/integration_on_host.sh --channel latest/edge
#   tests/integration_on_host.sh standup --channel latest/edge --model demo
#
# Prerequisites (see DEVELOPMENT.md): a Juju controller on LXD, the dev
# dependencies (pip install -e '.[dev]'), and charmcraft when packing locally.
set -euo pipefail

cd "$(dirname "$0")/.."

APP=nftables-operator

require() {
    command -v "$1" >/dev/null 2>&1 && return
    echo "error: '$1' is not installed (see DEVELOPMENT.md)" >&2
    exit 1
}

usage() {
    # Print the header comment (everything from line 2 up to the first non-# line).
    awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

# Subcommand: test (default), standup, or teardown.
action="test"
case "${1:-}" in
    test | standup | teardown)
        action="$1"
        shift
        ;;
    -h | --help | help)
        usage
        exit 0
        ;;
    "" | -*) ;; # no subcommand: run the test suite; the rest are options/args
    *)
        echo "error: unknown subcommand '$1'" >&2
        exit 1
        ;;
esac

# Options (default to the same-named env vars, so both flags and env work).
base="${TEST_BASE:-}"
channel="${CHARM_CHANNEL:-}"
repack="${REPACK:-}"
needs_value() {
    [ -n "${2:-}" ] && return
    echo "error: $1 requires a value" >&2
    exit 1
}
while [ $# -gt 0 ]; do
    case "$1" in
        --base) needs_value "$1" "${2:-}"; base="$2"; shift 2 ;;
        --base=*) base="${1#*=}"; shift ;;
        --channel) needs_value "$1" "${2:-}"; channel="$2"; shift 2 ;;
        --channel=*) channel="${1#*=}"; shift ;;
        --repack) repack=1; shift ;;
        --) shift; break ;; # everything after '--' is passthrough
        *) break ;;         # first non-option: the rest is passthrough
    esac
done

# environment.py and pytest read these from the environment.
[ -n "${base}" ] && export TEST_BASE="${base}"
[ -n "${channel}" ] && export CHARM_CHANNEL="${channel}"

require juju
if ! juju whoami >/dev/null 2>&1; then
    echo "error: no Juju controller found; run 'juju bootstrap localhost lxd' first" >&2
    exit 1
fi

# Local 'test'/'standup' need the charm packed; the published charm and 'teardown'
# do not. Packing is slow, so reuse an existing artifact unless --repack is given.
if [ -z "${channel}" ] && [ "${action}" != teardown ]; then
    require charmcraft
    shopt -s nullglob
    charms=("${APP}"_*.charm)
    shopt -u nullglob
    if [ ${#charms[@]} -eq 0 ] || [ -n "${repack}" ]; then
        echo "packing charm (this can take a few minutes)..."
        charmcraft pack
        charms=("${APP}"_*.charm)
    fi
    # Pass the directory (charmcraft emits one .charm per base); the tests pick
    # the file matching the base they deploy on.
    export CHARM_PATH="$(pwd)"
    echo "using charms in ${CHARM_PATH}: ${charms[*]}"
fi

case "${action}" in
    test)
        exec python -m pytest tests/integration "$@"
        ;;
    standup | teardown)
        exec python tests/integration/environment.py "${action}" "$@"
        ;;
esac
