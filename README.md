# Hashling contracts

Smart contracts behind [hashling.xyz](https://hashling.xyz), the token launchpad
and trading front end for Robinhood Chain (chain 4663). This repository holds
the exact sources that are verified on Blockscout, plus their tests.

| Contract | Address | Role |
|---|---|---|
| `HashlingFactory` | [`0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523`](https://robinhoodchain.blockscout.com/address/0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523) | Bonding-curve launchpad: `launch`, `buy`, `sell`, creator fee claims |
| `HashlingToken` | deployed per launch by the factory | Plain ERC-20 minted by the factory; no owner, no mint after launch |
| `HashlingSwap` | [`0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1`](https://robinhoodchain.blockscout.com/address/0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1) | 1% fee wrapper over Uniswap v3 SwapRouter02: `buy` (ETH → token), `sell` (token → ETH) |

All contracts are immutable: no owner, no pause, no upgrade path. HashlingSwap
holds nothing between transactions. Fee recipient for both is fixed at deploy.
See [SECURITY.md](SECURITY.md) for the threat model, tested invariants and how
to report a finding.

## Layout

```
src/   HashlingFactory.sol  HashlingToken.sol  HashlingSwap.sol
test/  Curve.properties.t.sol   property tests, 5,000 fuzz runs each
       Curve.invariants.t.sol   invariant suites, 512 runs x depth 100
       Swap.properties.t.sol    fee, balance, reentrancy and slippage properties
       Swap.fork.t.sol          mainnet fork: real buy and sell through the real router
lib/   forge-std, openzeppelin-contracts (vendored, unmodified)
```

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```shell
forge build
forge test --no-match-path "test/Swap.fork.t.sol"     # unit, fuzz, invariants
FORK_RPC=<robinhood chain rpc> forge test --match-path "test/Swap.fork.t.sol"
```

Compiler: solc 0.8.35, no assembly. Verify against Blockscout with
`forge verify-contract --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api`.

## Status

Immutable, source-verified, covered by property, invariant and fork tests (`test/`). No independent audit yet.

## License

MIT
