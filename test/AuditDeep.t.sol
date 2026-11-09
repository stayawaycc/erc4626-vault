// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";

/// @title AuditDeepTest
/// @notice Second-pass probes for the accounting paths that a passing test suite would not
///         necessarily exercise. Each test targets one specific arithmetic invariant.
contract AuditDeepTest is Test {
    ERC4626Vault internal vault;
    MockERC20 internal asset;
    MockLendingPool internal pool;
    LendingStrategy internal strategy;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        vm.warp(1_700_000_000);
        asset = new MockERC20("Mock USD", "mUSD", 18);
        pool = new MockLendingPool(address(asset));
        vault = new ERC4626Vault(IERC20(address(asset)), address(this), 100_000_000e18, 1000, feeRecipient);
        strategy = new LendingStrategy(address(asset), address(vault), address(this), address(this));
        strategy.setLendingPool(address(pool));
        pool.setYieldRecipient(address(strategy));
        vault.setStrategy(address(strategy));

        // The deposit limit is 100M, so the actors need more than the default 1M to reach it.
        asset.mint(alice, 500_000_000e18);
        asset.mint(bob, 500_000_000e18);
        asset.mint(address(this), 500_000_000e18);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
        asset.approve(address(vault), type(uint256).max);
    }

    // =====================================================================
    // Deep probe 1: does debt shrink when profit is reported?
    // =====================================================================

    /// @notice After harvest, `totalDebt` should reflect what the strategy still owes.
    /// @dev The concern: `report` only subtracts `loss` and never reconciles `profit`. If the
    ///      strategy transferred the profit to the vault, then `totalDebt` is now over-stated
    ///      relative to what the strategy actually holds, which breaks the solvency invariant
    ///      `totalDebt <= strategy.totalAssets()` on the *next* call.
    function test_TotalDebtReconcilesWithStrategyAfterHarvest() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        pool.simulateYield(500e18);
        vault.harvest();

        uint256 debt = vault.totalDebt();
        uint256 strategyAssets = strategy.totalAssets();

        console2.log("vault totalDebt       :", debt);
        console2.log("strategy totalAssets  :", strategyAssets);

        // The strategy moved 500 to the vault, so it now holds 10_000 while the vault still thinks
        // it is owed 10_000. Those should match.
        assertLe(debt, strategyAssets, "vault thinks it is owed more than the strategy holds");
    }

    /// @notice Repeated harvests must not drift the debt number.
    function test_RepeatedHarvestKeepsDebtStable() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        for (uint256 i; i < 5; ++i) {
            pool.simulateYield(100e18);
            vault.harvest();
        }

        uint256 debt = vault.totalDebt();
        uint256 strategyAssets = strategy.totalAssets();
        console2.log("debt after 5 harvests  :", debt);
        console2.log("strategy assets        :", strategyAssets);

        assertLe(debt, strategyAssets, "debt drifted above what the strategy holds");
    }

    // =====================================================================
    // Deep probe 2: can every holder actually exit after a profit?
    // =====================================================================

    /// @notice If totalAssets over-states reality, the last withdrawer cannot get paid.
    /// @dev This is the concrete user-visible symptom of an accounting error: `maxWithdraw` says
    ///      yes, `withdraw` reverts.
    function test_AllHoldersCanExitAfterProfit() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);
        vm.prank(bob);
        vault.deposit(10_000e18, bob);

        pool.simulateYield(1_000e18);
        vault.harvest();

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);

        // Alice exits fully.
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceShares, alice, alice);

        // Bob exits fully. If the vault over-reported assets, this reverts.
        vm.prank(bob);
        uint256 bobOut = vault.redeem(bobShares, bob, bob);

        console2.log("alice out:", aliceOut);
        console2.log("bob out  :", bobOut);

        assertGt(aliceOut, 10_000e18, "alice should profit");
        assertGt(bobOut, 10_000e18, "bob should profit");

        // Everyone is out and the vault is empty of user assets.
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);

        // Whatever remains must be fully claimable. Two claimants exist after the users exit: the
        // dead address (permanently locked) and the fee recipient (earned 10% of the 1_000 profit).
        uint256 deadShares = vault.balanceOf(vault.DEAD_ADDRESS());
        uint256 feeShares = vault.balanceOf(feeRecipient);
        uint256 claimable = vault.convertToAssets(deadShares + feeShares);

        console2.log("dead shares           :", deadShares);
        console2.log("fee recipient shares  :", feeShares);
        console2.log("claimable by them     :", claimable);
        console2.log("totalAssets remaining :", vault.totalAssets());

        // The fee recipient should have earned ~10% of the 1_000 profit.
        assertApproxEqAbs(vault.convertToAssets(feeShares), 100e18, 1e15, "fee was not ~10% of profit");

        // Nothing beyond the two legitimate claimants may be stranded.
        assertLe(vault.totalAssets(), claimable + 1e15, "assets stranded that no share can claim");
    }

    // =====================================================================
    // Deep probe 3: loss handling
    // =====================================================================

    /// @notice A reported loss must reduce totalAssets by exactly the loss.
    function test_LossReducesTotalAssetsExactly() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        uint256 before = vault.totalAssets();
        pool.simulateLoss(1_000e18);
        vault.harvest();
        uint256 afterLoss = vault.totalAssets();

        console2.log("assets before loss:", before);
        console2.log("assets after loss :", afterLoss);

        assertApproxEqAbs(afterLoss, before - 1_000e18, 1e6, "loss not passed through exactly");
    }

    /// @notice After a loss, holders must still be able to exit for the reduced amount.
    function test_HoldersCanExitAfterLoss() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        pool.simulateLoss(2_000e18);
        vault.harvest();

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        console2.log("alice out after 2000 loss:", out);
        assertApproxEqAbs(out, 8_000e18, 1e6, "holder did not absorb the loss proportionally");
    }

    // =====================================================================
    // Deep probe 4: deposit limit
    // =====================================================================

    function test_DepositLimitIsEnforcedExactly() public {
        uint256 limit = vault.depositLimit();

        vm.prank(alice);
        vault.deposit(limit, alice);

        assertEq(vault.maxDeposit(bob), 0, "limit should be exhausted");

        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1, bob);
    }

    /// @notice A donation must not be able to push the vault over its limit, and it must not bypass
    ///         the limit either. Once absorbed, the headroom it consumed is gone.
    function test_DonationCountsTowardLimit() public {
        uint256 limit = vault.depositLimit();
        vm.prank(alice);
        vault.deposit(limit / 2, alice);

        // Donate the remaining headroom directly.
        vm.prank(bob);
        asset.transfer(address(vault), limit / 2);

        // `maxDeposit` is a view over the stored accounting, so it only reflects the donation after
        // a state-changing call absorbs it. A withdrawal is the legal touch here: the vault is at
        // the limit, so a deposit would be rejected before it could sync.
        vm.prank(alice);
        vault.withdraw(1, alice, alice);

        console2.log("maxDeposit after donation:", vault.maxDeposit(bob));

        // Headroom is now 1 wei at most: the donation consumed the rest.
        assertLe(vault.maxDeposit(bob), 1, "donation should consume limit headroom");

        // A deposit beyond the remaining headroom must be rejected by the ERC-4626 limit check.
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(2, bob);
    }

    // =====================================================================
    // Deep probe 5: fee recipient cannot be used to drain via repeated harvests
    // =====================================================================

    /// @notice Ten small harvests must not extract materially more fee value than one large harvest.
    /// @dev A small difference is expected and correct: each fee mint increases `totalSupply`, which
    ///      becomes the base for the next fee calculation, so frequent harvesting compounds the fee
    ///      recipient's position slightly faster. The property that matters is that the difference
    ///      stays small — a large gap would mean `_sharesForFee` is rounding in the recipient's
    ///      favour rather than applying a flat percentage of profit.
    function test_SplittingHarvestsDoesNotOverchargeFees() public {
        vm.prank(alice);
        vault.deposit(100_000e18, alice);

        // Path A: one harvest of 1_000 profit.
        uint256 snap = vm.snapshotState();
        pool.simulateYield(1_000e18);
        vault.harvest();
        uint256 feeOneShot = vault.convertToAssets(vault.balanceOf(feeRecipient));
        vm.revertToState(snap);

        // Path B: ten harvests of 100 profit each.
        for (uint256 i; i < 10; ++i) {
            pool.simulateYield(100e18);
            vault.harvest();
        }
        uint256 feeSplit = vault.convertToAssets(vault.balanceOf(feeRecipient));

        console2.log("fee value, one harvest :", feeOneShot);
        console2.log("fee value, ten harvests:", feeSplit);

        // The compounding delta must stay under 1% of the fee. Above that, the fee formula is
        // amplifying rather than proportionally charging.
        uint256 delta = feeSplit > feeOneShot ? feeSplit - feeOneShot : 0;
        console2.log("delta from splitting  :", delta);
        assertLt(delta, feeOneShot / 100, "splitting harvests overcharges fees by more than 1%");
    }

    // =====================================================================
    // Deep probe 6: strategy returning less than owed during withdraw
    // =====================================================================

    /// @notice When the strategy is illiquid, a withdrawal larger than idle must revert rather than
    ///         pay out partially and corrupt the accounting.
    function test_IlliquidWithdrawRevertsCleanly() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        pool.simulateIlliquidity(9_000e18);

        uint256 assetsBefore = vault.totalAssets();
        uint256 sharesBefore = vault.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(10_000e18, alice, alice);

        assertEq(vault.totalAssets(), assetsBefore, "failed withdraw mutated accounting");
        assertEq(vault.balanceOf(alice), sharesBefore, "failed withdraw burned shares");
    }

    /// @notice A withdrawal within available liquidity must succeed even when the pool is tight.
    function test_WithdrawWithinLiquiditySucceeds() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        pool.simulateIlliquidity(9_000e18);

        uint256 liquid = vault.availableLiquidity();
        console2.log("available liquidity:", liquid);
        assertGt(liquid, 0);

        vm.prank(alice);
        vault.withdraw(liquid, alice, alice);
    }

    // =====================================================================
    // Deep probe 7: totalAssets identity under every operation
    // =====================================================================

    function test_IdentityHoldsAfterEveryOperation() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after deposit");

        pool.simulateYield(300e18);
        vault.harvest();
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after harvest");

        // `this` is the depositor here, so it needs its own allowance.
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(5_000e18, address(this));
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after second deposit");

        vm.prank(alice);
        vault.withdraw(2_000e18, alice, alice);
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after withdraw");

        uint256 halfShares = vault.balanceOf(address(this)) / 2;
        vault.redeem(halfShares, address(this), address(this));
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after redeem");

        pool.simulateLoss(100e18);
        vault.harvest();
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after loss harvest");
    }
}
