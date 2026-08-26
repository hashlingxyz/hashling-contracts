# Hashling contracts

Smart contracts behind [hashling.xyz](https://hashling.xyz), the token launchpad
and trading front end for Robinhood Chain (chain 4663). This repository contains
the exact public sources used for the verified deployments, plus their Foundry
tests.

## Deployed contracts

| Contract | Address | Role |
|---|---|---|
| `HashlingFactoryV2` | [`0xC73A79A974fD175927b6b87C86d57081c9d2F3C9`](https://robinhoodchain.blockscout.com/address/0xC73A79A974fD175927b6b87C86d57081c9d2F3C9) | Current launchpad: fixed-supply token launch, bonding-curve trading, automatic V3 graduation and delayed refund fallback |
| `HashlingTokenV2` | deployed per launch by Factory V2 | Fixed-supply ERC-20; no owner and no mint after launch |
| `HashlingMigrator` | [`0x9E662756265425e9DF57BDE7957C0cA0200c10FB`](https://robinhoodchain.blockscout.com/address/0x9E662756265425e9DF57BDE7957C0cA0200c10FB) | Prepares and validates the graduation pool, then mints its V3 position directly to the locker |
| `HashlingPositionLocker` | [`0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa`](https://robinhoodchain.blockscout.com/address/0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa) | Permanently holds graduated V3 position NFTs and distributes collected fees 80/20 to creator/protocol |
| `HashlingSwap` | [`0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1`](https://robinhoodchain.blockscout.com/address/0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1) | Separate 1% fee wrapper over Uniswap V3 SwapRouter02 |
| `HashlingFactory` | [`0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523`](https://robinhoodchain.blockscout.com/address/0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523) | Legacy V1 bonding-curve factory |

The contracts have no owner, pause or upgrade path. Factory reserves and locked
liquidity cannot be removed by an administrator. HashlingSwap is V3-only; a
future graduated-Flap V2 wrapper would be a separate contract and deployment.

See [DEPLOYMENTS.md](DEPLOYMENTS.md) for the complete address record and
[SECURITY.md](SECURITY.md) for the threat model, tested invariants and reporting
instructions.

## Layout

```text
src/   HashlingFactory.sol           legacy V1 bonding-curve factory
       HashlingToken.sol             legacy V1 token
       HashlingFactoryV2.sol         current launchpad and lifecycle accounting
       HashlingTokenV2.sol           current fixed-supply token
       HashlingMigrator.sol          V3 pool preparation and migration
       HashlingPositionLocker.sol    permanent V3 position custody and fee claims
       HashlingSwap.sol              separate V3 trading wrapper
       interfaces/IHashlingV3.sol    shared V3 component interfaces
test/  FactoryV2.*.t.sol             unit, property, invariant, drift and fork tests
       Curve.*.t.sol                 legacy V1 property and invariant tests
       Swap.*.t.sol                  V3 wrapper property and fork tests
lib/   forge-std, openzeppelin-contracts (vendored)
```

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```shell
forge build
forge test
FORK_RPC=<robinhood-chain-rpc> forge test --match-path "test/FactoryV2.fork.t.sol"
FORK_RPC=<robinhood-chain-rpc> forge test --match-path "test/Swap.fork.t.sol"
```

Compiler: solc 0.8.35, optimizer 200 runs, Osaka EVM target. Verify against
Blockscout with `forge verify-contract --verifier blockscout --verifier-url
https://robinhoodchain.blockscout.com/api`.

## Status

Immutable, source-verified, and covered by unit, property, invariant, drift and
fork tests. No independent audit yet.

## License

MIT
