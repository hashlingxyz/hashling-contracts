# Security

Hashling's current launch path on Robinhood Chain (chain 4663) is Factory V2,
its dedicated migrator and its permanent position locker. The repository also
contains the legacy V1 factory and the separate HashlingSwap V3 trading wrapper.

The deployed contracts are source-verified, immutable and have no owner, pause
or upgrade path.

| Component | Address | What it holds |
|---|---|---|
| Factory V2 | [`0xC73A79A974fD175927b6b87C86d57081c9d2F3C9`](https://robinhoodchain.blockscout.com/address/0xC73A79A974fD175927b6b87C86d57081c9d2F3C9) | Curve ETH reserves and unsold token supply until graduation or refund |
| V2 Migrator | [`0x9E662756265425e9DF57BDE7957C0cA0200c10FB`](https://robinhoodchain.blockscout.com/address/0x9E662756265425e9DF57BDE7957C0cA0200c10FB) | Migration assets only while a graduation call executes |
| V2 Position Locker | [`0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa`](https://robinhoodchain.blockscout.com/address/0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa) | Graduated Uniswap V3 position NFTs permanently; collected fees until claimed |
| HashlingSwap | [`0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1`](https://robinhoodchain.blockscout.com/address/0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1) | Nothing between transactions |
| Legacy V1 Factory | [`0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523`](https://robinhoodchain.blockscout.com/address/0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523) | Curve reserves for legacy V1 launches |

Protocol fee recipient:
`0x80eFCeD0d87469dCD4477064eF937d14c07D3d99` (fixed at deployment).

## Status

- **Not independently audited.** Treat the contracts as unaudited and size
  transactions accordingly.
- Compiler: solc 0.8.35, optimizer 200 runs, Osaka EVM target.
- OpenZeppelin dependency is pinned in `foundry.lock`.
- The test suite covers unit, property, invariant, drift and mainnet-fork paths.

## Factory V2 safety properties

- Fixed token supply is minted once at launch; there is no later mint path.
- Curve reserves leave only through successful sells, graduation migration or
  the seven-day refund fallback.
- Trading fees are split 80% to the token creator and 20% to the fixed protocol
  recipient.
- A blocked migration can be switched permissionlessly after the delay; no
  privileged keeper is required.
- Refund claims never expire and there is no sweep or recovery path for
  unclaimed refund reserves.
- The migrator uses the pinned Uniswap V3 1% fee tier and validates the pool
  before committing migration assets.
- Graduated position NFTs are minted directly to the locker. The locker has no
  transfer, decrease-liquidity, rescue or administrative withdrawal path.
- Locker fee claims are split 80/20 between creator and protocol.

## HashlingSwap safety properties

- The fee is exactly `amount * feeBps / 10_000`, paid to the fixed recipient.
- ETH out cannot exceed ETH in minus the fee.
- Contract ETH, WETH and token balances are zero after successful calls.
- Token allowance to the router is reset to zero after every sell.
- Sell slippage is checked on ETH after the fee.
- Reentrancy is blocked and direct ETH transfers are refused.

HashlingSwap supports Uniswap V3 only. Graduated Flap V2 pool support is not
part of this deployment and would require a separate contract.

## What can go wrong

- **Smart-contract risk.** Source verification and tests are not an independent
  audit. An undiscovered implementation or integration defect can still exist.
- **Pool risk.** Thin or manipulated pools can move sharply. Front-end
  simulation and slippage limits reduce accidental execution but do not remove
  market risk.
- **Token risk.** Fee-on-transfer, rebasing, blacklisting or non-standard tokens
  can revert or return less than expected.
- **External-protocol risk.** Graduation and pool trades depend on Uniswap V3
  contracts and Robinhood Chain execution.
- **Front-end risk.** Always verify the wallet transaction's destination against
  [DEPLOYMENTS.md](DEPLOYMENTS.md). A project listing is not an endorsement.

## Reporting

Email `support@hashling.xyz` with `SECURITY` in the subject. Please allow a
reasonable remediation window before public disclosure. Real findings may be
rewarded at Hashling's discretion; there is no formal bounty programme.
