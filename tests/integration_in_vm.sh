#!/usr/bin/env bash
# Run the integration tests inside an LXD virtual machine, so the host only ever
# needs LXD. The VM gets its own juju, charmcraft and (nested) LXD, bootstraps a
# controller, and runs tests/integration_on_host.sh.
#
# Usage:
#   tests/integration_in_vm.sh [pytest args...]   one-shot: up, test, down
#   tests/integration_in_vm.sh up                 create/start the VM, leave it up
#   tests/integration_in_vm.sh test [pytest args] run the tests in the VM (repeatable)
#   tests/integration_in_vm.sh down               delete the VM (keeps cached image)
#   tests/integration_in_vm.sh shell              open a shell in the VM as 'ubuntu'
#
# Iterate quickly (the VM stays up between runs, so charmcraft's build instance
# and the packed charm are reused; each 'test' re-syncs your working tree):
#   tests/integration_in_vm.sh up
#   tests/integration_in_vm.sh test -k firewall     # repeat as you edit tests
#   REPACK=1 tests/integration_in_vm.sh test        # repack after charm changes
#   tests/integration_in_vm.sh down
#
# Everything lives in a dedicated LXD project ("charm-integration-tests"). The
# first 'up' provisions the VM (snaps + 'juju bootstrap') and publishes it as a
# cached image; later 'up's launch from that image, skipping the slow setup. The
# cached image and project persist until 'down' with PURGE=1.
#
# A VM (not a container) is used on purpose: it has its own kernel, so nftables
# and the multi-machine networking the tests exercise behave exactly as on a real
# host. That requires hardware virtualization (/dev/kvm) on the host. Right after
# the VM boots, its outbound connectivity is checked; if it is unreachable
# (commonly a Docker + LXD firewall conflict on the host) the run aborts with the
# nft rules needed to fix it.
#
# Env: PROJECT SANDBOX IMAGE CACHE_ALIAS CPU MEMORY DISK JUJU_CHANNEL
#      CHARMCRAFT_CHANNEL REBUILD_IMAGE REPACK KEEP PURGE
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
CHARMCRAFT_CHANNEL="${CHARMCRAFT_CHANNEL:-3.x/stable}"

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

# Sync the latest source and run the tests. Reuses the packed charm unless REPACK
# is set; forward it (and the pytest args) into the ubuntu login session.
run_tests() {
    bring_up
    sync_source
    ensure_deps
    log "running integration tests inside the VM..."
    local script='cd ~/charm && . .venv/bin/activate'
    script+=" && export REPACK='${REPACK:-}'"
    # 'su - ubuntu -c CMD arg0 args...' passes args to the shell running CMD, so
    # the leading 'bash' becomes $0 and the pytest args become "$@".
    script+=' && exec bash tests/integration_on_host.sh "$@"'
    lxp exec "${SANDBOX}" -- su - ubuntu -c "${script}" bash "$@"
}

destroy() {
    # Tearing down needs neither /dev/kvm nor host init; just remove what exists.
    log "deleting sandbox VM ${SANDBOX} (cached image ${CACHE_ALIAS} kept)..."
    lxp delete --force "${SANDBOX}" >/dev/null 2>&1 || true
    if [ -n "${PURGE:-}" ]; then
        log "PURGE set; removing cached image ${CACHE_ALIAS} and project ${PROJECT}..."
        lxp image list -f csv -c f 2>/dev/null | while read -r fingerprint; do
            [ -n "${fingerprint}" ] && lxp image delete "${fingerprint}" >/dev/null 2>&1 || true
        done
        lxc project delete "${PROJECT}" >/dev/null 2>&1 || true
    fi
}

open_shell() {
    bring_up
    exec lxp exec "${SANDBOX}" -- su - ubuntu
}

usage() {
    # Print the header comment (everything from line 2 up to the first non-# line).
    awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

# --- dispatch ---------------------------------------------------------------
case "${1:-}" in
up)
    bring_up
    ;;
test)
    shift
    run_tests "$@"
    ;;
down)
    destroy
    ;;
shell)
    open_shell
    ;;
-h | --help | help)
    usage
    ;;
"" | -*)
    # One-shot: bring up, run the tests (all args are pytest args), then tear
    # down unless KEEP is set.
    cleanup() {
        if [ -n "${KEEP:-}" ]; then
            log "KEEP set; leaving ${SANDBOX} up (remove it with: $0 down)"
        else
            destroy
        fi
    }
    trap cleanup EXIT
    run_tests "$@"
    ;;
*)
    echo "error: unknown subcommand '$1'" >&2
    usage >&2
    exit 1
    ;;
esac
