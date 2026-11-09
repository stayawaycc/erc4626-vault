// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IStrategy } from "./interfaces/IStrategy.sol";
import { IVault } from "./interfaces/IVault.sol";

/**
 * @title ERC4626Vault
 * @notice Single-strategy ERC-4626 yield aggregator.
 *
 * Accounting model (Yearn style):
 *  - `totalIdle`  : assets held by the vault itself.
 *  - `totalDebt`  : assets deployed into the active strategy.
 *  - `totalAssets()` is always `totalIdle + totalDebt`, never a raw `balanceOf` read inside a view,
 *    so a mid-transaction transfer can never silently reprice shares.
 *
 * Donations:
 *  Idle is re-synced with the real balance at the start of every state changing entry point.
 *  A donation is therefore absorbed into `totalIdle` (it accrues to existing holders) but it can
 *  never be used to inflate the share price *within* the transaction that the attacker controls,
 *  and the combination of `_decimalsOffset() == 3` plus {DEAD_SHARES} makes the classic
 *  first-depositor inflation attack strictly unprofitable. See README for the full walk-through.
 */
contract ERC4626Vault is ERC4626, Ownable, ReentrancyGuard, IVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Performance fee is expressed in basis points and hard capped at 20%.
    uint256 public constant MAX_PERFORMANCE_FEE = 2000;
    /// @notice Denominator used for the performance fee.
    uint256 public constant FEE_DENOMINATOR = 10_000;
    /// @notice Shares permanently minted to the dead address on the very first deposit.
    uint256 public constant DEAD_SHARES = 1e3;
    /// @notice Sink for the dead shares.
    address public constant DEAD_ADDRESS = address(0xdEaD);
    /// @notice Virtual decimals between shares and assets used to blunt the inflation attack.
    uint8 public constant DECIMALS_OFFSET = 3;

    /// @inheritdoc IVault
    address public override strategy;
    /// @inheritdoc IVault
    uint256 public override totalDebt;
    /// @inheritdoc IVault
    uint256 public override totalIdle;

    /// @notice Maximum amount of assets the vault will ever hold. 0 disables deposits.
    uint256 public depositLimit;
    /// @notice Performance fee in basis points applied to harvested profit.
    uint256 public performanceFee;
    /// @notice Receiver of the minted performance fee shares.
    address public feeRecipient;
    /// @notice Timestamp of the last report.
    uint256 public lastReport;
    /// @notice Profit reported during the last harvest.
    uint256 public lastProfit;
    /// @notice Advisory delay after which keeper bots should harvest again.
    uint256 public maxReportDelay;

    error Vault__ZeroAddress();
    error Vault__ZeroAmount();
    error Vault__NotStrategy(address caller);
    error Vault__NoStrategy();
    error Vault__SameStrategy(address strategy);
    error Vault__AssetMismatch(address expected, address actual);
    error Vault__DebtNotCleared(uint256 remainingDebt);
    error Vault__InsufficientLiquidity(uint256 required, uint256 available);
    error Vault__FeeTooHigh(uint256 fee, uint256 max);
    error Vault__DepositLimitBelowAssets(uint256 limit, uint256 assets);
    error Vault__CannotSweepAsset();
    error Vault__NothingToSweep();
    error Vault__ZeroDelay();

    event StrategyUpdated(address indexed previousStrategy, address indexed newStrategy);
    event DepositLimitUpdated(uint256 previousLimit, uint256 newLimit);
    event PerformanceFeeUpdated(uint256 previousFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event MaxReportDelayUpdated(uint256 previousDelay, uint256 newDelay);
    event Reported(uint256 profit, uint256 loss, uint256 feeShares, uint256 totalDebt, uint256 totalIdle);
    event Swept(address indexed token, address indexed receiver, uint256 amount);

    constructor(IERC20 asset_, address owner_, uint256 depositLimit_, uint256 performanceFee_, address feeRecipient_)
        ERC4626(asset_)
        ERC20("Aggregator Vault Share", "agSHARE")
        Ownable(owner_)
    {
        if (owner_ == address(0)) revert Vault__ZeroAddress();
        if (performanceFee_ > MAX_PERFORMANCE_FEE) revert Vault__FeeTooHigh(performanceFee_, MAX_PERFORMANCE_FEE);
        if (feeRecipient_ == address(0)) revert Vault__ZeroAddress();

        depositLimit = depositLimit_;
        performanceFee = performanceFee_;
        feeRecipient = feeRecipient_;
        maxReportDelay = 7 days;

        emit DepositLimitUpdated(0, depositLimit_);
        emit PerformanceFeeUpdated(0, performanceFee_);
        emit FeeRecipientUpdated(address(0), feeRecipient_);
        emit MaxReportDelayUpdated(0, maxReportDelay);
    }

    // ---------------------------------------------------------------------
    // ERC-4626 metadata
    // ---------------------------------------------------------------------

    /// @notice Shares are displayed with the same precision as the underlying asset.
    /// @dev Share *accounting* still carries {DECIMALS_OFFSET} extra decimals of precision through
    ///      {_decimalsOffset}; only the ERC-20 display precision mirrors the asset so wallet and UI
    ///      amounts stay intuitive.
    function decimals() public view override(ERC4626, IERC20Metadata) returns (uint8) {
        return IERC20Metadata(asset()).decimals();
    }

    /// @dev Virtual shares/assets ratio of 10**3 on top of the {DEAD_SHARES} mint. Together they make
    ///      the donation based inflation attack cost orders of magnitude more than it can steal.
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    // ---------------------------------------------------------------------
    // Accounting views
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC4626
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return totalIdle + totalDebt;
    }

    /// @notice Assets the vault can hand out right now: idle plus what the strategy can divest.
    function availableLiquidity() public view returns (uint256) {
        return _availableLiquidity();
    }

    /// @notice True when `maxReportDelay` elapsed since the last report (advisory for keepers).
    function harvestNeeded() external view returns (bool) {
        uint256 last = lastReport;
        // Timestamp skew is irrelevant here: the flag is advisory and only drives keeper polling.
        // forge-lint: disable-next-line(block-timestamp)
        return last == 0 || block.timestamp - last >= maxReportDelay;
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 assets = totalAssets();
        return assets >= depositLimit ? 0 : depositLimit - assets;
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 ownerAssets = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 liquid = _availableLiquidity();
        return ownerAssets < liquid ? ownerAssets : liquid;
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 liquidShares = _convertToShares(_availableLiquidity(), Math.Rounding.Floor);
        uint256 balance = balanceOf(owner);
        return balance < liquidShares ? balance : liquidShares;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 entry points
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (assets == 0) revert Vault__ZeroAmount();
        _syncIdle();
        bool wasEmpty = totalSupply() == 0;
        uint256 shares = super.deposit(assets, receiver);
        _mintDeadSharesAfter(wasEmpty);
        return shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) public override(ERC4626, IERC4626) nonReentrant returns (uint256) {
        if (shares == 0) revert Vault__ZeroAmount();
        _syncIdle();
        bool wasEmpty = totalSupply() == 0;
        uint256 assets = super.mint(shares, receiver);
        _mintDeadSharesAfter(wasEmpty);
        return assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (assets == 0) revert Vault__ZeroAmount();
        _syncIdle();
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        _syncIdle();
        return super.redeem(shares, receiver, owner);
    }

    // ---------------------------------------------------------------------
    // Harvest / report
    // ---------------------------------------------------------------------

    /// @notice Harvests the active strategy and books the resulting profit/loss.
    /// @dev Permissionless on purpose: any keeper bot may trigger it, the strategy itself is the one
    ///      that authenticates the caller. Not guarded because {report} is invoked from inside the
    ///      strategy call chain and both share this contract's reentrancy guard.
    function harvest() external override(IVault) returns (uint256 profit) {
        address current = strategy;
        if (current == address(0)) revert Vault__NoStrategy();
        _syncIdle();
        profit = IStrategy(current).harvest();
    }

    /// @inheritdoc IVault
    /// @dev Only the active strategy may report. Profit has already been transferred into the vault by
    ///      the strategy, so `totalIdle` is re-synced instead of incremented; `totalDebt` only shrinks
    ///      by the realised loss, which keeps `totalAssets() == totalIdle + totalDebt` exact.
    function report(uint256 profit, uint256 loss) external override(IVault) {
        if (msg.sender != strategy) revert Vault__NotStrategy(msg.sender);

        _syncIdle();

        if (loss > 0) {
            totalDebt = totalDebt > loss ? totalDebt - loss : 0;
        }

        uint256 feeShares;
        uint256 fee = performanceFee;
        address recipient = feeRecipient;
        if (profit > 0 && fee > 0 && recipient != address(0)) {
            uint256 feeAssets = profit.mulDiv(fee, FEE_DENOMINATOR, Math.Rounding.Floor);
            if (feeAssets > 0) {
                feeShares = _sharesForFee(feeAssets);
                if (feeShares > 0) _mint(recipient, feeShares);
            }
        }

        lastReport = block.timestamp;
        lastProfit = profit;

        emit Reported(profit, loss, feeShares, totalDebt, totalIdle);
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    /// @inheritdoc IVault
    /// @dev The previous strategy must be able to return every asset it owes; otherwise the call
    ///      reverts with {Vault__DebtNotCleared} and the migration is aborted.
    function setStrategy(address newStrategy) external override(IVault) onlyOwner nonReentrant {
        if (newStrategy == address(0)) revert Vault__ZeroAddress();
        address previous = strategy;
        if (newStrategy == previous) revert Vault__SameStrategy(newStrategy);
        if (IStrategy(newStrategy).asset() != asset()) {
            revert Vault__AssetMismatch(asset(), IStrategy(newStrategy).asset());
        }

        _syncIdle();
        _divestAll();

        if (totalDebt != 0) revert Vault__DebtNotCleared(totalDebt);

        strategy = newStrategy;
        emit StrategyUpdated(previous, newStrategy);

        _deployIdle();
    }

    /// @inheritdoc IVault
    function setDepositLimit(uint256 newLimit) external override(IVault) onlyOwner {
        uint256 assets = totalAssets();
        if (newLimit < assets) revert Vault__DepositLimitBelowAssets(newLimit, assets);
        emit DepositLimitUpdated(depositLimit, newLimit);
        depositLimit = newLimit;
    }

    /// @inheritdoc IVault
    function setFeeRecipient(address newFeeRecipient) external override(IVault) onlyOwner {
        if (newFeeRecipient == address(0)) revert Vault__ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newFeeRecipient);
        feeRecipient = newFeeRecipient;
    }

    /// @inheritdoc IVault
    function setPerformanceFee(uint256 newFee) external override(IVault) onlyOwner {
        if (newFee > MAX_PERFORMANCE_FEE) revert Vault__FeeTooHigh(newFee, MAX_PERFORMANCE_FEE);
        emit PerformanceFeeUpdated(performanceFee, newFee);
        performanceFee = newFee;
    }

    /// @notice Updates the advisory harvest delay.
    function setMaxReportDelay(uint256 newDelay) external onlyOwner {
        if (newDelay == 0) revert Vault__ZeroDelay();
        emit MaxReportDelayUpdated(maxReportDelay, newDelay);
        maxReportDelay = newDelay;
    }

    /// @notice Rescues tokens that are not the vault asset.
    function sweep(address token) external onlyOwner nonReentrant {
        if (token == address(0)) revert Vault__ZeroAddress();
        if (token == asset()) revert Vault__CannotSweepAsset();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert Vault__NothingToSweep();
        IERC20(token).safeTransfer(owner(), balance);
        emit Swept(token, owner(), balance);
    }

    // ---------------------------------------------------------------------
    // Internal accounting
    // ---------------------------------------------------------------------

    /// @dev Absorbs donations and any other untracked inflow into `totalIdle`.
    function _syncIdle() internal {
        totalIdle = IERC20(asset()).balanceOf(address(this));
    }

    /// @dev First deposit protection. The dead shares are minted *after* the depositor's own shares are
    ///      computed, so `previewDeposit` / `previewMint` stay exact for the very first deposit; the dead
    ///      shares then dilute the depositor by `DEAD_SHARES / supply`, which is dust for any realistic
    ///      first deposit but permanently removes the "sole holder of the supply" precondition the
    ///      inflation attack relies on.
    function _mintDeadSharesAfter(bool wasEmpty) internal {
        if (wasEmpty) _mint(DEAD_ADDRESS, DEAD_SHARES);
    }

    /// @dev Shares worth exactly `feeAssets` once minted, taking the virtual shares/assets into account.
    ///      `x * (A + 1) / (S + 10**offset + x) == F`  =>  `x = F * (S + 10**offset) / (A + 1 - F)`.
    function _sharesForFee(uint256 feeAssets) internal view returns (uint256) {
        uint256 supply = totalSupply() + 10 ** DECIMALS_OFFSET;
        uint256 assetsAfter = totalAssets() + 1;
        if (feeAssets >= assetsAfter) return 0;
        return feeAssets.mulDiv(supply, assetsAfter - feeAssets, Math.Rounding.Floor);
    }

    /// @dev Pushes all idle assets into the active strategy.
    function _deployIdle() internal {
        address current = strategy;
        uint256 idle = totalIdle;
        if (current == address(0) || idle == 0) return;

        IERC20 token = IERC20(asset());
        token.forceApprove(current, idle);
        uint256 invested = IStrategy(current).deposit(idle);
        token.forceApprove(current, 0);

        if (invested > idle) invested = idle;
        totalIdle = idle - invested;
        totalDebt += invested;
    }

    /// @dev Pulls the whole debt back from the strategy, tolerating partial fills.
    function _divestAll() internal {
        address current = strategy;
        uint256 debt = totalDebt;
        if (current == address(0) || debt == 0) return;

        uint256 received = IStrategy(current).withdraw(debt, address(this));
        totalDebt = received >= debt ? 0 : debt - received;
        totalIdle += received;
    }

    /// @dev Ensures `assets` of idle liquidity are available before an outflow.
    function _ensureLiquidity(uint256 assets) internal {
        if (totalIdle >= assets) return;

        address current = strategy;
        uint256 shortfall = assets - totalIdle;
        if (current == address(0)) revert Vault__InsufficientLiquidity(assets, totalIdle);

        uint256 received = IStrategy(current).withdraw(shortfall, address(this));
        totalDebt = totalDebt > received ? totalDebt - received : 0;
        totalIdle += received;

        if (totalIdle < assets) revert Vault__InsufficientLiquidity(assets, totalIdle);
    }

    function _availableLiquidity() internal view returns (uint256) {
        uint256 liquid = totalIdle;
        address current = strategy;
        if (current != address(0)) {
            uint256 strategyLiquid = IStrategy(current).availableLiquidity();
            uint256 debt = totalDebt;
            liquid += strategyLiquid < debt ? strategyLiquid : debt;
        }
        return liquid;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 hooks
    // ---------------------------------------------------------------------

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        totalIdle += assets;
        _deployIdle();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _ensureLiquidity(assets);
        totalIdle -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
