# nftables-operator

## Developing

Create a virtualenv and install the development dependencies:

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
```

Dependencies are recorded in `pyproject.toml` and pinned in `uv.lock`. After
changing any dependency, regenerate the lock file with `uv lock` and commit it.
The `dev` extra is locked but never shipped in the charm (see Building).

## Linting and unit tests

```sh
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

```sh
sudo snap install charmcraft --channel 3.x/stable --classic
charmcraft pack
```

## Integration tests

Integration tests deploy the packed charm onto `ubuntu` machines on LXD. One
test checks the live nftables ruleset. The other drives a three-machine,
"blackbox" scenario to ensure firewall rules work as expected.

The integration tests can be run against a local Juju controller + LXD
installation or within a temporary LXD VM.

### Running on a locally-available Juju controller

First, run the following commands:

```sh
sudo snap install juju --channel 3.6/stable
lxd init --auto
juju bootstrap localhost lxd-test
```

Then, use the helper script. With no subcommand, it packs the charm (reusing an
existing artifact unless `--repack` is passed) and runs the test suite; extra
arguments pass through to pytest, and `--base`/`--channel` choose the base and
charm source:

```sh
tests/integration_on_host.sh                          # run all integration tests
tests/integration_on_host.sh -k firewall              # run a subset
tests/integration_on_host.sh --repack                 # force a fresh pack first
tests/integration_on_host.sh --base ubuntu@26.04      # deploy on another base
tests/integration_on_host.sh --channel latest/edge    # the published charm (no pack)
```

Or run pytest directly against charms you have already packed (`charmcraft pack`
emits one file per base; the tests pick the matching one). `CHARM_PATH` is the
directory to search, or a specific `.charm` file; `TEST_BASE`/`CHARM_CHANNEL`
are the environment-variable equivalents of `--base`/`--channel`:

```sh
CHARM_PATH=$(pwd) pytest tests/integration
```

### Standing up the black-box environment for manual testing

The same helper builds the three-machine black-box environment (server plus
allowed and blocked clients, with the firewall applied) in a persistent model
and leaves it running, then tears it down again. `--base`/`--channel` work as
above:

```sh
tests/integration_on_host.sh standup     # deploy and leave it running
tests/integration_on_host.sh teardown    # destroy it
```

`standup` prints the server IP and a ready-made `juju exec` probe. Under the
hood this runs `tests/integration/environment.py`, a plain (no pytest) script
you can also call directly (e.g.,
`environment.py standup --model NAME --channel latest/edge`). The model defaults
to `nftables-blackbox`; re-standing up requires a teardown first.

### Running in a disposable VM (keeps the host clean)

To avoid installing juju, charmcraft, and a Juju controller on your host, run
the whole suite inside a throwaway LXD virtual machine. The host only needs LXD;
the VM gets everything else and is deleted afterwards. A VM (not a container) is
used so it has its own kernel and nftables behaves exactly as on a real host.
This needs hardware virtualization (`/dev/kvm`):

It mirrors the on-host actions (`test`, `standup`, `teardown`), each running
inside the VM; the VM stays up between them:

```sh
tests/integration_in_vm.sh                   # one-shot: provision, run tests, delete
tests/integration_in_vm.sh test -k firewall  # run a subset (VM stays up)
tests/integration_in_vm.sh standup           # stand up the black-box env in the VM
tests/integration_in_vm.sh shell             # shell in as 'ubuntu'
tests/integration_in_vm.sh teardown          # tear the env down
tests/integration_in_vm.sh down              # delete the VM
```

The same `--base`/`--channel`/`--repack` options apply (forwarded into the VM),
so e.g. to test the published charm on another base:

```sh
tests/integration_in_vm.sh test --channel latest/edge --base ubuntu@26.04
```

Other flags: `--keep` (leave the VM up after a one-shot run), `--rebuild-image`
(rebuild the cached base image), and `--purge` (with `down`, also remove the
cached image and project). Run `tests/integration_in_vm.sh --help` for the full
list.

Everything runs in a dedicated LXD project, `charm-integration-tests`. The first
run provisions the VM (snaps + `juju bootstrap`) and publishes it as a cached
image; later runs launch from that image, skipping the slow setup. The cached
image and project persist between runs; use `--rebuild-image` to refresh them
(for example after a juju/charmcraft channel bump) and `down --purge` to remove
them entirely.

Advanced tuning (rarely needed) stays on environment variables: `CPU`, `MEMORY`,
`DISK`, `IMAGE`, `JUJU_CHANNEL`, `CHARMCRAFT_CHANNEL`, `SANDBOX`, `PROJECT`,
`CACHE_ALIAS`.

## Deploying a local build

```sh
juju deploy ./nftables-operator_*.charm
juju integrate nftables-operator ubuntu
```

Update an existing deployment:

```sh
juju refresh nftables-operator --path ./nftables-operator_*.charm
```
