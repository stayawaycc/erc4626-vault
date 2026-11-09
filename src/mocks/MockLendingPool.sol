// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILendingPool } from "../interfaces/ILendingPool.sol";
import { MockERC20 } from "./MockERC20.sol";

/**
 * @title MockLendingPool
 * @notice Test double for a money market: tracks per-account positions and lets the test suite
 *         fabricate interest, bad debt and temporary illiquidity.
 *
 * Test levers:
 *  - {simulateYield}     mints interest into the pool and credits it to a beneficiary position.
 *  - {simulateLoss}      burns pool assets and writes the position down (realised bad debt).
 *  - {simulateIlliquidity} burns pool assets while keeping positions intact, so withdrawals can only
 *                        be served partially (assets lent out / not recallable).
 */
contract MockLendingPool is ILendingPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    /// @notice Account whose position is credited by {simulateYield} / debited by {simulateLoss}.
    address public yieldRecipient;

    mapping(address => uint256) public balanceOf;
    uint256 public totalPositions;

    error LendingPool__ZeroAddress();
    error LendingPool__ZeroAmount();
    error LendingPool__InsufficientPosition(uint256 requested, uint256 position);

    event Deposited(address indexed account, uint256 assets);
    event Withdrawn(address indexed account, uint256 requested, uint256 received);
    event YieldSimulated(address indexed account, uint256 amount);
    event LossSimulated(address indexed account, uint256 amount);
    event IlliquiditySimulated(uint256 amount);
    event YieldRecipientUpdated(address indexed account);

    constructor(address asset_) {
        if (asset_ == address(0)) revert LendingPool__ZeroAddress();
        asset = IERC20(asset_);
    }

    // ---------------------------------------------------------------------
    // ILendingPool
    // ---------------------------------------------------------------------

    function deposit(uint256 assets) external {
        if (assets == 0) revert LendingPool__ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        balanceOf[msg.sender] += assets;
        totalPositions += assets;
        emit Deposited(msg.sender, assets);
    }

    /// @inheritdoc ILendingPool
    /// @dev Returns min(requested, position, cash on hand). A shortfall means the pool is illiquid,
    ///      which is exactly the situation the strategy's {_divest} must survive.
    function withdraw(uint256 assets) external returns (uint256 withdrawn) {
        if (assets == 0) revert LendingPool__ZeroAmount();

        uint256 position = balanceOf[msg.sender];
        uint256 cash = asset.balanceOf(address(this));
        withdrawn = assets;
        if (withdrawn > position) withdrawn = position;
        if (withdrawn > cash) withdrawn = cash;

        if (withdrawn == 0) revert LendingPool__InsufficientPosition(assets, position);

        balanceOf[msg.sender] = position - withdrawn;
        totalPositions -= withdrawn;
        asset.safeTransfer(msg.sender, withdrawn);
        emit Withdrawn(msg.sender, assets, withdrawn);
    }

    // ---------------------------------------------------------------------
    // Simulation levers
    // ---------------------------------------------------------------------

    /// @notice Credits `amount` of freshly minted interest to {yieldRecipient}'s position.
    function simulateYield(uint256 amount) external {
        if (amount == 0) revert LendingPool__ZeroAmount();
        address account = yieldRecipient;
        if (account == address(0)) revert LendingPool__ZeroAddress();

        MockERC20(address(asset)).mint(address(this), amount);
        balanceOf[account] += amount;
        totalPositions += amount;
        emit YieldSimulated(account, amount);
    }

    /// @notice Writes down {yieldRecipient}'s position by `amount` and burns the matching cash.
    function simulateLoss(uint256 amount) external {
        if (amount == 0) revert LendingPool__ZeroAmount();
        address account = yieldRecipient;
        if (account == address(0)) revert LendingPool__ZeroAddress();

        uint256 position = balanceOf[account];
        if (amount > position) revert LendingPool__InsufficientPosition(amount, position);

        balanceOf[account] = position - amount;
        totalPositions -= amount;

        uint256 cash = asset.balanceOf(address(this));
        MockERC20(address(asset)).burn(address(this), amount < cash ? amount : cash);
        emit LossSimulated(account, amount);
    }

    /// @notice Burns `amount` of cash while leaving positions untouched: the pool can no longer serve
    ///         every withdrawal in full.
    function simulateIlliquidity(uint256 amount) external {
        if (amount == 0) revert LendingPool__ZeroAmount();
        MockERC20(address(asset)).burn(address(this), amount);
        emit IlliquiditySimulated(amount);
    }

    function setYieldRecipient(address account) external {
        if (account == address(0)) revert LendingPool__ZeroAddress();
        yieldRecipient = account;
        emit YieldRecipientUpdated(account);
    }
}
