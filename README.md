# Aave Reserve Integrity Sentinel

> A production-grade Drosera Trap monitoring **Aave V3 protocol and reserve health** on Ethereum Mainnet. Detects utilization crises, liquidity collapses, borrow rate spikes, and reserve freezes across 6 key assets with automated on-chain response.

[![Mainnet](https://img.shields.io/badge/Network-Ethereum%20Mainnet-blue)](https://ethereum.org)
[![Drosera](https://img.shields.io/badge/Powered%20by-Drosera%20Network-orange)](https://drosera.io)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## Why Monitor Aave Reserves

Aave is one of the largest lending protocols on Ethereum with billions in TVL. Reserve health directly impacts:

- **Liquidity providers** — unable to withdraw if utilization hits 100%
- **Borrowers** — forced liquidation if rates spike dramatically
- **DeFi composability** — protocols using Aave as collateral layer are exposed

When a reserve's utilization approaches 100%, available liquidity collapses. Borrowers face extreme rates. Withdrawals become impossible. This trap fires **before** the situation becomes critical — giving protocols and users time to react.

---

## Deployed on Ethereum Mainnet

| Contract | Address | Status |
|----------|---------|--------|
| `AaveReserveSentinel` | [`0x829B37f0d2deec626C88d0Cace2A8F48C9F6B6af`](https://etherscan.io/address/0x829B37f0d2deec626C88d0Cace2A8F48C9F6B6af) | ✅ Active |
| `AaveReserveResponse` | [`0x5741040A5572F917DE324cD81D5f08C1eFaa5917`](https://etherscan.io/address/0x5741040A5572F917DE324cD81D5f08C1eFaa5917) | ✅ Active |

---

## Contracts Monitored

| Contract | Address |
|----------|---------|
| Aave V3 Pool | [`0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`](https://etherscan.io/address/0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2) |

### Key Assets Monitored

| Asset | Address |
|-------|---------|
| WETH | [`0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`](https://etherscan.io/address/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) |
| wstETH | [`0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`](https://etherscan.io/address/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0) |
| WBTC | [`0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`](https://etherscan.io/address/0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599) |
| USDC | [`0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`](https://etherscan.io/address/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) |
| USDT | [`0xdAC17F958D2ee523a2206206994597C13D831ec7`](https://etherscan.io/address/0xdAC17F958D2ee523a2206206994597C13D831ec7) |
| DAI | [`0x6B175474E89094C44Da98b954EedeAC495271d0F`](https://etherscan.io/address/0x6B175474E89094C44Da98b954EedeAC495271d0F) |

---

## Detection Logic

### Design Philosophy

All checks require **sustained** anomalies across 3 consecutive block samples before triggering. Transient state changes — from large deposits, flash loans, or MEV — will not fire the trap. The signal must persist across multiple blocks.

### Detection Layers

#### Protocol Level

| Check | ID | Trigger |
|-------|-----|---------|
| Protocol pause transition | 2 | Pool paused while previously active |

#### Reserve Level (per asset)

Each reserve uses a base ID + check type:
- Base: WETH=10, wstETH=20, WBTC=30, USDC=40, USDT=50, DAI=60
- +1 = Utilization critical, +2 = Liquidity collapse, +3 = Borrow rate spike, +4 = Frozen/paused

| Check | Threshold | Confirmation | Severity |
|-------|-----------|--------------|----------|
| R1: Utilization critical | > 95% | current + mid both breach | CRITICAL |
| R2: Liquidity collapse | > 40% drop | current + mid both drop | HIGH |
| R3: Borrow rate spike | > 50% increase | current + mid both spike | HIGH |
| R4: Reserve frozen/paused | any freeze/pause | current + mid both frozen | CRITICAL |

### Early Warnings (`shouldAlert`)

| Alert | Threshold |
|-------|-----------|
| Utilization approaching critical | > 85% |
| Liquidity soft drop | > 20% drop |
| Borrow rate soft spike | > 20% increase |

---

## Snapshot Data

Each block sample collects per-reserve:

```solidity
struct ReserveSnapshot {
    uint256 utilizationBps;      // totalBorrow / totalSupply in bps
    uint256 availableLiquidity;  // aToken underlying balance (free liquidity)
    uint256 borrowRateBps;       // current variable borrow rate in bps
    bool    frozen;              // reserve frozen flag from configuration bitmap
    bool    paused;              // reserve paused flag from configuration bitmap
    bool    valid;               // false if any external call reverted
}
```

Utilization is derived from:
- `aToken.totalSupply()` — total supplied assets
- `variableDebtToken.totalSupply()` — total borrowed assets
- `asset.balanceOf(aToken)` — available liquidity

---

## Response Payload

```solidity
function handleRisk(uint8 riskId, uint256 a, uint256 b, uint256 c) external
```

| Risk ID | Event | a | b | c |
|---------|-------|---|---|---|
| 2 | ProtocolPaused | — | — | — |
| X1 | UtilizationCritical | currentUtilBps | midUtilBps | oldestUtilBps |
| X2 | LiquidityCollapse | currentLiquidity | oldestLiquidity | dropBps |
| X3 | BorrowRateSpike | currentRateBps | oldestRateBps | spikeBps |
| X4 | ReserveFrozenOrPaused | frozen(0/1) | paused(0/1) | — |

Where X = asset base ID (10=WETH, 20=wstETH, 30=WBTC, 40=USDC, 50=USDT, 60=DAI)

---

## Part of a Multi-Protocol Mainnet Deployment

| Repo | Coverage |
|------|----------|
| [lido-sentinel-mainnet](https://github.com/DAOmindbreaker/lido-sentinel-mainnet) | Lido core protocol accounting health |
| [aegis-v3-sentinel-mainnet](https://github.com/DAOmindbreaker/aegis-v3-sentinel-mainnet) | Lido V3 stVaults + Governance + Aegis V4 IDT |
| **aave-sentinel-mainnet** (this repo) | Aave V3 reserve integrity |

---

## Stack

- [Drosera Network](https://drosera.io) — decentralized trap execution & attestation
- Foundry — compilation & testing
- Solidity ^0.8.20

---

## Author

**admirjae** — Drosera Mainnet Operator

- 𝕏 [@admirjae](https://x.com/admirjae)
- Operator: [`0x689Ad0f9cBa2dA64039cF894E9fB3Aa6266861D8`](https://etherscan.io/address/0x689Ad0f9cBa2dA64039cF894E9fB3Aa6266861D8)
- GitHub: [@DAOmindbreaker](https://github.com/DAOmindbreaker)
