// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IStrategy
 * @notice Minimal interface a yield strategy must implement to be plugged into {ERC4626Vault}.
 * @dev A strategy is the only contract allowed to report profit/loss to the vault. The vault keeps
 *      `totalDebt` in sync with `strategy.totalAssets()` on every report.
 */
interface IStrategy {
    /// @notice Emitted when the strategy settles its profit and loss with the vault.
    /// @param profit Assets gained since the last harvest.
    /// @param loss Assets lost since the last harvest.
    /// @param timestamp Block timestamp of the settlement.
    event Harvested(uint256 profit, uint256 loss, uint256 timestamp);

    /// @notice The ERC20 asset managed by the strategy. Must match the vault asset.
    function asset() external view returns (address);

    /// @notice Total assets controlled by the strategy, including positions in external protocols.
    function totalAssets() external view returns (uint256);

    /// @notice Portion of {totalAssets} the strategy can return right now, bounded by the liquidity of
    ///         the underlying protocol. Always `<= totalAssets()`. Used by the vault to report honest
    ///         `maxWithdraw` / `maxRedeem` values.
    function availableLiquidity() external view returns (uint256);

    /// @notice Pulls `assets` from the caller (vault or keeper) and invests them.
    /// @return invested Amount of assets actually deployed into the underlying protocol.
    function deposit(uint256 assets) external returns (uint256 invested);

    /// @notice Divests up to `assets` and transfers the proceeds to `receiver`.
    /// @dev Implementations must tolerate illiquidity/slippage and return the amount actually delivered.
    /// @return received Amount of assets actually transferred to `receiver`.
    function withdraw(uint256 assets, address receiver) external returns (uint256 received);

    /// @notice Realizes profit/loss and reports it to the vault.
    /// @return profit Assets gained since the last harvest (zero when the position lost value).
    function harvest() external returns (uint256 profit);

    /// @notice Updates the keeper allowed to push funds in and trigger harvests.
    function setKeeper(address keeper) external;
}
