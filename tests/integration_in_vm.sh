#!/usr/bin/env bash
# Run integration actions inside a disposable LXD virtual machine, so the host
# only ever needs LXD. The VM gets its own juju, charmcraft and (nested) LXD,
# bootstraps a controller, and runs tests/integration_on_host.sh inside it.
#
# Actions (each brings the VM up first, then runs inside it):
#   tests/integration_in_vm.sh [options] [pytest args]      one-shot: up, test, down
#   tests/integration_in_vm.sh test [options] [pytest args] run the test suite
#   tests/integration_in_vm.sh standup [options]            stand up the black-box env
#   tests/integration_in_vm.sh teardown [options]           tear down the black-box env
#
# VM lifecycle:
#   tests/integration_in_vm.sh up [options]                 create/start the VM
#   tests/integration_in_vm.sh shell                        shell into the VM as 'ubuntu'
#   tests/integration_in_vm.sh down [--purge]               delete the VM
#
# Options:
#   --base BASE        deploy on this base (default: ubuntu@24.04)
#   --channel CHANNEL  test/standup against the published charm from this Charmhub
#                      channel (e.g. latest/edge) instead of a local pack
#   --repack           force a fresh local pack
#   --rebuild-image    rebuild the cached VM base image before starting
#   --keep             (one-shot) leave the VM up instead of deleting it afterwards
#   --purge            (down) also remove the cached image and the LXD project
#
# For example:
#   tests/integration_in_vm.sh test --channel latest/edge -k firewall
#   tests/integration_in_vm.sh test --base ubuntu@26.04
#   tests/integration_in_vm.sh standup
#   tests/integration_in_vm.sh teardown
#
# The VM stays up between actions, so charmcraft's build instance and the packed
# charm are reused and each action re-syncs your working tree. Everything lives in
# a dedicated LXD project ("charm-integration-tests"); the first 'up' provisions
# the VM (snaps + 'juju bootstrap') and publishes it as a cached image, so later
# 'up's skip the slow setup. The image and project persist until 'down --purge'.
#
# A VM (not a container) is used on purpose: it has its own kernel, so nftables
# and the multi-machine networking the tests exercise behave exactly as on a real
# host. That requires hardware virtualization (/dev/kvm) on the host. Right after
# the VM boots, its outbound connectivity is checked; if it is unreachable
# (commonly a Docker + LXD firewall conflict on the host) the run aborts with the
# nft rules needed to fix it.
#
# Advanced tuning (environment variables): PROJECT SANDBOX IMAGE CACHE_ALIAS CPU
#      MEMORY DISK JUJU_CHANNEL CHARMCRAFT_CHANNEL
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="${PROJECT:-charm-integration-tests}"
SANDBOX="${SANDBOX:-nft-operator-itest}"
IMAGE="${IMAGE:-ubuntu:24.04}"
CACHE_ALIAS="${CACHE_ALIAS:-charm-test-base}"
CPU="${CPU:-4}"
MEMORY="${MEMORY:-8GiB}"
DISK="${DISK:-30GiB}"
JUJU_CHANNEL="${JUJU_CHANNEL:-3.6/stable}"
CHARMCRAFT_CHANNEL="${CHARMCRAFT_CHANNEL:-4.x/stable}"

log() { echo ">> $*"; }

# Project-scoped lxc, plus guest-exec helpers:
#   vm  - run as root on the default PATH (coreutils, apt, snap).
#   vml - run as root in a login shell, so snap apps under /snap/bin (lxd) resolve.
#   vmu - run as the 'ubuntu' user via a login session. juju is a strictly
#         confined snap: its home interface does not cover /root, and snap-confine
#         also needs a systemd login session (a proper cgroup). 'su -' is used,
#         not sudo: su's PAM stack runs pam_systemd (so a session/scope exists)
#         and initgroups (so the lxd group applies); sudo's noninteractive session
#         stack does neither. A login shell also puts /snap/bin on PATH.
lxp() { lxc --project "${PROJECT}" "$@"; }
vm() { lxp exec "${SANDBOX}" -- "$@"; }
vml() { lxp exec "${SANDBOX}" -- bash -lc "$*"; }
vmu() { lxp exec "${SANDBOX}" -- su - ubuntu -c "$*"; }

