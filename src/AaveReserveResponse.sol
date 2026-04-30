// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  Aave Reserve Integrity Response
 * @author DAOmindbreaker
 * @notice Response contract for AaveReserveSentinel.
 *
 * @dev    Risk ID encoding:
 *         Protocol level:
 *           2  = Protocol pause transition
 *
 *         Per-reserve (base ID + check):
 *           Base 10 = WETH,  20 = wstETH, 30 = WBTC
 *           Base 40 = USDC,  50 = USDT,   60 = DAI
 *           +1 = Utilization critical (>95%)
 *           +2 = Liquidity collapse (>40% drop)
 *           +3 = Borrow rate spike (>50%)
 *           +4 = Reserve frozen/paused
 *
 *         Alert IDs use same encoding but fired earlier at softer thresholds.
 */
contract AaveReserveResponse {

    // ── Events ───────────────────────────────
    event ProtocolPaused(uint256 indexed blockNumber);

    event UtilizationCritical(
        uint256 indexed blockNumber,
        uint8   assetId,
        uint256 currentUtilBps,
        uint256 midUtilBps,
        uint256 oldestUtilBps
    );

    event LiquidityCollapse(
        uint256 indexed blockNumber,
        uint8   assetId,
        uint256 currentLiquidity,
        uint256 oldestLiquidity,
        uint256 dropBps
    );

    event BorrowRateSpike(
        uint256 indexed blockNumber,
        uint8   assetId,
        uint256 currentRateBps,
        uint256 oldestRateBps,
        uint256 spikeBps
    );

    event ReserveFrozenOrPaused(
        uint256 indexed blockNumber,
        uint8   assetId,
        bool    frozen,
        bool    paused
    );

    event UnknownRiskSignal(
        uint256 indexed blockNumber,
        uint8   riskId,
        uint256 a,
        uint256 b,
        uint256 c
    );

    // ── State ────────────────────────────────
    uint256 public totalRiskEvents;
    uint256 public lastRiskBlock;
    uint8   public lastRiskId;

    // ── Entrypoint ───────────────────────────
    function handleRisk(
        uint8   riskId,
        uint256 a,
        uint256 b,
        uint256 c
    ) external {
        unchecked { ++totalRiskEvents; }
        lastRiskBlock = block.number;
        lastRiskId    = riskId;

        if (riskId == 2) {
            emit ProtocolPaused(block.number);
        } else {
            // Decode asset base and check type
            uint8 base  = (riskId / 10) * 10;
            uint8 check = riskId % 10;
            uint8 assetId = base;

            if (check == 1) {
                emit UtilizationCritical(block.number, assetId, a, b, c);
            } else if (check == 2) {
                emit LiquidityCollapse(block.number, assetId, a, b, c);
            } else if (check == 3) {
                emit BorrowRateSpike(block.number, assetId, a, b, c);
            } else if (check == 4) {
                emit ReserveFrozenOrPaused(block.number, assetId, a == 1, b == 1);
            } else {
                emit UnknownRiskSignal(block.number, riskId, a, b, c);
            }
        }
    }

    function hasRecordedRisk() external view returns (bool) {
        return totalRiskEvents > 0;
    }
}
