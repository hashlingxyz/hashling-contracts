# Hashling contracts

Smart contracts behind [hashling.xyz](https://hashling.xyz), the token launchpad
and trading front end for Robinhood Chain (chain 4663). This repository contains
the exact public sources used for the production deployments, plus their Foundry
tests.

## Deployed contracts

| Contract | Address | Role |
|---|---|---|
| `HashlingFactoryV2` | [`0xC73A79A974fD175927b6b87C86d57081c9d2F3C9`](https://robinhoodchain.blockscout.com/address/0xC73A79A974fD175927b6b87C86d57081c9d2F3C9) | Current launchpad: fixed-supply token launch, bonding-curve trading, automatic V3 graduation and delayed refund fallback |
| `HashlingTokenV2` | deployed per launch by Factory V2 | Fixed-supply ERC-20 created for each launch |
| `HashlingMigrator` | [`0x9E662756265425e9DF57BDE7957C0cA0200c10FB`](https://robinhoodchain.blockscout.com/address/0x9E662756265425e9DF57BDE7957C0cA0200c10FB) | Prepares and validates the graduation pool, then mints its V3 position directly to the locker |
| `HashlingPositionLocker` | [`0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa`](https://robinhoodchain.blockscout.com/address/0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa) | Permanently holds graduated V3 position NFTs and distributes collected fees 80/20 to creator/protocol |
| `HashlingSwap` | [`0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1`](https://robinhoodchain.blockscout.com/address/0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1) | Separate 1% fee wrapper over Uniswap V3 SwapRouter02 |
| `HashlingV2Swap` | [`0x84a7280190012DF7C03B1a137890ff27a1dF9bbB`](https://robinhoodchain.blockscout.com/address/0x84a7280190012DF7C03B1a137890ff27a1dF9bbB) | Separate 1% fee wrapper over canonical WETH-paired Uniswap V2 pools; first exposed for verified graduated Flap tokens |
| `HashlingFactory` | [`0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523`](https://robinhoodchain.blockscout.com/address/0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523) | Legacy V1 bonding-curve factory |

Factory V2 runs new Hashling launches and V3 graduation. `HashlingSwap` provides
the V3 execution route, while `HashlingV2Swap` provides the separate canonical
V2 execution route first exposed for graduated Flap pools.

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
       HashlingV2Swap.sol            separate V2 trading wrapper
       interfaces/IHashlingV3.sol    shared V3 component interfaces
test/  FactoryV2.*.t.sol             unit, property, invariant, drift and fork tests
       Curve.*.t.sol                 legacy V1 property and invariant tests
       Swap.*.t.sol                  V3 wrapper property and fork tests
       V2Swap.*.t.sol                V2 wrapper property and Flap parity fork tests
lib/   forge-std, openzeppelin-contracts (vendored)
```

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```shell
forge build
forge test --no-match-path "test/*.fork.t.sol"
FORK_RPC=<robinhood-chain-rpc> forge test --match-path "test/FactoryV2.fork.t.sol"
FORK_RPC=<robinhood-chain-rpc> forge test --match-path "test/Swap.fork.t.sol"
FORK_RPC=<robinhood-chain-rpc> forge test --match-path "test/V2Swap.fork.t.sol"
```

Compiler: solc 0.8.35, optimizer 200 runs, Osaka EVM target. Verify against
Blockscout with `forge verify-contract --verifier blockscout --verifier-url
https://robinhoodchain.blockscout.com/api`.

## Validation benchmarks

| Validation | Recorded result |
|---|---|
| Factory V2 optimized release suite | 59 / 59 passed |
| Fuzz configuration | 5,000 runs per fuzz property |
| Invariant configuration | 512 runs × depth 100 |
| Real Robinhood Chain V3 lifecycle fork | Passed |
| Maximum observed closing-price drift | 1 PPB — 0.01% of tolerance |
| HashlingV2Swap property and unit suite | 8 / 8 passed |
| HashlingV2Swap live-fork parity | 2 / 2 tested token generations passed |
| Release canaries | Two testnet canaries and one complete mainnet lifecycle |

## License

MIT
