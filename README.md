# nftables-operator

## Description

`nftables-operator` is a subordinate charm that applies an operator-provided
nftables ruleset to every machine it is deployed to. It can be related to any
principal application using the `juju-info` interface.

The charm does exactly one thing: it takes the ruleset from the `rules` config
option, validates it with `nft -c`, writes it verbatim to `/etc/nftables.conf`,
and applies it with `nft -f`. Persistence across reboots is provided by the
packaged `nftables.service`, which loads `/etc/nftables.conf` at boot.

The charm owns `/etc/nftables.conf`; deploy it only on machines where you want
this charm to be the single manager of nftables.

## Usage

Deploy the charm and relate it to a principal application:

```
juju deploy ./nftables-operator_*.charm
juju integrate nftables-operator ubuntu
```

Until it is configured, the charm reports `blocked` with `no rules configured`.
Provide a ruleset to activate it. The ruleset must be a complete, self-contained
nftables script. Begin it with `flush ruleset` so that re-applying it is
idempotent (exactly like the stock `/etc/nftables.conf`):

```
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    tcp dport 22 accept
  }
}
```

```
juju config nftables-operator rules=@rules.nft
```

The charm applies the rules and reports `active`. To change the firewall, update
the config again; the new ruleset replaces the old one (this is why the ruleset
must start with `flush ruleset`).

If the ruleset is invalid, the charm reports `blocked` with `invalid rules: ...`
and leaves both `/etc/nftables.conf` and the running firewall untouched.

## Lifecycle

The charm manages nftables only while it is deployed; it does not try to rewind
the machine to its pre-charm state. This keeps behaviour predictable and, for a
firewall, fail-closed: rules stay in force until a human deliberately changes
them.

The charm re-checks its state periodically (on Juju's `update-status` hook) and
re-applies the rules only when the desired ruleset differs from what is already
in `/etc/nftables.conf`. When they match it does nothing, so the live ruleset
(and any runtime state such as dynamic sets and counters) is left alone.

- Clearing the config (`juju config nftables-operator rules=""`) returns the
  unit to `blocked` and leaves the last-applied ruleset in place.
- Removing the charm leaves the nftables package installed and the last-applied
  ruleset in place. It does not flush the firewall or restore any prior
  `/etc/nftables.conf`. If you want a clean firewall afterwards, flush it
  yourself with `nft flush ruleset` (and edit `/etc/nftables.conf` so the change
  persists across reboot).

## Configuration

- `rules` (string, default `""`): a complete nftables ruleset written verbatim
  to `/etc/nftables.conf`. Must be self-contained and begin with
  `flush ruleset`.

## Actions

- `reapply`: force the configured ruleset to be re-validated and re-applied, even
  when `/etc/nftables.conf` already matches it. The periodic reconcile skips
  re-applying when the file is up to date, so it will not notice if the live
  ruleset was changed outside the charm (for example a manual `nft flush
  ruleset`). Run this action to restore the firewall in that case. Each unit
  manages its own machine, so target the affected unit (or every unit):

  ```
  juju run nftables-operator/0 reapply
  ```

  It fails if no rules are configured, or if the ruleset is invalid or cannot be
  applied.

## Relations

This charm can be related to any principal application using the `juju-info`
interface.

## Contributing

Please see `CONTRIBUTING.md` for developer guidance.
