# UPGRADE_AUTHORITY

Who controls upgrades to the Daman contract surface, and how.

## Surface controlled

Every Daman contract deployed via UUPS proxy:

- `DamanCopyBond` (`damanfi/copy-bond/src/DamanCopyBond.sol`)
- `DamanBountyAccrual` (`damanfi/copy-bond/src/DamanBountyAccrual.sol`)
- `DamanReputationRegistry` (`damanfi/copy-bond/src/DamanReputationRegistry.sol`)
- `DamanBondYieldVault` (`damanfi/copy-bond/src/DamanBondYieldVault.sol`)
- `UniverseRegistry` (`damanfi/universe/src/UniverseRegistry.sol`)

Each proxy's `owner()` returns the address of the deployment's `TimelockController`. `_authorizeUpgrade(address)` is `onlyOwner`. The deployer EOA holds no upgrade authority past the initial deploy script.

## Two-layer authority

**Layer 1: Safe multisig (3-of-5)**

The Safe at the `safe.address` field of `.deployments/arc-testnet.json` is the only proposer + executor on every TimelockController. Two independent Safes for blast-radius containment:

- Daman-side Safe: controls upgrades to `DamanCopyBond`, `DamanBountyAccrual`, `DamanReputationRegistry`, `DamanBondYieldVault`.
- Universe-side Safe: controls upgrades to `UniverseRegistry`.

Threshold: 3-of-5 minimum. Signers documented out-of-band; the `signers` array in each deployments file lists their EVM addresses.

**Layer 2: TimelockController**

The TimelockController enforces an upgrade delay:

- Testnet: 24 hours (86400 seconds).
- Mainnet: 72 hours (259200 seconds).

During the delay, the queued upgrade is visible on-chain. Any bee in the mesh, any storefront, any third-party indexer can inspect the pending `newImpl` bytecode. If the upgrade is determined to be malicious or wrong, the Safe can call `cancel(operationId)` during the delay window.

## Upgrade flow

1. Daman or upstream library audit identifies a needed change.
2. New implementation contract written, reviewed, tested (`forge test`, `forge test --match-contract SelectorFreeze`, slither high-severity zero, storage-layout validation against the deployed proxy).
3. Implementation deployed via `forge create` (no proxy; this is the bare implementation). Address recorded.
4. Safe signers compose an `upgradeToAndCall(newImpl, data)` call against the target proxy.
5. Safe submits this as `schedule(target, value, data, predecessor, salt, delay)` on the TimelockController. Delay starts.
6. During the delay, a public PR opens against the relevant repo with the diff of the deployments file and a link to the queued operation on the explorer.
7. After the delay elapses, any 3-of-5 Safe signers execute the upgrade via `execute(...)` on the TimelockController.
8. Post-upgrade: storage-layout validation + selector freeze test rerun against the new implementation. If either fails, the Safe immediately calls `pause()` and a follow-on upgrade reverts the change.

## Pause authority

Pause is the emergency stop. It runs without the TimelockController delay (the Safe calls `pause()` directly through the Timelock with `schedule + execute` at `delay = 0`, or via a separate fast-path role if configured).

Unpause runs through the full Safe + Timelock delay so the unpause itself is auditable.

The pause + unpause cadence is documented in the architecture notes. Functions that pause-gate vs functions that stay open during pause are listed there per contract.

## Signer roster placeholders

The deployments file at `.deployments/arc-testnet.json` carries five zero-address placeholders for the Safe signers. Before the deploy script runs:

1. Safe multisig is provisioned out-of-band via the Safe CLI or web app with the actual five EVM addresses (operator-controlled keys, hardware-wallet or HSM-managed).
2. Safe address is set in `SAFE_ADDRESS` env for the deploy script.
3. The `signers` array in the deployments file is updated post-deploy with the actual addresses.

Hardware-wallet or HSM-managed signing for the operator side is operator's choice; the contract surface treats every signer as equivalent.

## Independent Safes

The two Safes (Daman + Universe) share no signers by default. Operator choice on whether to overlap the rosters: overlap saves coordination cost; independence ensures a compromised Daman Safe cannot upgrade the universe registry and vice versa. Document any overlap decision in this file.

## Audit trail

Every upgrade lands as:

- A git commit on `main` of the affected repo with the new implementation source.
- A PR with the deployments file diff (new `implementation` address, bumped `version`).
- A `.game/play-012.md` entry per the project-reverb logging convention.
- An on-chain `Upgraded` event from the proxy, plus the Timelock's `CallExecuted` event.

The four artifacts together carry the audit trail; any one missing is grounds for the Safe to call `pause()` until the trail is reconstructed.
