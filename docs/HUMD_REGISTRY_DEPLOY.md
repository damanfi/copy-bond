# HumdRegistry deploy plan for the Daman subnet

The Daman hum subnet uses the vanilla `HumdRegistry` from `github.com/adiled/hum/contracts` as its immutable identity anchor. The registry is the trust root: it carries the public-key-to-manifest binding that the mesh's discovery layer reads. The contract is intentionally non-upgradeable.

## Why vanilla, not upgradeable

Per hum issue [#39](https://github.com/adiled/hum/issues/39), the maintainer reasoning is explicit: the identity layer's bytecode is the standard. Subnets that want to extend identity behavior (KYC attestation, multi-chain pubkey aliases, bond-staked status flags) compose sideways, not by upgrading the base registry.

Daman's `ReputationRegistry` and `BountyAccrual` (in `damanfi/copy-bond`) are sidecars in this pattern: they key off the same address space as `HumdRegistry` but store their own state separately and upgrade independently. The base registry never moves; sidecars iterate.

If future identity-adjacent state is needed, `DamanHumdAnnotations.sol` ships as a new sidecar in `damanfi/copy-bond/src/` (UUPS-upgradeable, full hardening discipline). Not in this deploy's scope.

## Deploy steps

1. Clone `github.com/adiled/hum` locally and pin to a release tag (current target: HEAD of `main`, recorded in the deployments file at deploy time).
2. Verify the bytecode of `lib/hum/contracts/src/HumdRegistry.sol` matches the upstream repo at the pinned ref. Diff vs upstream MUST be empty.
3. Deploy via `forge create` using the deployer EOA:

```bash
forge create --rpc-url arc_testnet \
  --private-key $PRIVATE_KEY \
  lib/hum/contracts/src/HumdRegistry.sol:HumdRegistry
```

4. Record the deployed address in `damanfi/copy-bond/.deployments/arc-testnet.json` under the `humdRegistry.address` field.
5. Set `HUMD_REGISTRY_ADDR` env in every bee's configuration so the bees register against this subnet's registry on first hello.
6. Update `damanfi/docs/README.md` with the deployed address in the substrate-consumption section.

The deploy is a single transaction. ~50k gas. Single-shot; no proxy, no Safe, no Timelock. The deployer EOA holds no special authority over the contract past the deploy (the contract has no admin functions).

## Verification

After deploy:

- The deployed bytecode hash matches the hash of the upstream `HumdRegistry.sol` source compiled with the same Solidity version.
- A test `advertise()` from the deployer EOA succeeds and emits the `Advertised` event.
- A test `get(pubkey)` for the deployer's published pubkey returns the expected record.

If any check fails, the deploy is rolled back (re-deploy fresh; the broken instance stays live but is ignored by reading the new address from the deployments file).
