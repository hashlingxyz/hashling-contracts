# Security

Hashling's current launch path on Robinhood Chain (chain 4663) is Factory V2,
its dedicated migrator and its permanent position locker. The repository also
contains the legacy V1 factory and separate HashlingSwap V3 and HashlingV2Swap
V2 trading wrappers.

Production components and their on-chain roles are listed below.

| Component | Address | What it holds |
|---|---|---|
| Factory V2 | [`0xC73A79A974fD175927b6b87C86d57081c9d2F3C9`](https://robinhoodchain.blockscout.com/address/0xC73A79A974fD175927b6b87C86d57081c9d2F3C9) | Curve ETH reserves and unsold token supply until graduation or refund |
| V2 Migrator | [`0x9E662756265425e9DF57BDE7957C0cA0200c10FB`](https://robinhoodchain.blockscout.com/address/0x9E662756265425e9DF57BDE7957C0cA0200c10FB) | Migration assets only while a graduation call executes |
| V2 Position Locker | [`0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa`](https://robinhoodchain.blockscout.com/address/0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa) | Graduated Uniswap V3 position NFTs permanently; collected fees until claimed |
| HashlingSwap | [`0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1`](https://robinhoodchain.blockscout.com/address/0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1) | Nothing between transactions |
| HashlingV2Swap | [`0x84a7280190012DF7C03B1a137890ff27a1dF9bbB`](https://robinhoodchain.blockscout.com/address/0x84a7280190012DF7C03B1a137890ff27a1dF9bbB) | Nothing introduced by a normal trade remains after that transaction |
| Legacy V1 Factory | [`0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523`](https://robinhoodchain.blockscout.com/address/0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523) | Curve reserves for legacy V1 launches |

Protocol fee recipient:
`0x80eFCeD0d87469dCD4477064eF937d14c07D3d99` (fixed at deployment).

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

The release also completed clean and adversarial testnet canaries and a full
mainnet launch, graduation, locked-liquidity and post-graduation trade canary.

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

## HashlingV2Swap safety properties

- Router02 and the fixed fee recipient are constructor immutables. The factory
  and WETH are read from Router02 during construction and stored immutably.
- Every trade requires the router factory's canonical token/WETH pair to exist.
- Buys take 1% from ETH input, route pair output directly to the buyer and check
  slippage on the buyer's actual balance increase after token mechanics.
- Sells measure the tokens actually received, take 1% from gross ETH output,
  check slippage after that fee and reset the Router02 allowance to zero.
- A normal trade leaves no new ETH or token residue. Direct ETH is refused and
  router ETH is accepted only while a sell is executing.
- Reentrancy is blocked. A fee-recipient refusal or any residue mismatch reverts
  the whole transaction.
- The mandatory mainnet-fork suite proves parity with direct Portal execution
  for both tested graduated Flap token generations; an unset `FORK_RPC` fails.

`HashlingSwap` supports Uniswap V3 only. `HashlingV2Swap` is a separate,
venue-generic execution layer for canonical WETH-paired Uniswap V2 pools. It
checks pair existence, not Flap lifecycle status. Hashling's Flap adapter
separately requires Portal status `4` and exact equality between the
Portal-reported pool and the router factory's pair before exposing the V2 route.
Direct callers must perform their own lifecycle and venue checks.

## General caution

Digital-asset and smart-contract transactions can lose value or fail because
of contract, token, liquidity, network or external-protocol behavior. Review
the wallet transaction before signing and confirm its destination against
[DEPLOYMENTS.md](DEPLOYMENTS.md).

## Reporting

Email `support@hashling.xyz` with `SECURITY` in the subject. Please allow a
reasonable remediation window before public disclosure. Include the affected
contract, relevant transaction hashes, reproduction steps and expected impact.
