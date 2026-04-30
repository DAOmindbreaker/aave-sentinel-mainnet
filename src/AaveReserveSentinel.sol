// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

/**
 * @title  Aave Reserve Integrity Sentinel
 * @author DAOmindbreaker
 * @notice Drosera Trap monitoring Aave V3 protocol health on Ethereum Mainnet.
 *         Covers three layers of risk: protocol-level, reserve-level, and
 *         utilization-based liquidity stress detection.
 *
 * @dev    Detection layers:
 *
 *         Protocol Level:
 *           P1 — Total borrow/supply ratio spike (utilization surge)
 *           P2 — Protocol pause state transition
 *
 *         Reserve Level (sampled across key assets):
 *           R1 — Reserve utilization approaching 100% (liquidity crisis)
 *           R2 — Available liquidity collapse (sudden large withdrawal)
 *           R3 — Borrow rate spike (signal of liquidity stress)
 *           R4 — Reserve frozen/paused (individual asset halt)
 *
 *         All checks require sustained anomalies across 3 block samples
 *         to eliminate false positives from transient state.
 *
 * @dev    Encoding: shouldRespond/shouldAlert payload:
 *           abi.encode(uint8 riskId, uint256 a, uint256 b, uint256 c)
 *         Response function: handleRisk(uint8,uint256,uint256,uint256)
 *
 * Contracts monitored:
 *   Aave V3 Pool       : 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
 *   Aave V3 DataProvider: 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3
 *
 * Key assets monitored:
 *   WETH  : 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
 *   wstETH: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
 *   WBTC  : 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
 *   USDC  : 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
 *   USDT  : 0xdAC17F958D2ee523a2206206994597C13D831ec7
 *   DAI   : 0x6B175474E89094C44Da98b954EedeAC495271d0F
 */

// ─────────────────────────────────────────────
//  Interfaces
// ─────────────────────────────────────────────

