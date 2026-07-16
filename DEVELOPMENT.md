# nftables-operator

## Developing

Create a virtualenv and install the development dependencies:

```
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
```

Dependencies are recorded in `pyproject.toml` and pinned in `uv.lock`. After
changing any dependency, regenerate the lock file with `uv lock` and commit it.
The `dev` extra is locked but never shipped in the charm (see Building).

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

This charm builds with charmcraft 3 using the `uv` plugin, which installs the
runtime dependencies from `pyproject.toml` + `uv.lock` (without the `dev` extra,
so only `ops` and its dependencies ship in the charm):

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

The tests deploy on `ubuntu@24.04` by default. Set `TEST_BASE` to test another
supported base (CI runs one job per base):

```
TEST_BASE=ubuntu@26.04 tests/integration_on_host.sh
```

Equivalently, run pytest directly against charms you have already packed
(`charmcraft pack` emits one file per base; the tests pick the matching one).
`CHARM_PATH` is the directory to search, or a specific `.charm` file:

```
CHARM_PATH=$(pwd) pytest tests/integration
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
REBUILD_IMAGE=1 tests/integration_in_vm.sh  # rebuild the cached base image
```

Everything runs in a dedicated LXD project, `charm-integration-tests`. The first
run provisions the VM (snaps + `juju bootstrap`) and publishes it as a cached
image; later runs launch from that image, skipping the slow setup. The cached
image and project persist between runs; use `REBUILD_IMAGE=1` to refresh them
(for example after a juju/charmcraft channel bump).

Resources, channels, and names are overridable via environment variables (`CPU`,
`MEMORY`, `DISK`, `IMAGE`, `JUJU_CHANNEL`, `CHARMCRAFT_CHANNEL`, `SANDBOX`,
`PROJECT`, `CACHE_ALIAS`).

## Deploying a local build

```
juju deploy ./nftables-operator_*.charm
juju integrate nftables-operator ubuntu
```

Update an existing deployment:

```
juju refresh nftables-operator --path ./nftables-operator_*.charm
```