launch_vm() {
    local source="$1"
    log "launching VM ${SANDBOX} from ${source} (${CPU} CPU, ${MEMORY} RAM, ${DISK} disk)..."
    if ! lxp launch "${source}" "${SANDBOX}" --vm \
        -c limits.cpu="${CPU}" -c limits.memory="${MEMORY}" \
        -d root,size="${DISK}" 2>/dev/null; then
        # Some storage pools (e.g. dir) reject a root size override; retry without.
        log "storage pool would not accept a disk size; using the default disk size..."
        lxp launch "${source}" "${SANDBOX}" --vm \
            -c limits.cpu="${CPU}" -c limits.memory="${MEMORY}"
    fi
}

wait_agent() {
    log "waiting for the VM agent..."
    for _ in $(seq 1 60); do
        vm true >/dev/null 2>&1 && return
        sleep 2
    done
    echo "error: the VM agent did not come up" >&2
    exit 1
}

wait_cloud_init() {
    log "waiting for the VM to finish booting..."
    for _ in $(seq 1 30); do
        vm cloud-init status --wait >/dev/null 2>&1 && return
        sleep 6
    done
    echo "error: cloud-init did not finish" >&2
    exit 1
}

wait_controller() {
    log "waiting for the Juju controller..."
    for _ in $(seq 1 90); do
        vmu 'juju show-controller' >/dev/null 2>&1 && return
        sleep 2
    done
    echo "error: the Juju controller did not come up" >&2
    exit 1
}

provision() {
    log "installing snaps inside the VM..."
    vm snap wait system seed.loaded
    vm snap install lxd >/dev/null 2>&1 || true
    vm snap install juju --channel "${JUJU_CHANNEL}"
    vm snap install charmcraft --classic --channel "${CHARMCRAFT_CHANNEL}"
    vm apt-get update -qq
    vm apt-get install -y -qq python3-venv >/dev/null
    # juju/charmcraft/tests run as 'ubuntu'; it needs lxd-group access.
    vm usermod -aG lxd ubuntu

    log "initialising LXD and bootstrapping Juju inside the VM..."
    vml 'lxd init --auto'
    vmu 'juju bootstrap localhost lxd-test'
}

check_network() {
    log "checking the VM has outbound network access..."
    local host
    for _ in $(seq 1 5); do
        for host in 1.1.1.1 8.8.8.8; do
            if vm timeout 2 bash -c ": >/dev/tcp/${host}/443" 2>/dev/null; then
                return 0
            fi
        done
        sleep 3
    done
    return 1
}

warn_network() {
    cat >&2 <<'EOF'
WARNING: the sandbox VM has no outbound network access; aborting.

The usual cause on a developer machine is a Docker + LXD firewall conflict:
installing Docker sets the filter FORWARD chain policy to drop and does not
permit the LXD bridge, so traffic forwarded for LXD instances (including this
VM) is dropped.

To let Docker and LXD coexist, insert these rules on the HOST, then re-run
(replace lxdbr0 if your LXD bridge has a different name):

    sudo nft insert rule ip filter DOCKER-USER iifname "lxdbr0" accept
    sudo nft insert rule ip filter DOCKER-USER oifname "lxdbr0" accept

See the LXD docs: "Prevent connectivity issues with LXD and Docker".
EOF
}

# Verify outbound connectivity, or warn (with the Docker/LXD fix) and abort.
require_network() {
    if ! check_network; then
        warn_network
        exit 1
    fi
}

