# Deployments

Canonical Hashling contract addresses. Always verify the destination shown by
your wallet against this list.

## Robinhood Chain mainnet (chain 4663)

| Component | Address |
|---|---|
| Factory V2 | [`0xC73A79A974fD175927b6b87C86d57081c9d2F3C9`](https://robinhoodchain.blockscout.com/address/0xC73A79A974fD175927b6b87C86d57081c9d2F3C9) |
| V2 Migrator | [`0x9E662756265425e9DF57BDE7957C0cA0200c10FB`](https://robinhoodchain.blockscout.com/address/0x9E662756265425e9DF57BDE7957C0cA0200c10FB) |
| V2 Position Locker | [`0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa`](https://robinhoodchain.blockscout.com/address/0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa) |
| HashlingSwap (Uniswap V3 only) | [`0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1`](https://robinhoodchain.blockscout.com/address/0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1) |
| Legacy V1 Factory | [`0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523`](https://robinhoodchain.blockscout.com/address/0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523) |
| Protocol fee recipient | [`0x80eFCeD0d87469dCD4477064eF937d14c07D3d99`](https://robinhoodchain.blockscout.com/address/0x80eFCeD0d87469dCD4477064eF937d14c07D3d99) |

### Factory V2 fixed dependencies

| Dependency | Address |
|---|---|
| Uniswap V3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Wrapped native token (WETH) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

### Mainnet canary

The minimum-supply deployment used to prove the full Factory V2 graduation
path on mainnet:

| Item | Value |
|---|---|
| Token | [`0x55C7D0a677BB7Abd56bfcb843BcA3E2Fe4DC83Cc`](https://robinhoodchain.blockscout.com/address/0x55C7D0a677BB7Abd56bfcb843BcA3E2Fe4DC83Cc) |
| Pinned V3 pool | [`0xcf00180051f03A1B1d101115fD657d329bca1B11`](https://robinhoodchain.blockscout.com/address/0xcf00180051f03A1B1d101115fD657d329bca1B11) |
| Position ID | `758237` |

## Robinhood Chain testnet

| Component | Address |
|---|---|
| Factory V2 | `0xCf0188941c22E23014B9A0ad5209b50BfAb42C5d` |
| V2 Migrator | `0x5359015C56407cDE8F92cAe888d8b982254fB32C` |
| V2 Position Locker | `0x4528AA673F7123bA279A35DECA57A9c6198c1619` |

## Reproducibility

- Solidity: `0.8.35+commit.47b9dedd`
- Optimizer: enabled, 200 runs
- EVM target: Osaka
- OpenZeppelin revision: `cab19933c33c2ad1d4c7a84864a3601dddfd16f3`

This repository intentionally excludes deployment keys, environment files and
broadcast artifacts.
