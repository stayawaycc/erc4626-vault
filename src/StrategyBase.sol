// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IStrategy } from "./interfaces/IStrategy.sol";
import { IVault } from "./interfaces/IVault.sol";

/**
 * @title StrategyBase
 * @notice Abstract yield strategy holding a single ERC20 asset on behalf of a single vault.
 *
 * Lifecycle:
 *  - The vault (or an authorised keeper) pushes idle assets in through {deposit}.
 *  - {deposit} forwards the funds to the underlying protocol via the {_invest} hook.
 *  - {withdraw} pulls funds back through the {_divest} hook and forwards them to the vault.
 *  - {harvest} compares the position value against the debt the vault believes is deployed,
 *    moves the realised profit back to the vault and reports profit/loss via {IVault-report}.
 *
 * Debt accounting:
 *  `_debt` mirrors what the vault records as `totalDebt`. It is the only baseline used to
 *  measure yield, so tokens donated directly to this contract are NOT counted as profit until
 *  the next harvest (they are silently absorbed as unrealised gain). This keeps the vault share
 *  price immune to donation-based manipulation between reports.
 */
abstract contract StrategyBase is IStrategy, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Asset managed by this strategy (must equal the vault asset).
    address public immutable override asset;

    /// @notice Vault this strategy reports to.
    address public immutable vault;

    /// @notice Address allowed to push funds in and trigger harvests in addition to the owner.
    address public keeper;

    /// @notice Assets the vault believes are deployed here. Used as the yield baseline.
    uint256 internal _debt;

    /// @notice Timestamp of the last harvest that produced a profit.
    uint256 internal _lastHarvest;

    /// @notice Profit moved to the vault during the last harvest.
    uint256 internal _lastProfit;

    error Strategy__ZeroAddress();
    error Strategy__ZeroAmount();
    error Strategy__NotVault(address caller);
    error Strategy__NotVaultOrKeeper(address caller);
    error Strategy__NotKeeperOrOwner(address caller);
    error Strategy__InvestOverflow(uint256 received, uint256 deployed);
    error Strategy__NothingToDivest(uint256 requested, uint256 received);

    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);
    event Deposited(address indexed caller, uint256 assets, uint256 invested);
    event Withdrawn(address indexed receiver, uint256 requested, uint256 received);

    modifier onlyVault() {
        if (msg.sender != vault) revert Strategy__NotVault(msg.sender);
        _;
    }

    modifier onlyVaultOrKeeper() {
        if (msg.sender != vault && msg.sender != keeper) revert Strategy__NotVaultOrKeeper(msg.sender);
        _;
    }

    /// @dev The vault is allowed as well so that {IVault-harvest} can stay permissionless at the vault
    ///      layer (any keeper bot may trigger it) while the strategy still authenticates the caller.
    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner() && msg.sender != vault) {
            revert Strategy__NotKeeperOrOwner(msg.sender);
        }
        _;
    }

    constructor(address asset_, address vault_, address owner_, address keeper_) Ownable(owner_) {
        if (asset_ == address(0) || vault_ == address(0)) revert Strategy__ZeroAddress();
        asset = asset_;
        vault = vault_;
        keeper = keeper_;
        emit KeeperUpdated(address(0), keeper_);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IStrategy
    function totalAssets() public view virtual returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + _invested();
    }

    /// @inheritdoc IStrategy
    /// @dev Conservative default: everything the strategy holds in cash plus whatever the underlying
    ///      protocol reports as immediately redeemable. Concrete strategies refine {_liquid}.
    function availableLiquidity() public view virtual returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + _liquid();
    }

    /// @notice Debt baseline used to measure profit/loss on the next harvest.
    function debt() external view returns (uint256) {
        return _debt;
    }

    /// @notice Timestamp of the last profitable harvest.
    function lastHarvest() external view returns (uint256) {
        return _lastHarvest;
    }

    /// @notice Profit moved to the vault during the last profitable harvest.
    function lastProfit() external view returns (uint256) {
        return _lastProfit;
    }

    // ---------------------------------------------------------------------
    // Vault facing entry points
    // ---------------------------------------------------------------------

    /// @inheritdoc IStrategy
    /// @dev Returns the amount of assets now under strategy management. It equals the amount
    ///      pulled from the caller; anything the underlying protocol refuses to accept simply
    ///      stays in this contract and is still counted by {totalAssets}.
    function deposit(uint256 assets) external onlyVaultOrKeeper nonReentrant returns (uint256) {
        if (assets == 0) revert Strategy__ZeroAmount();

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        uint256 deployed = _invest(received);
        if (deployed > received) revert Strategy__InvestOverflow(received, deployed);

        _debt += received;
        emit Deposited(msg.sender, received, deployed);
        return received;
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 assets, address receiver) external onlyVault nonReentrant returns (uint256) {
        if (assets == 0) revert Strategy__ZeroAmount();
        if (receiver == address(0)) revert Strategy__ZeroAddress();

        uint256 available = IERC20(asset).balanceOf(address(this));
        if (available < assets) {
            uint256 toDivest = assets - available;
            uint256 before = available;
            _divest(toDivest);
            available += IERC20(asset).balanceOf(address(this)) - before;
        }

        uint256 received = assets < available ? assets : available;
        if (received == 0) revert Strategy__NothingToDivest(assets, received);

        _debt = _debt > received ? _debt - received : 0;
        IERC20(asset).safeTransfer(receiver, received);

        emit Withdrawn(receiver, assets, received);
        return received;
    }

    /// @inheritdoc IStrategy
    /// @dev Profit is capped by the liquidity the underlying protocol can actually return. Any
    ///      unrealised remainder stays invested and is picked up by the next harvest, so profit is
    ///      never double counted. A shortfall against the debt baseline is reported as a loss.
    function harvest() external onlyKeeperOrOwner nonReentrant returns (uint256 profit) {
        uint256 current = totalAssets();
        uint256 debtBefore = _debt;
        uint256 loss;

        if (current > debtBefore) {
            profit = current - debtBefore;
        } else if (current < debtBefore) {
            loss = debtBefore - current;
        }

        uint256 reportedProfit;
        if (profit > 0) {
            uint256 liquid = IERC20(asset).balanceOf(address(this));
            if (liquid < profit) {
                uint256 before = liquid;
                _divest(profit - liquid);
                liquid += IERC20(asset).balanceOf(address(this)) - before;
            }
            reportedProfit = profit < liquid ? profit : liquid;
            if (reportedProfit > 0) {
                _lastProfit = reportedProfit;
                _lastHarvest = block.timestamp;
                IERC20(asset).safeTransfer(vault, reportedProfit);
            }
        }

        if (loss > 0) {
            _debt = debtBefore - loss;
        }

        emit Harvested(reportedProfit, loss, block.timestamp);
        IVault(vault).report(reportedProfit, loss);
        return reportedProfit;
    }

    // ---------------------------------------------------------------------
    // Owner entry points
    // ---------------------------------------------------------------------

    /// @inheritdoc IStrategy
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert Strategy__ZeroAddress();
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    // ---------------------------------------------------------------------
    // Internal hooks implemented by concrete strategies
    // ---------------------------------------------------------------------

    /// @dev Deploys `assets` into the underlying protocol. Returns the amount actually deployed.
    function _invest(uint256 assets) internal virtual returns (uint256 deployed);

    /// @dev Pulls up to `assets` out of the underlying protocol. Implementations must tolerate
    ///      illiquidity and slippage and return the amount actually made liquid.
    function _divest(uint256 assets) internal virtual returns (uint256 withdrawn);

    /// @dev Value of the position held in the underlying protocol.
    function _invested() internal view virtual returns (uint256);

    /// @dev Portion of {_invested} that the underlying protocol can return right now.
    function _liquid() internal view virtual returns (uint256);
}
