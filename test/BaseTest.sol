// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";

/**
 * @title BaseTest
 * @notice Shared fixture for every suite: one asset, one lending pool, one strategy, one vault,
 *         three funded users plus a keeper and a fee recipient.
 */
abstract contract BaseTest is Test {
    uint256 internal constant INITIAL_BALANCE = 1_000_000e18;
    uint256 internal constant DEPOSIT_LIMIT = 100_000_000e18;
    uint256 internal constant PERFORMANCE_FEE = 1_000; // 10%
    uint256 internal constant START_TIME = 1_700_000_000;

    MockERC20 internal asset;
    MockLendingPool internal pool;
    LendingStrategy internal strategy;
    ERC4626Vault internal vault;

    address internal alice;
    address internal bob;
    address internal carol;
    address internal keeper;
    address internal feeRecipient;

    function setUp() public virtual {
        vm.warp(START_TIME);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        keeper = makeAddr("keeper");
        feeRecipient = makeAddr("feeRecipient");

        asset = new MockERC20("Mock USD", "mUSD", 18);
        pool = new MockLendingPool(address(asset));

        vault = new ERC4626Vault(IERC20(address(asset)), address(this), DEPOSIT_LIMIT, PERFORMANCE_FEE, feeRecipient);
        strategy = new LendingStrategy(address(asset), address(vault), address(this), keeper);

        strategy.setLendingPool(address(pool));
        pool.setYieldRecipient(address(strategy));
        vault.setStrategy(address(strategy));

        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; ++i) {
            asset.mint(users[i], INITIAL_BALANCE);
            vm.prank(users[i]);
            asset.approve(address(vault), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit(assets, user);
    }

    function _redeem(address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = vault.redeem(shares, user, user);
    }

    function _harvest() internal returns (uint256 profit) {
        profit = vault.harvest();
    }

    /// @notice Injects interest into the lending pool, which the strategy is positioned to receive.
    function _simulateYield(uint256 amount) internal {
        pool.simulateYield(amount);
    }
}
