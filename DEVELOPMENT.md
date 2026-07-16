# nftables-operator

## Developing

Create a virtualenv and install the development dependencies:

```
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
```

## Linting and unit tests

```
ruff check .
ruff format --check .
pytest tests/unit
```

Unit tests use the `ops.testing` Scenario harness and run without Juju or a real
nftables. The system boundary (`src/nftables.py`) is replaced with in-memory
fakes.

## Building

This charm builds with charmcraft 3:

```
sudo snap install charmcraft --channel 3.x/stable --classic
charmcraft pack
```

## Integration tests

Integration tests deploy the packed charm onto `ubuntu` machines on LXD. One
test checks the live nftables ruleset. The other drives a three-machine,
"blackbox" scenario to ensure firewall rules works as expected.

The integration tests can be run against a local Juju controller + LXD
installation or within a temporary LXD VM.

### Running on a locally-available Juju controller

```
sudo snap install juju --channel 3.6/stable
lxd init --auto
juju bootstrap localhost lxd-test
```

Then use the helper script, which packs the charm (reusing an existing artifact
unless `REPACK=1`), exports `CHARM_PATH`, and runs pytest. Extra arguments are
passed through:

```
tests/integration_on_host.sh                 # run all integration tests
tests/integration_on_host.sh -k firewall     # run a subset
REPACK=1 tests/integration_on_host.sh        # force a fresh pack first
```

Equivalently, run pytest directly against a charm you have already packed:

```
CHARM_PATH=$(ls nftables-operator_*.charm) pytest tests/integration
```

### Running in a disposable VM (keeps the host clean)

To avoid installing juju, charmcraft, and a Juju controller on your host, run
the whole suite inside a throwaway LXD virtual machine. The host only needs LXD;
the VM gets everything else and is deleted afterwards. A VM (not a container) is
used so it has its own kernel and nftables behaves exactly as on a real host.
This needs hardware virtualization (`/dev/kvm`):

```
tests/integration_in_vm.sh                  # provision a VM, run tests, delete it
tests/integration_in_vm.sh -k firewall      # extra args pass through to pytest
KEEP=1 tests/integration_in_vm.sh           # leave the VM up for debugging
```

Resources and channels are overridable via environment variables (`CPU`,
`MEMORY`, `DISK`, `IMAGE`, `JUJU_CHANNEL`, `CHARMCRAFT_CHANNEL`, `SANDBOX`).

## Deploying a local build

```
juju deploy ./nftables-operator_*.charm
juju integrate nftables-operator ubuntu
```

Update an existing deployment:

```
juju refresh nftables-operator --path ./nftables-operator_*.charm
```