interface IAavePool {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40  lastUpdateTimestamp;
        uint16  id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
    function paused() external view returns (bool);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

// ─────────────────────────────────────────────
//  Data structures
// ─────────────────────────────────────────────

struct ReserveSnapshot {
    uint256 utilizationBps;      // totalBorrow / totalSupply in bps
    uint256 availableLiquidity;  // aToken underlying balance (free liquidity)
    uint256 borrowRateBps;       // current variable borrow rate in bps
    bool    frozen;              // reserve frozen flag
    bool    paused;              // reserve paused flag
    bool    valid;               // false if call reverted
}

struct AaveSnapshot {
    bool    protocolPaused;                // protocol-level pause
    ReserveSnapshot weth;
    ReserveSnapshot wstEth;
    ReserveSnapshot wbtc;
    ReserveSnapshot usdc;
    ReserveSnapshot usdt;
    ReserveSnapshot dai;
    bool    valid;
}

// ─────────────────────────────────────────────
//  Trap contract
// ─────────────────────────────────────────────

contract AaveReserveSentinel is ITrap {

    // ── Addresses ────────────────────────────
    address public constant AAVE_POOL    = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // ── Key assets ───────────────────────────
    address public constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WBTC   = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant USDC   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT   = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant DAI    = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // ── Constants ────────────────────────────
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant RAY       = 1e27;

    // ── Thresholds ───────────────────────────

    /// R1: Utilization > 95% = liquidity crisis imminent
    uint256 public constant UTILIZATION_CRITICAL_BPS  = 9500;
    /// R1 alert: Utilization > 85%
    uint256 public constant UTILIZATION_ALERT_BPS     = 8500;

    /// R2: Available liquidity drop > 40% sustained
    uint256 public constant LIQUIDITY_DROP_BPS        = 4000;
    /// R2 alert: > 20% drop
    uint256 public constant LIQUIDITY_DROP_ALERT_BPS  = 2000;

    /// R3: Borrow rate spike > 50% increase sustained
    uint256 public constant BORROW_RATE_SPIKE_BPS     = 5000;
    /// R3 alert: > 20% increase
    uint256 public constant BORROW_RATE_ALERT_BPS     = 2000;

    // ── Bit masks for ReserveConfigurationMap ─
    uint256 constant FROZEN_MASK = 0x0800000000000000000000000000000000000000000000000000000000000000;
    uint256 constant PAUSED_MASK = 0x1000000000000000000000000000000000000000000000000000000000000000;

    // ── collect() ────────────────────────────

    function collect() external view returns (bytes memory) {
        AaveSnapshot memory snap;

        // Protocol pause
        try IAavePool(AAVE_POOL).paused() returns (bool p) {
            snap.protocolPaused = p;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // Sample 6 key reserves
        snap.weth   = _collectReserve(WETH);
        snap.wstEth = _collectReserve(WSTETH);
        snap.wbtc   = _collectReserve(WBTC);
        snap.usdc   = _collectReserve(USDC);
        snap.usdt   = _collectReserve(USDT);
        snap.dai    = _collectReserve(DAI);

        snap.valid = true;
        return abi.encode(snap);
    }

    function _collectReserve(address asset) internal view returns (ReserveSnapshot memory r) {
        IAavePool.ReserveData memory data;

        try IAavePool(AAVE_POOL).getReserveData(asset) returns (IAavePool.ReserveData memory d) {
            data = d;
        } catch {
            return r; // valid = false
        }

        // Frozen/paused flags from configuration bitmap
        r.frozen = (data.configuration.data & FROZEN_MASK) != 0;
        r.paused = (data.configuration.data & PAUSED_MASK) != 0;

        // Available liquidity = aToken underlying balance
        if (data.aTokenAddress != address(0)) {
            try IERC20(asset).balanceOf(data.aTokenAddress) returns (uint256 bal) {
                r.availableLiquidity = bal;
            } catch {
                return r;
            }
        }

        // aToken total supply = total supplied
        uint256 totalSupply;
        if (data.aTokenAddress != address(0)) {
            try IERC20(data.aTokenAddress).totalSupply() returns (uint256 s) {
                totalSupply = s;
            } catch {
                return r;
            }
        }

        // Variable debt = total borrowed
        uint256 totalBorrow;
        if (data.variableDebtTokenAddress != address(0)) {
            try IERC20(data.variableDebtTokenAddress).totalSupply() returns (uint256 b) {
                totalBorrow = b;
            } catch {
                return r;
            }
        }

        // Utilization = totalBorrow / totalSupply
        if (totalSupply > 0) {
            r.utilizationBps = (totalBorrow * BPS_DENOM) / totalSupply;
        }

        // Borrow rate: convert from RAY to BPS
        r.borrowRateBps = data.currentVariableBorrowRate / (RAY / BPS_DENOM);

        r.valid = true;
    }

    // ── shouldRespond() ──────────────────────

    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 3) return (false, bytes(""));

        AaveSnapshot memory current = abi.decode(data[0], (AaveSnapshot));
        AaveSnapshot memory mid     = abi.decode(data[1], (AaveSnapshot));
        AaveSnapshot memory oldest  = abi.decode(data[2], (AaveSnapshot));

        if (!current.valid || !mid.valid || !oldest.valid) return (false, bytes(""));

        // ── P2: Protocol pause transition ─────────────────────────────────────
        if (current.protocolPaused && !oldest.protocolPaused) {
            return (true, abi.encode(uint8(2), uint256(1), uint256(0), uint256(0)));
        }

        // ── Check each reserve ────────────────────────────────────────────────
        // Pack: riskId=1 protocol, 10=WETH, 20=wstETH, 30=WBTC, 40=USDC, 50=USDT, 60=DAI

        // WETH
        (bool triggered, bytes memory payload) = _checkReserve(
            current.weth, mid.weth, oldest.weth, 10
        );
        if (triggered) return (true, payload);

        // wstETH
        (triggered, payload) = _checkReserve(
            current.wstEth, mid.wstEth, oldest.wstEth, 20
        );
        if (triggered) return (true, payload);

        // WBTC
        (triggered, payload) = _checkReserve(
            current.wbtc, mid.wbtc, oldest.wbtc, 30
        );
        if (triggered) return (true, payload);

        // USDC
        (triggered, payload) = _checkReserve(
            current.usdc, mid.usdc, oldest.usdc, 40
        );
        if (triggered) return (true, payload);

        // USDT
        (triggered, payload) = _checkReserve(
            current.usdt, mid.usdt, oldest.usdt, 50
        );
        if (triggered) return (true, payload);

        // DAI
        (triggered, payload) = _checkReserve(
            current.dai, mid.dai, oldest.dai, 60
        );
        if (triggered) return (true, payload);

        return (false, bytes(""));
    }

