// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { StrategyBase } from "../StrategyBase.sol";
import { ILendingPool } from "../interfaces/ILendingPool.sol";

/**
 * @title LendingStrategy
 * @notice Deploys vault capital into a single {ILendingPool} and reports the accrued interest.
 *
 * Divest behaviour: {ILendingPool-withdraw} is allowed to return less than requested (illiquid pool).
 * The hook therefore never assumes a full fill; whatever comes back is what the vault gets, and the
 * debt baseline is decremented by that amount only. This keeps the vault solvent under partial
 * liquidity instead of reverting the whole user withdrawal.
 */
contract LendingStrategy is StrategyBase {
    using SafeERC20 for IERC20;

    /// @notice Pool currently receiving the vault's capital (zero when unset).
    ILendingPool public lendingPool;

    error Lending__ZeroAddress();
    error Lending__SamePool();
    error Lending__PoolNotFlat(uint256 position);

    event LendingPoolUpdated(address indexed previousPool, address indexed newPool);

    constructor(address asset_, address vault_, address owner_, address keeper_)
        StrategyBase(asset_, vault_, owner_, keeper_)
    { }

    // ---------------------------------------------------------------------
    // Pool wiring
    // ---------------------------------------------------------------------

    /// @notice Points the strategy at a lending pool. The pool must speak the same asset.
    /// @dev Requires the strategy to be flat so capital can never be stranded in a detached pool.
    function setLendingPool(address newPool) external onlyOwner {
        if (newPool == address(0)) revert Lending__ZeroAddress();
        if (newPool == address(lendingPool)) revert Lending__SamePool();

        uint256 position = _invested();
        if (position != 0) revert Lending__PoolNotFlat(position);

        address previous = address(lendingPool);
        lendingPool = ILendingPool(newPool);
        emit LendingPoolUpdated(previous, newPool);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Annualised yield implied by the last harvest, scaled by 1e18.
    /// @dev Read-side calculation for dashboards: `profit / debt * (365 days / elapsed)`. Returns 0
    ///      until a profitable harvest happened. Intentionally naive (no compounding, single
    ///      observation window) because it only exists to display a rough figure.
    function estimatedAPY() external view returns (uint256) {
        uint256 profit = _lastProfit;
        uint256 debtBefore = _debt;
        uint256 last = _lastHarvest;

        if (profit == 0 || debtBefore == 0 || last == 0) return 0;

        uint256 elapsed = block.timestamp - last;
        if (elapsed == 0) return 0;

        uint256 year = 365 days;
        // profit * 1e18 * year / (debt * elapsed), ordered to keep precision.
        return (profit * 1e18 * year) / (debtBefore * elapsed);
    }

    // ---------------------------------------------------------------------
    // Strategy hooks
    // ---------------------------------------------------------------------

    /// @dev Approves and deposits into the pool. If the pool refuses the funds they simply stay in
    ///      this contract, still counted by {totalAssets}, so a broken pool cannot lose user money.
    function _invest(uint256 assets) internal override returns (uint256 deployed) {
        ILendingPool pool = lendingPool;
        if (address(pool) == address(0) || assets == 0) return 0;

        IERC20 token = IERC20(asset);
        token.forceApprove(address(pool), assets);
        pool.deposit(assets);
        token.forceApprove(address(pool), 0);
        return assets;
    }

    /// @dev Tolerates partial fills: returns whatever the pool actually made liquid.
    function _divest(uint256 assets) internal override returns (uint256 withdrawn) {
        ILendingPool pool = lendingPool;
        if (address(pool) == address(0) || assets == 0) return 0;

        uint256 position = pool.balanceOf(address(this));
        if (position == 0) return 0;

        uint256 requested = assets < position ? assets : position;
        return pool.withdraw(requested);
    }

    function _invested() internal view override returns (uint256) {
        ILendingPool pool = lendingPool;
        if (address(pool) == address(0)) return 0;
        return pool.balanceOf(address(this));
    }

    /// @dev A pool can only pay out of its cash reserve, so liquidity is `min(position, poolCash)`.
    function _liquid() internal view override returns (uint256) {
        ILendingPool pool = lendingPool;
        if (address(pool) == address(0)) return 0;

        uint256 position = pool.balanceOf(address(this));
        uint256 cash = IERC20(asset).balanceOf(address(pool));
        return position < cash ? position : cash;
    }
}
