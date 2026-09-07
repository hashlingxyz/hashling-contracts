# Deployments

Canonical Hashling contract addresses. Always verify the destination shown by
your wallet against this list.

## Robinhood Chain mainnet (chain 4663)

| Component | Address |
|---|---|
| Factory V2 | [`0xC73A79A974fD175927b6b87C86d57081c9d2F3C9`](https://robinhoodchain.blockscout.com/address/0xC73A79A974fD175927b6b87C86d57081c9d2F3C9) |
| Direct V3 Launcher | [`0x4DF37b5A9205382C468bC523D3F2b89e1886D1ff`](https://robinhoodchain.blockscout.com/address/0x4DF37b5A9205382C468bC523D3F2b89e1886D1ff) |
| Direct V3 Position Locker | [`0xA2D7348B57527fC136e102F27625D15935a9Ad5a`](https://robinhoodchain.blockscout.com/address/0xA2D7348B57527fC136e102F27625D15935a9Ad5a) |
| HashlingSwap (Direct V3, zero wrapper fee) | [`0xA9DF8975940Dbb2B5A10A85D91B10c02649DAE92`](https://robinhoodchain.blockscout.com/address/0xA9DF8975940Dbb2B5A10A85D91B10c02649DAE92) |
| V2 Migrator | [`0x9E662756265425e9DF57BDE7957C0cA0200c10FB`](https://robinhoodchain.blockscout.com/address/0x9E662756265425e9DF57BDE7957C0cA0200c10FB) |
| V2 Position Locker | [`0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa`](https://robinhoodchain.blockscout.com/address/0x3b8f634b1773D7F7A5fff91AAfFf3e4928Be50fa) |
| HashlingSwap (Uniswap V3 only) | [`0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1`](https://robinhoodchain.blockscout.com/address/0x16Bc3720C90c3d5b5B99acf2Df746bAC03Cb53a1) |
| HashlingV2Swap (Uniswap V2) | [`0x84a7280190012DF7C03B1a137890ff27a1dF9bbB`](https://robinhoodchain.blockscout.com/address/0x84a7280190012DF7C03B1a137890ff27a1dF9bbB) |
| Legacy V1 Factory | [`0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523`](https://robinhoodchain.blockscout.com/address/0x3b38c6Fa9Cc41d3A20d64111325231E7dEF7D523) |
| Protocol fee recipient | [`0x80eFCeD0d87469dCD4477064eF937d14c07D3d99`](https://robinhoodchain.blockscout.com/address/0x80eFCeD0d87469dCD4477064eF937d14c07D3d99) |

### Factory V2 fixed dependencies

| Dependency | Address |
|---|---|
| Uniswap V3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Wrapped native token (WETH) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

### Direct V3 fixed configuration

| Deployment | Transaction |
|---|---|
| Position Locker | [`0xc880bb9cdb6ad4a1ede47bb7999167fd2b858f05be2b864e561a97c125c5c819`](https://robinhoodchain.blockscout.com/tx/0xc880bb9cdb6ad4a1ede47bb7999167fd2b858f05be2b864e561a97c125c5c819) |
| Direct V3 Launcher | [`0xedb6d6213188a5b010c354a36e060d016567e706de761399e0dca0a66bb0fbf6`](https://robinhoodchain.blockscout.com/tx/0xedb6d6213188a5b010c354a36e060d016567e706de761399e0dca0a66bb0fbf6) |
| Zero-fee HashlingSwap | [`0x63b2250cdc5510735609d91faa5b3a1521a8abebf1816e0a3900847de628efb5`](https://robinhoodchain.blockscout.com/tx/0x63b2250cdc5510735609d91faa5b3a1521a8abebf1816e0a3900847de628efb5) |

| Item | Value |
|---|---|
| Uniswap V3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Wrapped native token (WETH) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Fixed token supply | `1,000,000,000` |
| Starting fully diluted value | `3.5125 ETH` |
| Minimum creator buy | `0.001 ETH`, exchanged for tokens |
| Uniswap pool fee | `10,000` fee units (1%) |
| Hashling wrapper fee | `0` basis points |
| LP-fee distribution | 80% creator / 20% protocol |
| Position principal | Permanently locked |

### HashlingV2Swap fixed configuration

Deployed in transaction
[`0xa781adb1536cb115ee156f69837a4bfd79cdf6084dfc18f1c43e75461cb2ffb8`](https://robinhoodchain.blockscout.com/tx/0xa781adb1536cb115ee156f69837a4bfd79cdf6084dfc18f1c43e75461cb2ffb8).
The constructor fixes Router02, the protocol fee recipient and `100` fee basis
points. The wrapper reads the factory and WETH from Router02 during construction
and stores both immutably.

| Item | Value |
|---|---|
| Uniswap V2 Router02 | `0x89e5DB8B5aA49aA85AC63f691524311AEB649eba` |
| Canonical V2 factory | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |
| Wrapped native token (WETH) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Protocol fee | `100` basis points (1%) |

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
- Dependencies are vendored and therefore pinned by this repository commit.
- OpenZeppelin Contracts v5.7.0 upstream revision:
  `cab19933c33c2ad1d4c7a84864a3601dddfd16f3`
- Forge Std upstream revision:
  `f27ce82f8e8c3dd8122aab83f2344c1e8a757ebf`

This repository intentionally excludes deployment keys, environment files and
broadcast artifacts.
