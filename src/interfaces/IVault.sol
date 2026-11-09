// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IVault
 * @notice ERC-4626 vault interface extended with the strategy/debt accounting surface used by strategies.
 */
interface IVault is IERC4626 {
    /// @notice Address of the currently active strategy (zero when none).
    function strategy() external view returns (address);

    /// @notice Assets currently deployed into the strategy.
    function totalDebt() external view returns (uint256);

    /// @notice Assets sitting idle inside the vault.
    function totalIdle() external view returns (uint256);

    /// @notice Replaces the active strategy. Caller must be the owner; the previous strategy is fully divested.
    function setStrategy(address newStrategy) external;

    /// @notice Updates the maximum amount of assets the vault accepts in total.
    function setDepositLimit(uint256 newLimit) external;

    /// @notice Updates the address receiving minted performance fees.
    function setFeeRecipient(address newFeeRecipient) external;

    /// @notice Updates the performance fee in basis points (max 2000 = 20%).
    function setPerformanceFee(uint256 newFee) external;

    /// @notice Harvests the strategy and books the resulting profit/loss.
    /// @return profit Assets reported by the strategy for this harvest.
    function harvest() external returns (uint256 profit);

    /// @notice Called by the strategy to report profit/loss. Mints performance fees on profit.
    function report(uint256 profit, uint256 loss) external;
}
