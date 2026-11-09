// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { BaseTest } from "./BaseTest.sol";
import { StrategyBase } from "../src/StrategyBase.sol";
import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { IStrategy } from "../src/interfaces/IStrategy.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";

contract StrategyTest is BaseTest {
    uint256 internal constant SEED = 1_000e18;

    function setUp() public override {
        super.setUp();
        _deposit(alice, SEED);
    }

    // ---------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------

    function test_WithdrawOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyBase.Strategy__NotVault.selector, alice));
        vm.prank(alice);
        strategy.withdraw(1e18, alice);
    }

    function test_DepositOnlyVaultOrKeeper() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyBase.Strategy__NotVaultOrKeeper.selector, alice));
        vm.prank(alice);
        strategy.deposit(1e18);
    }

    function test_KeeperCanDeposit() public {
        asset.mint(address(strategy), 100e18);

        // The keeper cannot conjure funds, but it may route its own capital in.
        asset.mint(keeper, 100e18);
        vm.startPrank(keeper);
        asset.approve(address(strategy), 100e18);
        uint256 invested = strategy.deposit(100e18);
        vm.stopPrank();

        assertEq(invested, 100e18, "keeper deposit accepted");
        assertEq(pool.balanceOf(address(strategy)), SEED + 100e18, "capital deployed to the pool");
    }

    function test_HarvestOnlyKeeperOrOwner() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyBase.Strategy__NotKeeperOrOwner.selector, alice));
        vm.prank(alice);
        strategy.harvest();
    }

    function test_SetKeeperOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        strategy.setKeeper(alice);
    }

    function test_SetKeeperTransfersRights() public {
        address newKeeper = makeAddr("newKeeper");
        strategy.setKeeper(newKeeper);
        assertEq(strategy.keeper(), newKeeper, "keeper updated");

        // Old keeper lost the privilege.
        vm.expectRevert(abi.encodeWithSelector(StrategyBase.Strategy__NotKeeperOrOwner.selector, keeper));
        vm.prank(keeper);
        strategy.harvest();

        // New keeper has it.
        vm.prank(newKeeper);
        strategy.harvest();
    }

    function test_SetKeeperRejectsZeroAddress() public {
        vm.expectRevert(StrategyBase.Strategy__ZeroAddress.selector);
        strategy.setKeeper(address(0));
    }

    function test_SetLendingPoolOnlyOwner() public {
        MockLendingPool newPool = new MockLendingPool(address(asset));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        strategy.setLendingPool(address(newPool));
    }

    function test_SetLendingPoolRequiresFlatPosition() public {
        MockLendingPool newPool = new MockLendingPool(address(asset));
        vm.expectRevert(abi.encodeWithSelector(LendingStrategy.Lending__PoolNotFlat.selector, SEED));
        strategy.setLendingPool(address(newPool));
    }

    // ---------------------------------------------------------------------
    // totalAssets / accounting
    // ---------------------------------------------------------------------

    function test_TotalAssetsReflectsUnderlyingPosition() public {
        assertEq(strategy.totalAssets(), SEED, "position equals the deposit");
        assertEq(strategy.debt(), SEED, "debt baseline equals the deposit");

        _simulateYield(50e18);

        assertEq(strategy.totalAssets(), SEED + 50e18, "yield is reflected in totalAssets");
        assertEq(strategy.debt(), SEED, "debt baseline unchanged until harvest");
    }

    function test_TotalAssetsCountsLooseCash() public {
        // Assets sitting in the strategy but not invested still belong to it.
        asset.mint(address(strategy), 25e18);
        assertEq(strategy.totalAssets(), SEED + 25e18, "idle strategy cash counted");
    }

    function test_AvailableLiquidityBoundedByPoolCash() public {
        assertEq(strategy.availableLiquidity(), SEED, "fully liquid");

        pool.simulateIlliquidity(300e18);
        assertEq(strategy.availableLiquidity(), SEED - 300e18, "liquidity reflects the pool's cash");

        // Drain the remaining cash: the pool can no longer serve any withdrawal.
        pool.simulateIlliquidity(SEED - 300e18);
        assertEq(strategy.availableLiquidity(), 0, "no cash left");
        assertEq(strategy.totalAssets(), SEED, "notional position is untouched");
    }

    // ---------------------------------------------------------------------
    // Harvest: profit and loss
    // ---------------------------------------------------------------------

    function test_HarvestReportsProfit() public {
        _simulateYield(80e18);

        vm.expectEmit(true, true, true, true, address(strategy));
        emit IStrategy.Harvested(80e18, 0, block.timestamp);

        vm.prank(keeper);
        uint256 profit = strategy.harvest();

        assertEq(profit, 80e18, "profit reported");
        assertEq(strategy.lastProfit(), 80e18, "profit cached");
        assertEq(strategy.lastHarvest(), block.timestamp, "timestamp cached");
        assertEq(strategy.debt(), SEED, "debt baseline unchanged on profit");
        assertEq(asset.balanceOf(address(vault)), 80e18, "profit transferred to the vault");
    }

    function test_HarvestReportsLoss() public {
        pool.simulateLoss(60e18);

        vm.expectEmit(true, true, true, true, address(strategy));
        emit IStrategy.Harvested(0, 60e18, block.timestamp);

        uint256 profit = strategy.harvest();

        assertEq(profit, 0, "no profit on a loss");
        assertEq(strategy.debt(), SEED - 60e18, "debt written down");
        assertEq(strategy.totalAssets(), SEED - 60e18, "position matches the written down debt");
    }

    function test_HarvestWithoutChangeReportsNothing() public {
        uint256 profit = strategy.harvest();
        assertEq(profit, 0, "flat position reports no profit");
        assertEq(strategy.debt(), SEED, "debt untouched");
        assertEq(strategy.lastHarvest(), 0, "no profitable harvest recorded");
    }

    function test_HarvestIsIdempotent() public {
        _simulateYield(80e18);
        uint256 first = strategy.harvest();
        uint256 second = strategy.harvest();

        assertEq(first, 80e18, "first harvest books the profit");
        assertEq(second, 0, "second harvest finds nothing new");
        assertEq(strategy.debt(), SEED, "no double counting");
    }

    function test_HarvestCapsProfitAtAvailableLiquidity() public {
        _simulateYield(100e18);
        // Pool cannot pay out everything: only 40e18 of cash remains beyond the principal.
        pool.simulateIlliquidity(SEED + 60e18);

        uint256 profit = strategy.harvest();

        assertEq(profit, 40e18, "profit is capped by what the pool can actually return");
        assertEq(asset.balanceOf(address(vault)), 40e18, "only the liquid part was transferred");
        // The unrealised remainder stays invested and is picked up by the next harvest.
        assertEq(strategy.totalAssets(), SEED + 60e18, "unrealised gain still on the books");
    }

    function test_EstimatedAPYAfterHarvest() public {
        _simulateYield(10e18);
        strategy.harvest();

        vm.warp(block.timestamp + 365 days);
        // 10e18 profit on a 1000e18 book over one year == 1% APY, scaled by 1e18.
        assertApproxEqRel(strategy.estimatedAPY(), 0.01e18, 1e12, "1% annualised");
    }

    function test_EstimatedAPYIsZeroWithoutHarvest() public view {
        assertEq(strategy.estimatedAPY(), 0, "no data yet");
    }

    // ---------------------------------------------------------------------
    // Divest / illiquidity
    // ---------------------------------------------------------------------

    function test_DivestReturnsPartialAmountWhenPoolIsShort() public {
        pool.simulateIlliquidity(400e18);

        vm.prank(address(vault));
        uint256 received = strategy.withdraw(SEED, address(vault));

        assertEq(received, SEED - 400e18, "partial fill returned instead of reverting");
        assertEq(strategy.debt(), 400e18, "debt reduced only by what was actually returned");
        assertEq(asset.balanceOf(address(vault)), SEED - 400e18, "assets delivered to the vault");
        assertEq(strategy.totalAssets(), 400e18, "remaining position intact");
    }

    function test_WithdrawRevertsWhenNothingCanBeDivested() public {
        pool.simulateIlliquidity(SEED);

        vm.expectRevert();
        vm.prank(address(vault));
        strategy.withdraw(SEED, address(vault));
    }

    function test_WithdrawUsesLooseCashFirst() public {
        asset.mint(address(strategy), 200e18);

        vm.prank(address(vault));
        uint256 received = strategy.withdraw(200e18, address(vault));

        assertEq(received, 200e18, "loose cash served the withdrawal");
        assertEq(pool.balanceOf(address(strategy)), SEED, "pool position untouched");
        assertEq(strategy.debt(), SEED - 200e18, "debt reduced");
    }

    function test_WithdrawRejectsZeroAmount() public {
        vm.expectRevert(StrategyBase.Strategy__ZeroAmount.selector);
        vm.prank(address(vault));
        strategy.withdraw(0, address(vault));
    }

    function test_DepositRejectsZeroAmount() public {
        vm.expectRevert(StrategyBase.Strategy__ZeroAmount.selector);
        vm.prank(address(vault));
        strategy.deposit(0);
    }

    // ---------------------------------------------------------------------
    // Full cycle through the vault
    // ---------------------------------------------------------------------

    function test_FullCycleDepositYieldHarvestWithdraw() public {
        _simulateYield(100e18);
        uint256 profit = _harvest();
        assertEq(profit, 100e18, "vault-level harvest forwards the profit");

        uint256 shares = vault.balanceOf(alice);
        uint256 out = _redeem(alice, shares);

        assertApproxEqAbs(out, SEED + 90e18, 1e12, "depositor keeps the profit net of the 10% fee");
        assertEq(vault.balanceOf(alice), 0, "depositor fully exited");

        // What is left belongs to the fee recipient plus the dead shares; the depositor's debt is gone.
        uint256 feeClaim = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqAbs(feeClaim, 10e18, 1e12, "the 10% fee is the only remaining claim");
        assertApproxEqAbs(vault.totalAssets(), feeClaim, 1e6, "remaining assets match the fee claim");
    }

    // ---------------------------------------------------------------------
    // Strategy without a lending pool
    // ---------------------------------------------------------------------

    function test_StrategyWithoutPoolKeepsFundsAsCash() public {
        LendingStrategy detached = new LendingStrategy(address(asset), address(vault), address(this), keeper);

        asset.mint(address(detached), 100e18);
        assertEq(detached.totalAssets(), 100e18, "cash only");
        assertEq(detached.availableLiquidity(), 100e18, "cash is liquid");
        assertEq(detached.estimatedAPY(), 0, "no yield to annualise");

        // The detached strategy is not the vault's active strategy, so its report is rejected. This is
        // exactly the guard that stops a rogue strategy from minting fees.
        vm.expectRevert(abi.encodeWithSelector(ERC4626Vault.Vault__NotStrategy.selector, address(detached)));
        detached.harvest();
    }

    function test_StrategyWithPoolButNoPositionDoesNotInvest() public {
        // Fresh strategy with a pool but no capital: the invest hook must short-circuit on `assets == 0`.
        MockLendingPool emptyPool = new MockLendingPool(address(asset));
        LendingStrategy fresh = new LendingStrategy(address(asset), address(vault), address(this), keeper);
        fresh.setLendingPool(address(emptyPool));

        assertEq(fresh.totalAssets(), 0, "nothing to report");
        assertEq(fresh.availableLiquidity(), 0, "nothing liquid");

        // Nothing to divest: the call fails loudly rather than silently moving zero assets.
        vm.expectRevert(abi.encodeWithSelector(StrategyBase.Strategy__NothingToDivest.selector, 1e18, uint256(0)));
        vm.prank(address(vault));
        fresh.withdraw(1e18, address(vault));
    }
}