# --- host / project setup ---------------------------------------------------
ensure_host() {
    if [ ! -e /dev/kvm ]; then
        echo "error: /dev/kvm not present; an LXD VM needs hardware virtualization." >&2
        echo "       If the host is itself a VM, enable nested virtualization." >&2
        exit 1
    fi
    if ! command -v lxc >/dev/null 2>&1; then
        log "installing LXD on the host..."
        sudo snap install lxd
    fi
    if ! lxc list >/dev/null 2>&1; then
        echo "error: cannot talk to LXD as this user. Join the lxd group, then retry:" >&2
        echo "       sudo usermod -aG lxd \$USER && newgrp lxd" >&2
        exit 1
    fi
    # Initialise LXD on the host only if it has no storage pool yet.
    if ! lxc storage list -f csv 2>/dev/null | grep -q .; then
        log "initialising LXD on the host..."
        sudo lxd init --auto
    fi
    # Dedicated project. features.profiles=false reuses the default project's
    # profiles (so the VM gets a network and root disk); images stay per-project
    # so the cached base image does not leak into the default project.
    if ! lxc project show "${PROJECT}" >/dev/null 2>&1; then
        log "creating LXD project ${PROJECT}..."
        lxc project create "${PROJECT}" -c features.profiles=false
    fi
}

# RUNNING, STOPPED, or absent.
vm_state() {
    if lxp info "${SANDBOX}" >/dev/null 2>&1; then
        lxp info "${SANDBOX}" | awk -F': *' 'tolower($1) == "status" {print toupper($2); exit}'
    else
        echo absent
    fi
}

# --- lifecycle --------------------------------------------------------------
# Ensure the VM exists, is running, and its controller is ready. Idempotent: a
# no-op when the VM is already up, so 'test' can call it cheaply every run.
bring_up() {
    ensure_host

    case "$(vm_state)" in
    RUNNING)
        log "VM ${SANDBOX} is already running."
        return
        ;;
    STOPPED)
        log "starting existing VM ${SANDBOX}..."
        lxp start "${SANDBOX}"
        wait_agent
        require_network
        wait_controller
        return
        ;;
    esac

    if [ -n "${REBUILD_IMAGE:-}" ]; then
        log "REBUILD_IMAGE set; discarding cached image ${CACHE_ALIAS}..."
        lxp image delete "${CACHE_ALIAS}" >/dev/null 2>&1 || true
    fi

    if lxp image info "${CACHE_ALIAS}" >/dev/null 2>&1; then
        # Fast path: the cached image is already provisioned and bootstrapped.
        launch_vm "${CACHE_ALIAS}"
        wait_agent
        require_network
        wait_controller
    else
        # Slow path: provision from scratch, then cache the result for next time.
        launch_vm "${IMAGE}"
        wait_agent
        require_network
        wait_cloud_init
        provision

        log "publishing ${CACHE_ALIAS} for reuse (one-time cost)..."
        lxp stop "${SANDBOX}"
        lxp publish "${SANDBOX}" --alias "${CACHE_ALIAS}" >/dev/null
        lxp start "${SANDBOX}"
        wait_agent
        wait_controller
    fi
}

# Copy the working tree (uncommitted changes included) into the VM. Overwrites in
# place rather than wiping the dir, so the persistent .venv and any packed *.charm
# survive between runs. The source runs as 'ubuntu', hence its home.
sync_source() {
    log "syncing the charm source into the VM..."
    vm mkdir -p /home/ubuntu/charm
    tar -czf - \
        --exclude=.git --exclude=.venv --exclude='*.charm' \
        --exclude=__pycache__ --exclude='.*_cache' . |
        vm tar -xzf - -C /home/ubuntu/charm
    vm chown -R ubuntu:ubuntu /home/ubuntu/charm
}

