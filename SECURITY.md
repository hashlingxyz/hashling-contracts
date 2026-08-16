# Security

Hashling runs two contracts on Robinhood Chain (chain 4663). Both are
source-verified on Blockscout, immutable, and hold no user funds between
transactions. Neither has an owner, a pause, or an upgrade path.

| Contract | Address | What it does | What it holds |
|---|---|---|---|
| HashlingFactory | [`0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523`](https://robinhoodchain.blockscout.com/address/0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523) | Bonding-curve launchpad: `launch`, `buy`, `sell`, creator fee claims | Curve reserves for its tokens (ETH and unsold supply). No admin can withdraw them. `graduate()` reverts until the migrator ships. |
| HashlingSwap | [`0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1`](https://robinhoodchain.blockscout.com/address/0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1) | 1% fee wrapper over Uniswap v3 SwapRouter02: `buy` (ETH → token), `sell` (token → ETH) | Nothing. ETH and tokens pass through inside one call; the contract's balance is zero after every call and it refuses direct ETH. |

Fee recipient for both: `0x80eFCeD0d87469dCD4477064eF937d14c07D3d99` (fixed at deploy).

## Status

- **Not yet audited.** An independent review is planned after HashlingSwap v2
  (multi-hop routing) lands. Until then, treat these as unaudited contracts and
  size trades accordingly.
- Tests (Foundry, `contracts/test/`): 15 property tests at 5,000 fuzz runs
  each, 4 invariant suites at 512 runs × depth 100, one mainnet fork test
  that buys and sells a real token through the real router.
- Compiler: solc 0.8.35, no assembly, OpenZeppelin `ReentrancyGuard` and
  `SafeERC20` only.

## Invariants we test

HashlingSwap
- ETH out ≤ ETH in minus the fee, on every path.
- Fee is exactly `amount * feeBps / 10_000`, paid to the fixed recipient.
- Contract ETH, WETH and token balances are zero after every call.
- Token allowance to the router is reset to zero after every sell.
- Sell slippage (`minOut`) is checked on ETH *after* the fee.
- Reentrancy is blocked; a fee recipient that refuses ETH reverts the trade
  rather than stranding funds; direct ETH transfers are refused.

HashlingFactory
- Reserve conservation: curve ETH equals sum of buys minus sells minus fees.
- No path moves reserves except `sell` and (once enabled) `graduate`.
- Fee split is 80/20 creator/protocol, computed on trade value.

## What can go wrong

- **Uniswap pool risk.** HashlingSwap forwards to a Uniswap v3 pool chosen by
  the front end (deepest liquidity for the token). Thin pools move a lot on
  small orders; the front end simulates first and applies a 5% slippage cap,
  but price impact is real and is the user's.
- **Token risk.** Fee-on-transfer, blacklisting or rebasing tokens can make a
  `sell` revert or return less than quoted. The simulation catches reverts
  before a wallet prompt; it cannot make a bad token good.
- **Front-end risk.** The site is static and open; the contract does exactly
  what the wallet confirmation shows. Verify the `to` address in your wallet:
  it should be one of the two contracts above (or, for hood.fun curve tokens,
  hood.fun's verified factory).

## Reporting

Email `support@hashling.xyz` with "SECURITY" in the subject. Please give us a
reasonable window before public disclosure. Real findings are paid at our
discretion in ETH; there is no formal bounty programme yet.
