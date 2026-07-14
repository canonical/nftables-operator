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

Integration tests deploy the packed charm onto an `ubuntu` principal on LXD and
assert on the live nftables ruleset. They require a bootstrapped Juju controller:

```
sudo snap install juju --channel 3.6/stable
lxd init --auto
juju bootstrap localhost lxd-test
CHARM_PATH=$(ls nftables-operator_*.charm) pytest tests/integration
```

## Deploying a local build

```
juju deploy ./nftables-operator_*.charm
juju integrate nftables-operator ubuntu
```

Update an existing deployment:

```
juju refresh nftables-operator --path ./nftables-operator_*.charm
```
