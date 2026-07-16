#!/usr/bin/env bash
# Run the integration tests inside a disposable LXD virtual machine, so the host
# only ever needs LXD. The VM gets its own juju, charmcraft and (nested) LXD,
# bootstraps a controller, runs tests/integration_on_host.sh, and is deleted
# afterwards.
#
#   tests/integration_in_vm.sh                  # run in a fresh VM, then delete it
#   tests/integration_in_vm.sh -k firewall      # extra args pass through to pytest
#   KEEP=1 tests/integration_in_vm.sh           # leave the VM up for debugging
#
# A VM (not a container) is used on purpose: it has its own kernel, so nftables
# and the multi-machine networking the tests exercise behave exactly as on a real
# host. That requires hardware virtualization (/dev/kvm) on the host.
#
# Tunables (environment variables): SANDBOX, IMAGE, CPU, MEMORY, DISK,
# JUJU_CHANNEL, CHARMCRAFT_CHANNEL.
set -euo pipefail

cd "$(dirname "$0")/.."

SANDBOX="${SANDBOX:-nft-operator-itest}"
IMAGE="${IMAGE:-ubuntu:24.04}"
CPU="${CPU:-4}"
MEMORY="${MEMORY:-8GiB}"
DISK="${DISK:-30GiB}"
JUJU_CHANNEL="${JUJU_CHANNEL:-3.6/stable}"
CHARMCRAFT_CHANNEL="${CHARMCRAFT_CHANNEL:-3.x/stable}"

log() { echo ">> $*"; }

# --- host prerequisites -----------------------------------------------------
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

# --- (re)create the sandbox VM ----------------------------------------------
cleanup() {
    if [ -n "${KEEP:-}" ]; then
        log "KEEP set; leaving ${SANDBOX} (remove it with: lxc delete --force ${SANDBOX})"
    else
        log "deleting sandbox VM ${SANDBOX}..."
        lxc delete --force "${SANDBOX}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

lxc delete --force "${SANDBOX}" >/dev/null 2>&1 || true

log "launching ${IMAGE} VM ${SANDBOX} (${CPU} CPU, ${MEMORY} RAM, ${DISK} disk)..."
if ! lxc launch "${IMAGE}" "${SANDBOX}" --vm \
        -c limits.cpu="${CPU}" -c limits.memory="${MEMORY}" \
        -d root,size="${DISK}" 2>/dev/null; then
    # Some storage pools (e.g. dir) reject a root size override; retry without it.
    log "storage pool would not accept a disk size; using the default disk size..."
    lxc launch "${IMAGE}" "${SANDBOX}" --vm \
        -c limits.cpu="${CPU}" -c limits.memory="${MEMORY}"
fi

log "waiting for the VM to finish booting..."
lxc exec "${SANDBOX}" -- cloud-init status --wait >/dev/null

# --- provision juju / charmcraft / lxd inside the VM ------------------------
vm() { lxc exec "${SANDBOX}" -- "$@"; }

log "installing snaps inside the VM..."
vm snap wait system seed.loaded
vm snap install lxd >/dev/null 2>&1 || true
vm snap install juju --channel "${JUJU_CHANNEL}"
vm snap install charmcraft --classic --channel "${CHARMCRAFT_CHANNEL}"
vm apt-get update -qq
vm apt-get install -y -qq python3-venv >/dev/null

log "initialising LXD and bootstrapping Juju inside the VM..."
vm lxd init --auto
vm juju bootstrap localhost lxd-test

# --- copy the working tree in (uncommitted changes included) ----------------
log "copying the charm source into the VM..."
vm rm -rf /root/charm
vm mkdir -p /root/charm
tar -czf - \
    --exclude=.git --exclude=.venv --exclude='*.charm' \
    --exclude=__pycache__ --exclude='.*_cache' . \
  | vm tar -xzf - -C /root/charm

log "installing python dependencies inside the VM..."
vm bash -lc "cd /root/charm \
    && python3 -m venv .venv \
    && .venv/bin/pip install --quiet --upgrade pip \
    && .venv/bin/pip install --quiet -e '.[dev]'"

# --- run the tests (forwarding any extra args to pytest) --------------------
log "running integration tests inside the VM..."
lxc exec "${SANDBOX}" -- bash -lc \
    'cd /root/charm && . .venv/bin/activate && exec bash tests/integration_on_host.sh "$@"' \
    bash "$@"
