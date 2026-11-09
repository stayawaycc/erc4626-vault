// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ILendingPool
 * @notice Minimal money-market surface a lending strategy can be pointed at.
 */
interface ILendingPool {
    /// @notice Pulls `assets` from the caller and credits them to the caller's position.
    function deposit(uint256 assets) external;

    /// @notice Returns up to `assets` to the caller, bounded by its position and available liquidity.
    function withdraw(uint256 assets) external returns (uint256 withdrawn);

    /// @notice Position size of `account` denominated in the pool asset.
    function balanceOf(address account) external view returns (uint256);
}