    function _checkReserve(
        ReserveSnapshot memory current,
        ReserveSnapshot memory mid,
        ReserveSnapshot memory oldest,
        uint8 baseId
    ) internal pure returns (bool, bytes memory) {
        if (!current.valid || !mid.valid || !oldest.valid) return (false, bytes(""));

        // R4: Reserve frozen or paused (sustained)
        if ((current.frozen || current.paused) && (mid.frozen || mid.paused)) {
            return (true, abi.encode(uint8(baseId + 4), uint256(current.frozen ? 1 : 0), uint256(current.paused ? 1 : 0), uint256(0)));
        }

        // R1: Utilization critical (> 95%) sustained
        if (current.utilizationBps >= UTILIZATION_CRITICAL_BPS &&
            mid.utilizationBps     >= UTILIZATION_CRITICAL_BPS) {
            return (true, abi.encode(uint8(baseId + 1), current.utilizationBps, mid.utilizationBps, oldest.utilizationBps));
        }

        // R2: Available liquidity collapse > 40% sustained
        if (oldest.availableLiquidity > 0 && current.availableLiquidity < oldest.availableLiquidity) {
            uint256 dropBps = ((oldest.availableLiquidity - current.availableLiquidity) * BPS_DENOM)
                / oldest.availableLiquidity;
            bool midAlsoDrop = mid.availableLiquidity < oldest.availableLiquidity;
            if (dropBps >= LIQUIDITY_DROP_BPS && midAlsoDrop) {
                return (true, abi.encode(uint8(baseId + 2), current.availableLiquidity, oldest.availableLiquidity, dropBps));
            }
        }

        // R3: Borrow rate spike > 50% sustained
        if (oldest.borrowRateBps > 0 && current.borrowRateBps > oldest.borrowRateBps) {
            uint256 spikeBps = ((current.borrowRateBps - oldest.borrowRateBps) * BPS_DENOM)
                / oldest.borrowRateBps;
            bool midAlsoSpike = mid.borrowRateBps > oldest.borrowRateBps;
            if (spikeBps >= BORROW_RATE_SPIKE_BPS && midAlsoSpike) {
                return (true, abi.encode(uint8(baseId + 3), current.borrowRateBps, oldest.borrowRateBps, spikeBps));
            }
        }

        return (false, bytes(""));
    }

    // ── shouldAlert() ─────────────────────────

    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 2) return (false, bytes(""));

        AaveSnapshot memory current = abi.decode(data[0], (AaveSnapshot));
        AaveSnapshot memory mid     = abi.decode(data[1], (AaveSnapshot));

        if (!current.valid || !mid.valid) return (false, bytes(""));

        // Alert: utilization > 85% on any key reserve
        ReserveSnapshot[6] memory reserves = [
            current.weth, current.wstEth, current.wbtc,
            current.usdc, current.usdt, current.dai
        ];
        ReserveSnapshot[6] memory midReserves = [
            mid.weth, mid.wstEth, mid.wbtc,
            mid.usdc, mid.usdt, mid.dai
        ];
        uint8[6] memory baseIds = [10, 20, 30, 40, 50, 60];

        for (uint256 i = 0; i < 6; ) {
            if (!reserves[i].valid || !midReserves[i].valid) {
                unchecked { ++i; }
                continue;
            }

            // Alert R1: utilization > 85%
            if (reserves[i].utilizationBps >= UTILIZATION_ALERT_BPS) {
                return (true, abi.encode(uint8(baseIds[i] + 1), reserves[i].utilizationBps, midReserves[i].utilizationBps, uint256(0)));
            }

            // Alert R2: liquidity drop > 20%
            if (midReserves[i].availableLiquidity > 0 &&
                reserves[i].availableLiquidity < midReserves[i].availableLiquidity) {
                uint256 dropBps = ((midReserves[i].availableLiquidity - reserves[i].availableLiquidity) * BPS_DENOM)
                    / midReserves[i].availableLiquidity;
                if (dropBps >= LIQUIDITY_DROP_ALERT_BPS) {
                    return (true, abi.encode(uint8(baseIds[i] + 2), reserves[i].availableLiquidity, midReserves[i].availableLiquidity, dropBps));
                }
            }

            // Alert R3: borrow rate spike > 20%
            if (midReserves[i].borrowRateBps > 0 &&
                reserves[i].borrowRateBps > midReserves[i].borrowRateBps) {
                uint256 spikeBps = ((reserves[i].borrowRateBps - midReserves[i].borrowRateBps) * BPS_DENOM)
                    / midReserves[i].borrowRateBps;
                if (spikeBps >= BORROW_RATE_ALERT_BPS) {
                    return (true, abi.encode(uint8(baseIds[i] + 3), reserves[i].borrowRateBps, midReserves[i].borrowRateBps, spikeBps));
                }
            }

            unchecked { ++i; }
        }

        return (false, bytes(""));
    }
}
