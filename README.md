# damanfi/copy-bond

Vanilla reference implementation of `IDamanCopyBond`. Slash-bond state machine for copy-trading on Daman.

## What's here

`src/DamanCopyBond.sol` implements the full lifecycle: leader registration, bond posting, follower subscription, on-platform trade and settlement recording (per ADR-001), degradation claims, dispute window, arbiter rulings with the 25% per-dispute slash cap, lockup-gated bond withdrawal.

`src/IERC20.sol` is the minimal token surface used for USDC.

`test/DamanCopyBond.t.sol` covers 18 cases: tier math, oracle access, asset eligibility, short-blocking, dispute window, slash cap enforcement, treasury routing, lockup gating.

## Substrate

`refundProtocol` is recorded at construction as the address of the deployed `IRefundProtocol`-conformant dispute primitive at `github.com/reverbprotocol/protocol`. The bond itself is held inside this contract for clarity; the substrate address is preserved on chain so downstream consumers can observe the lineage. Richer deployments may route follower-side capital flows through the refund protocol.

## ADR-001

`recordTrade` and `recordSettlement` are callable only by the configured `oracle` address. The oracle reads on-platform events from this contract's own emissions. No off-platform leaderboards, no third-party performance feeds.

`recordTrade` rejects shorts (`ShortNotPermitted`) and assets not on the configured `IUniverseWhitelist` (`AssetNotEligible`). These two gates are the structural-cleanliness guarantee: a deployment cannot record a haram trade through the operator-side oracle by construction.

## Build

```
git clone https://github.com/damanfi/copy-bond.git
cd copy-bond
forge install foundry-rs/forge-std
git clone --depth 1 https://github.com/damanfi/protocol.git lib/damanfi-protocol
git clone --depth 1 https://github.com/reverbprotocol/protocol.git lib/reverbprotocol-protocol
forge build
forge test -vv
```

## Deploy

```
forge create \
  --rpc-url arc_testnet \
  --private-key $PRIVATE_KEY \
  src/DamanCopyBond.sol:DamanCopyBond \
  --constructor-args \
    $USDC_ADDR $UNIVERSE_ADDR $REFUND_PROTOCOL_ADDR \
    $ARBITER_ADDR $ORACLE_ADDR $TREASURY_ADDR \
    604800 86400
```

The two trailing constants are `bondLockupSeconds` (7 days) and `disputeWindowSeconds` (1 day).

## License

Apache-2.0.