# Create the venv and install dev deps once; reused on later runs.
ensure_deps() {
    if vmu 'test -d ~/charm/.venv' >/dev/null 2>&1; then
        return
    fi
    log "creating virtualenv and installing dependencies inside the VM..."
    vmu 'cd ~/charm \
        && python3 -m venv .venv \
        && .venv/bin/pip install --quiet --upgrade pip \
        && .venv/bin/pip install --quiet -e ".[dev]"'
}

# Run an integration_on_host.sh action (test/standup/teardown) inside the VM,
# forwarding the relevant env vars and any extra args. The VM is brought up and
# the working tree re-synced first.
run_action() {
    local action="$1"
    shift
    bring_up
    sync_source
    ensure_deps
    log "running '${action}' inside the VM..."

    # Forward only the env vars that are set (an empty TEST_BASE would override
    # the test's default). su - resets the environment, so export inside the shell.
    local script='cd ~/charm && . .venv/bin/activate'
    [ -n "${TEST_BASE:-}" ] && script+=" && export TEST_BASE='${TEST_BASE}'"
    [ -n "${CHARM_CHANNEL:-}" ] && script+=" && export CHARM_CHANNEL='${CHARM_CHANNEL}'"
    [ -n "${REPACK:-}" ] && script+=" && export REPACK='${REPACK}'"
    # 'su - ubuntu -c CMD arg0 args...' passes args to the shell running CMD, so
    # the leading 'bash' becomes $0 and the extra args become "$@".
    script+=" && exec bash tests/integration_on_host.sh ${action} \"\$@\""
    lxp exec "${SANDBOX}" -- su - ubuntu -c "${script}" bash "$@"
}

destroy() {
    # Tearing down needs neither /dev/kvm nor host init; just remove what exists.
    log "deleting sandbox VM ${SANDBOX} (cached image ${CACHE_ALIAS} kept)..."
    lxp delete --force "${SANDBOX}" >/dev/null 2>&1 || true
    if [ -n "${PURGE:-}" ]; then
        log "--purge given; removing cached image ${CACHE_ALIAS} and project ${PROJECT}..."
        lxp image list -f csv -c f 2>/dev/null | while read -r fingerprint; do
            [ -n "${fingerprint}" ] && lxp image delete "${fingerprint}" >/dev/null 2>&1 || true
        done
        lxc project delete "${PROJECT}" >/dev/null 2>&1 || true
    fi
}

open_shell() {
    bring_up
    exec lxc --project "${PROJECT}" exec "${SANDBOX}" -- su - ubuntu
}

usage() {
    # Print the header comment (everything from line 2 up to the first non-# line).
    awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

# --- dispatch ---------------------------------------------------------------
# Subcommand first (default: one-shot). Then parse our own flags; anything else
# (--base/--channel/--repack, pytest args) is forwarded to integration_on_host.sh.
action="${1:-oneshot}"
case "${action}" in
up | test | standup | teardown | down | shell)
    shift
    ;;
-h | --help | help)
    usage
    exit 0
    ;;
"" | -*)
    action="oneshot" # no subcommand: one-shot (up, test, down)
    ;;
*)
    echo "error: unknown subcommand '${action}'" >&2
    usage >&2
    exit 1
    ;;
esac

forward=()
while [ $# -gt 0 ]; do
    case "$1" in
    --keep) KEEP=1 ;;
    --purge) PURGE=1 ;;
    --rebuild-image) REBUILD_IMAGE=1 ;;
    *) forward+=("$1") ;;
    esac
    shift
done

case "${action}" in
up)
    bring_up
    ;;
test | standup | teardown)
    run_action "${action}" "${forward[@]}"
    ;;
down)
    destroy
    ;;
shell)
    open_shell
    ;;
oneshot)
    # Bring up, run the test suite, then tear down the VM unless --keep was given.
    cleanup() {
        if [ -n "${KEEP:-}" ]; then
            log "--keep set; leaving ${SANDBOX} up (remove it with: $0 down)"
        else
            destroy
        fi
    }
    trap cleanup EXIT
    run_action test "${forward[@]}"
    ;;
esac
