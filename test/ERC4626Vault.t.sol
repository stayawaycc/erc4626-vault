// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from "./BaseTest.sol";
import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";

contract ERC4626VaultTest is BaseTest {
    // ---------------------------------------------------------------------
    // Basic ERC-4626 correctness
    // ---------------------------------------------------------------------

    function test_DepositMintsSharesAndPullsAssets() public {
        uint256 amount = 1_000e18;
        uint256 previewShares = vault.previewDeposit(amount);

        uint256 shares = _deposit(alice, amount);

        assertEq(shares, previewShares, "shares must match previewDeposit");
        assertGt(shares, 0, "shares must be non-zero");
        assertEq(vault.balanceOf(alice), shares, "share balance");
        assertEq(asset.balanceOf(alice), INITIAL_BALANCE - amount, "assets pulled from depositor");
        assertEq(vault.totalAssets(), amount, "vault accounts the deposit");
    }

    function test_PreviewIsExactAfterFirstDeposit() public {
        _deposit(carol, 1_000e18);

        uint256 amount = 1_000e18;
        uint256 previewShares = vault.previewDeposit(amount);
        uint256 shares = _deposit(alice, amount);

        assertEq(shares, previewShares, "previews are exact once the vault is seeded");
    }

    function test_DepositDeploysIntoStrategy() public {
        uint256 amount = 1_000e18;
        _deposit(alice, amount);

        assertEq(vault.totalIdle(), 0, "all idle capital is deployed");
        assertEq(vault.totalDebt(), amount, "debt tracks the deployed amount");
        assertEq(pool.balanceOf(address(strategy)), amount, "strategy position in the pool");
        assertEq(asset.balanceOf(address(vault)), 0, "vault holds no loose asset");
    }

    function test_MintPullsExactAssets() public {
        uint256 shares = 500e18;

        vm.prank(alice);
        uint256 assets = vault.mint(shares, alice);

        assertEq(vault.balanceOf(alice), shares, "requested shares minted");
        assertEq(assets, vault.previewMint(shares), "assets match previewMint");
        assertEq(asset.balanceOf(alice), INITIAL_BALANCE - assets, "assets pulled");
    }

    function test_WithdrawReturnsAssets() public {
        uint256 shares = _deposit(alice, 1_000e18);

        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(400e18, alice, alice);

        assertEq(asset.balanceOf(alice), INITIAL_BALANCE - 1_000e18 + 400e18, "assets returned");
        assertEq(vault.balanceOf(alice), shares - sharesBurned, "shares burned");
        assertEq(vault.totalAssets(), 600e18, "remaining accounting");
        assertEq(sharesBurned, vault.previewWithdraw(400e18), "burn matches previewWithdraw");
    }

    function test_RedeemReturnsAssets() public {
        uint256 shares = _deposit(alice, 1_000e18);

        uint256 assets = _redeem(alice, shares / 2);

        assertApproxEqAbs(assets, 500e18, 1, "half of the position (1 wei of share rounding)");
        assertEq(vault.balanceOf(alice), shares - shares / 2, "shares burned");
    }

    function test_RedeemAllRecoversDeposit() public {
        uint256 amount = 1_000e18;
        uint256 shares = _deposit(alice, amount);

        uint256 out = _redeem(alice, shares);

        assertApproxEqAbs(out, amount, 1, "round trip returns the deposit within 1 wei");
        assertEq(vault.balanceOf(alice), 0, "no shares left");
        // The dead shares stay behind, backed by the virtual asset, so only dust remains.
        assertLe(vault.totalAssets(), 1, "vault is effectively drained");
    }

    function test_SharePriceRisesAfterYield() public {
        uint256 shares = _deposit(alice, 1_000e18);
        uint256 priceBefore = vault.convertToAssets(shares);

        _simulateYield(100e18);
        _harvest();

        uint256 priceAfter = vault.convertToAssets(shares);
        assertGt(priceAfter, priceBefore, "one share redeems more assets after yield");
        // 10% yield minus the 10% performance fee leaves ~9% net for the depositor.
        assertApproxEqRel(priceAfter, 1_090e18, 1e12, "10% yield minus 10% performance fee");
    }

    function test_LossReducesSharePrice() public {
        uint256 shares = _deposit(alice, 1_000e18);
        uint256 priceBefore = vault.convertToAssets(shares);

        pool.simulateLoss(100e18);
        _harvest();

        uint256 priceAfter = vault.convertToAssets(shares);
        assertLt(priceAfter, priceBefore, "loss is socialised across holders");
        assertApproxEqRel(priceAfter, 900e18, 1e12, "10% of the position written off");
    }

    // ---------------------------------------------------------------------
    // Harvest and performance fees
    // ---------------------------------------------------------------------

    function test_HarvestBooksProfitAndTimestamp() public {
        _deposit(alice, 1_000e18);
        _simulateYield(50e18);
        vm.warp(START_TIME + 7 days);

        uint256 profit = _harvest();

        assertEq(profit, 50e18, "strategy reports the full yield");
        assertEq(vault.lastProfit(), 50e18, "vault records the profit");
        assertEq(vault.lastReport(), START_TIME + 7 days, "vault records the report time");
        assertEq(vault.totalAssets(), 1_050e18, "profit is part of total assets");
        assertEq(vault.totalIdle(), 50e18, "profit landed as idle capital");
        assertEq(vault.totalDebt(), 1_000e18, "debt unchanged by a profitable harvest");
    }

    function test_HarvestMintsPerformanceFee() public {
        _deposit(alice, 1_000e18);
        _simulateYield(100e18);
        _harvest();

        assertGt(vault.balanceOf(feeRecipient), 0, "fee shares minted to the recipient");
    }

    function test_HarvestFeeAmountIsExact() public {
        uint256 depositAmount = 1_000e18;
        uint256 profit = 100e18;
        _deposit(alice, depositAmount);

        uint256 supplyBefore = vault.totalSupply();
        uint256 assetsBefore = vault.totalAssets();

        _simulateYield(profit);
        _harvest();

        // The fee is charged in assets and converted to shares at the post-profit price, using the
        // virtual shares/assets so the minted shares are worth exactly `feeAssets` afterwards.
        uint256 expectedFeeAssets = (profit * PERFORMANCE_FEE) / 10_000;
        uint256 expectedFeeShares = expectedFeeAssets * (supplyBefore + 10 ** vault.DECIMALS_OFFSET())
            / (assetsBefore + profit + 1 - expectedFeeAssets);

        assertEq(vault.balanceOf(feeRecipient), expectedFeeShares, "fee shares == profit * fee / 10000");
        assertApproxEqAbs(vault.convertToAssets(expectedFeeShares), expectedFeeAssets, 1, "fee shares redeem the fee");
        assertEq(vault.totalSupply(), supplyBefore + expectedFeeShares, "no other shares minted");
    }

    function test_HarvestWithoutProfitReportsZero() public {
        _deposit(alice, 1_000e18);

        uint256 profit = _harvest();

        assertEq(profit, 0, "no yield, no profit");
        assertEq(vault.balanceOf(feeRecipient), 0, "no fee without profit");
        assertEq(vault.totalAssets(), 1_000e18, "assets untouched");
    }

    function test_HarvestRevertsWithoutStrategy() public {
        ERC4626Vault bare = new ERC4626Vault(IERC20(address(asset)), address(this), DEPOSIT_LIMIT, 0, feeRecipient);
        vm.expectRevert(ERC4626Vault.Vault__NoStrategy.selector);
        bare.harvest();
    }

    function test_HarvestNeededFlag() public {
        _deposit(alice, 1_000e18);
        assertTrue(vault.harvestNeeded(), "never reported yet");

        _harvest();
        assertFalse(vault.harvestNeeded(), "just reported");

        vm.warp(block.timestamp + vault.maxReportDelay());
        assertTrue(vault.harvestNeeded(), "delay elapsed");
    }

    function test_ReportOnlyCallableByStrategy() public {
        _deposit(alice, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Vault.Vault__NotStrategy.selector, alice));
        vm.prank(alice);
        vault.report(1e18, 0);
    }

    // ---------------------------------------------------------------------
    // Limits and liquidity views
    // ---------------------------------------------------------------------

    function test_MaxDepositRespectsDepositLimit() public {
        _deposit(alice, 1_000e18);
        assertEq(vault.maxDeposit(bob), DEPOSIT_LIMIT - 1_000e18, "remaining capacity");

        vault.setDepositLimit(1_000e18);
        assertEq(vault.maxDeposit(bob), 0, "limit reached");
    }

    function test_DepositAboveLimitReverts() public {
        _deposit(alice, 1_000e18);
        vault.setDepositLimit(1_000e18);

        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1e18, uint256(0)));
        vm.prank(bob);
        vault.deposit(1e18, bob);
    }

    function test_SetDepositLimitBelowAssetsReverts() public {
        _deposit(alice, 1_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Vault.Vault__DepositLimitBelowAssets.selector, uint256(999e18), 1_000e18)
        );
        vault.setDepositLimit(999e18);
    }

    function test_MaxWithdrawReflectsStrategyLiquidity() public {
        _deposit(alice, 1_000e18);

        assertEq(vault.totalIdle(), 0, "everything is invested");
        // `maxWithdraw` is a floor-converted view; it can lag the position by a wei of rounding.
        assertApproxEqAbs(vault.maxWithdraw(alice), 1_000e18, 1, "strategy liquidity counts as withdrawable");
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice), "all shares redeemable");

        // Once the pool turns illiquid, the view reports the real constraint instead of the notional debt.
        pool.simulateIlliquidity(400e18);
        assertApproxEqAbs(vault.maxWithdraw(alice), 600e18, 1, "illiquidity is reflected in maxWithdraw");
        assertEq(vault.availableLiquidity(), 600e18, "vault reports the real liquidity");
    }

    function test_WithdrawRevertsWhenStrategyCannotDeliver() public {
        _deposit(alice, 1_000e18);
        pool.simulateIlliquidity(400e18);

        vm.expectRevert();
        vm.prank(alice);
        vault.withdraw(1_000e18, alice, alice);

        // A smaller withdrawal still works: the pool has 600e18 of cash left.
        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);
        assertEq(asset.balanceOf(alice), INITIAL_BALANCE - 1_000e18 + 500e18, "partial liquidity served");
    }

    function test_TotalAssetsEqualsIdlePlusDebt() public {
        _deposit(alice, 1_000e18);
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after deposit");

        _simulateYield(37e18);
        _harvest();
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after harvest");

        vm.prank(alice);
        vault.withdraw(123e18, alice, alice);
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after withdraw");
    }

    function test_DonationIsAbsorbedIntoIdle() public {
        _deposit(alice, 1_000e18);

        vm.prank(bob);
        assertTrue(asset.transfer(address(vault), 500e18), "donation sent");

        // Untracked inflow does not silently reprice shares inside a view...
        assertEq(vault.totalAssets(), 1_000e18, "stale accounting before sync");
        // ...but it is picked up on the next state changing call and accrues to holders.
        _harvest();
        assertEq(vault.totalIdle(), 500e18, "donation synced into idle");
        assertEq(vault.totalAssets(), 1_500e18, "donation belongs to the existing holders");
    }

    // ---------------------------------------------------------------------
    // Strategy migration
    // ---------------------------------------------------------------------

    function test_SetStrategyMigratesCapital() public {
        _deposit(alice, 1_000e18);

        MockLendingPool newPool = new MockLendingPool(address(asset));
        LendingStrategy newStrategy = new LendingStrategy(address(asset), address(vault), address(this), keeper);
        newStrategy.setLendingPool(address(newPool));
        newPool.setYieldRecipient(address(newStrategy));

        vault.setStrategy(address(newStrategy));

        assertEq(address(vault.strategy()), address(newStrategy), "strategy swapped");
        assertEq(strategy.debt(), 0, "old strategy debt cleared");
        assertEq(pool.balanceOf(address(strategy)), 0, "old pool position closed");
        assertEq(vault.totalDebt(), 1_000e18, "capital redeployed into the new strategy");
        assertEq(newPool.balanceOf(address(newStrategy)), 1_000e18, "new pool position");
        assertEq(vault.totalIdle(), 0, "no capital left idle");
    }

    function test_SetStrategyRequiresZeroDebt() public {
        _deposit(alice, 1_000e18);
        pool.simulateIlliquidity(400e18);

        LendingStrategy newStrategy = new LendingStrategy(address(asset), address(vault), address(this), keeper);
        newStrategy.setLendingPool(address(new MockLendingPool(address(asset))));

        vm.expectRevert(abi.encodeWithSelector(ERC4626Vault.Vault__DebtNotCleared.selector, uint256(400e18)));
        vault.setStrategy(address(newStrategy));
    }

    function test_SetStrategyRejectsMismatchedAsset() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        LendingStrategy newStrategy = new LendingStrategy(address(other), address(vault), address(this), keeper);
        newStrategy.setLendingPool(address(new MockLendingPool(address(other))));

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Vault.Vault__AssetMismatch.selector, address(asset), address(other))
        );
        vault.setStrategy(address(newStrategy));
    }

    function test_SetStrategyRejectsSameStrategy() public {
        vm.expectRevert(abi.encodeWithSelector(ERC4626Vault.Vault__SameStrategy.selector, address(strategy)));
        vault.setStrategy(address(strategy));
    }

    function test_SetStrategyRejectsZeroAddress() public {
        vm.expectRevert(ERC4626Vault.Vault__ZeroAddress.selector);
        vault.setStrategy(address(0));
    }

    // ---------------------------------------------------------------------
    // Access control and parameter validation
    // ---------------------------------------------------------------------

    function test_SetStrategyRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.setStrategy(address(0x1234));
    }

    function test_SetPerformanceFeeRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.setPerformanceFee(100);
    }

    function test_SetFeeRecipientRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.setFeeRecipient(alice);
    }

    function test_SetPerformanceFeeAboveMaxReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ERC4626Vault.Vault__FeeTooHigh.selector, uint256(2001), uint256(2000)));
        vault.setPerformanceFee(2_001);
    }

    function test_SetPerformanceFeeAtMaxSucceeds() public {
        vault.setPerformanceFee(2_000);
        assertEq(vault.performanceFee(), 2_000, "20% is the hard cap and is allowed");
    }

    function test_SetPerformanceFeeChangesFeeAmount() public {
        vault.setPerformanceFee(2_000); // 20%
        _deposit(alice, 1_000e18);
        uint256 supplyBefore = vault.totalSupply();
        uint256 assetsBefore = vault.totalAssets();

        _simulateYield(100e18);
        _harvest();

        uint256 feeAssets = (100e18 * 2_000) / 10_000;
        uint256 expectedShares =
            feeAssets * (supplyBefore + 10 ** vault.DECIMALS_OFFSET()) / (assetsBefore + 100e18 + 1 - feeAssets);
        assertEq(vault.balanceOf(feeRecipient), expectedShares, "fee follows the configured rate");
        assertApproxEqAbs(vault.convertToAssets(expectedShares), feeAssets, 1, "fee is worth 20% of the profit");
    }

    function test_SetFeeRecipientUpdatesEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit ERC4626Vault.FeeRecipientUpdated(feeRecipient, bob);
        vault.setFeeRecipient(bob);
        assertEq(vault.feeRecipient(), bob, "recipient updated");
    }

    function test_SetFeeRecipientRejectsZeroAddress() public {
        vm.expectRevert(ERC4626Vault.Vault__ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_SetMaxReportDelayRejectsZero() public {
        vm.expectRevert(ERC4626Vault.Vault__ZeroDelay.selector);
        vault.setMaxReportDelay(0);
    }

    function test_DepositZeroReverts() public {
        vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
        vm.prank(alice);
        vault.deposit(0, alice);
    }

    function test_RedeemZeroReverts() public {
        _deposit(alice, 1_000e18);
        vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
        vm.prank(alice);
        vault.redeem(0, alice, alice);
    }

    function test_DepositToZeroAddressReverts() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(1e18, address(0));
    }

    // ---------------------------------------------------------------------
    // Decimals and dead shares
    // ---------------------------------------------------------------------

    function test_DecimalsMirrorsAsset() public {
        assertEq(vault.decimals(), 18, "18 decimal asset");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        ERC4626Vault sixVault = new ERC4626Vault(IERC20(address(usdc)), address(this), DEPOSIT_LIMIT, 0, feeRecipient);
        assertEq(sixVault.decimals(), 6, "6 decimal asset");
    }

    function test_DecimalsOffsetIsThree() public view {
        assertEq(vault.DECIMALS_OFFSET(), 3, "offset hardcoded to 3");
    }

    function test_DeadSharesMintedOnFirstDeposit() public {
        _deposit(alice, 1e18);

        assertEq(vault.balanceOf(vault.DEAD_ADDRESS()), vault.DEAD_SHARES(), "dead shares minted once");
        assertGt(vault.totalSupply(), vault.DEAD_SHARES(), "depositor shares exist alongside");
    }

    function test_DeadSharesNotMintedTwice() public {
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);

        assertEq(vault.balanceOf(vault.DEAD_ADDRESS()), vault.DEAD_SHARES(), "minted exactly once");
    }

    // ---------------------------------------------------------------------
    // Sweep
    // ---------------------------------------------------------------------

    function test_SweepRescuesForeignToken() public {
        MockERC20 token = new MockERC20("Junk", "JNK", 18);
        token.mint(address(vault), 77e18);

        vault.sweep(address(token));

        assertEq(token.balanceOf(address(this)), 77e18, "rescued to owner");
        assertEq(token.balanceOf(address(vault)), 0, "vault cleared");
    }

    function test_SweepAssetReverts() public {
        _deposit(alice, 1_000e18);
        vm.expectRevert(ERC4626Vault.Vault__CannotSweepAsset.selector);
        vault.sweep(address(asset));
    }

    function test_SweepNothingReverts() public {
        MockERC20 token = new MockERC20("Junk", "JNK", 18);
        vm.expectRevert(ERC4626Vault.Vault__NothingToSweep.selector);
        vault.sweep(address(token));
    }

    // ---------------------------------------------------------------------
    // Inflation / donation attack
    // ---------------------------------------------------------------------

    /**
     * Classic ERC-4626 inflation attack, and why this vault defeats it.
     *
     * Attack against a naive vault (no virtual offset, no dead shares):
     *   1. attacker deposits 1 wei        -> owns 100% of a 1 wei share supply;
     *   2. attacker donates 10 000e18     -> share price explodes;
     *   3. victim deposits 10 000e18      -> floor rounding hands the victim ZERO shares;
     *   4. attacker redeems 1 share       -> walks away with the victim's money.
     *
     * Defence in this vault:
     *   a) `_decimalsOffset() == 3` injects 10**3 virtual shares and 1 virtual asset, so the very
     *      first exchange rate is 1 asset : 1000 shares instead of 1:1 and rounding can never wipe a
     *      deposit down to zero shares unless the donation dwarfs it by ~3 orders of magnitude;
     *   b) `DEAD_SHARES = 1e3` are minted to 0xdEaD on the first deposit, so the attacker can never
     *      be the sole holder of the supply and the donated value is shared with the dead address.
     *   Net effect: the attacker must burn ~2000x the loot to grief, so the attack is unprofitable.
     */
    function test_InflationAttackIsUnprofitable() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        asset.mint(attacker, 10_000e18 + 1);
        asset.mint(victim, 10_000e18);

        // 1. attacker seeds the vault with a single wei
        vm.startPrank(attacker);
        asset.approve(address(vault), type(uint256).max);
        uint256 attackerShares = vault.deposit(1, attacker);
        // 2. attacker donates a huge amount to inflate the share price
        assertTrue(asset.transfer(address(vault), 10_000e18), "donation sent");
        vm.stopPrank();

        assertGt(attackerShares, 0, "attacker got shares");

        // 3. victim deposits at the inflated price
        vm.startPrank(victim);
        asset.approve(address(vault), type(uint256).max);
        uint256 victimShares = vault.deposit(10_000e18, victim);
        vm.stopPrank();

        assertGt(victimShares, 0, "victim must never receive zero shares");

        // 4. victim exits
        vm.prank(victim);
        uint256 victimOut = vault.redeem(victimShares, victim, victim);

        uint256 lossBps = victimOut >= 10_000e18 ? 0 : ((10_000e18 - victimOut) * 10_000) / 10_000e18;
        assertLt(lossBps, 100, "victim loses less than 1%");

        // 5. the attacker is strictly worse off
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);
        assertLt(attackerOut, 10_000e18 + 1, "attack does not pay for itself");
    }

    /// @notice The griefing variant: the attacker deliberately burns capital to force the victim's
    ///         share count to round down to zero. It only works at ~3000x the victim's deposit, and
    ///         the attacker loses more than the victim does.
    function test_GriefingAttackCostsFarMoreThanItSteals() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        uint256 victimDeposit = 1e18;
        // 1000 virtual shares + 1000 dead shares + 1000 attacker shares => the price must be pushed
        // above 3000 wei per share before the victim's shares floor to zero.
        uint256 requiredDonation = victimDeposit * 3_000;

        asset.mint(attacker, requiredDonation + 1);
        asset.mint(victim, victimDeposit);

        vm.startPrank(attacker);
        asset.approve(address(vault), type(uint256).max);
        uint256 attackerShares = vault.deposit(1, attacker);
        assertTrue(asset.transfer(address(vault), requiredDonation), "donation sent");
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(vault), type(uint256).max);
        uint256 victimShares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        assertEq(victimShares, 0, "only at this extreme donation size does the victim round to zero");

        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);

        uint256 attackerSpent = requiredDonation + 1;
        assertLt(attackerOut, attackerSpent, "attacker is underwater");
        assertGt(attackerSpent - attackerOut, victimDeposit, "attacker loses more than the victim loses");
    }

    /// @notice With a donation of the same order of magnitude as the victim deposit, the victim keeps
    ///         essentially everything: the loss is bounded by the virtual-share dilution (~1/2000).
    function test_RealisticDonationCannotDiluteVictim() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        uint256 victimDeposit = 10_000e18;

        asset.mint(attacker, victimDeposit + 1);
        asset.mint(victim, victimDeposit);

        vm.startPrank(attacker);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1, attacker);
        assertTrue(asset.transfer(address(vault), victimDeposit), "donation sent");
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(vault), type(uint256).max);
        uint256 victimShares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        assertGt(victimShares, 0, "victim receives shares");

        vm.prank(victim);
        uint256 out = vault.redeem(victimShares, victim, victim);

        assertGt(out, victimDeposit * 99 / 100, "victim keeps >99% of the deposit");
        assertApproxEqRel(out, victimDeposit, 5e14, "victim keeps >99.9% of the deposit");
    }

    // ---------------------------------------------------------------------
    // Rounding direction
    // ---------------------------------------------------------------------

    function test_PreviewDepositRoundsDown() public {
        _deposit(alice, 1_000e18);
        _simulateYield(333e18);
        _harvest(); // non-round share price, so floor and ceil can differ

        uint256 assets = 1e18 + 1;
        uint256 floorShares = vault.previewDeposit(assets);
        uint256 ceilShares = vault.previewWithdraw(assets);

        assertLe(floorShares, ceilShares, "deposit never mints more shares than a withdrawal burns");
        assertLe(ceilShares - floorShares, 1, "the two directions differ by at most one share");
        assertLe(vault.previewRedeem(floorShares), assets, "floor shares never redeem for more than deposited");
        assertGe(vault.previewRedeem(ceilShares), assets, "ceil shares cover the requested assets");
    }

    function test_PreviewWithdrawRoundsUp() public {
        _deposit(alice, 1_000e18);
        _simulateYield(333e18);
        _harvest();

        uint256 assets = 777e18 + 1;
        uint256 shares = vault.previewWithdraw(assets);

        assertGe(vault.previewRedeem(shares), assets, "rounding up protects the vault");
        assertLt(vault.previewRedeem(shares) - assets, 1e12, "over-charge is dust");
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    /// @notice A deposit/redeem round trip must never create assets out of thin air.
    /// @dev Bootstrapped with an existing position so the virtual-asset `+1` bonus of the very first
    ///      deposit (a deliberate part of the ERC-4626 virtual offset) does not mask a real bug.
    function testFuzz_DepositRedeemNeverProfits(uint96 amount) public {
        _deposit(carol, 1_000_000e18);

        uint256 assetsIn = bound(uint256(amount), 1, INITIAL_BALANCE);
        uint256 shares = _deposit(alice, assetsIn);
        assertGt(shares, 0, "deposit must produce shares");

        uint256 assetsOut = _redeem(alice, shares);
        assertLe(assetsOut, assetsIn, "round trip must not profit");
    }

    /// @notice Harvested yield must never reduce the value of an existing share.
    function testFuzz_SharesMonotonicWithYield(uint96 depositAmount, uint96 yieldAmount) public {
        uint256 depositAssets = bound(uint256(depositAmount), 1e12, 1_000_000e18);
        uint256 yieldAssets = bound(uint256(yieldAmount), depositAssets / 100 + 1, depositAssets);

        uint256 shares = _deposit(alice, depositAssets);
        uint256 valueBefore = vault.convertToAssets(shares);

        _simulateYield(yieldAssets);
        _harvest();

        uint256 valueAfter = vault.convertToAssets(shares);
        assertGe(valueAfter, valueBefore, "share value is monotonic in yield");
        assertGt(valueAfter, valueBefore, "a material yield must actually move the price");
    }

    /// @notice Two users entering at different times share the yield proportionally to their stake.
    function testFuzz_TwoDepositorsShareYieldProportionally(uint96 firstAmount, uint96 secondAmount) public {
        uint256 first = bound(uint256(firstAmount), 1e18, 500_000e18);
        uint256 second = bound(uint256(secondAmount), 1e18, 500_000e18);

        uint256 aliceShares = _deposit(alice, first);
        uint256 bobShares = _deposit(bob, second);

        _simulateYield((first + second) / 10);
        _harvest();

        uint256 aliceOut = vault.convertToAssets(aliceShares);
        uint256 bobOut = vault.convertToAssets(bobShares);

        // Both holders must earn the same proportional return (within rounding dust).
        assertApproxEqRel(aliceOut * 1e18 / first, bobOut * 1e18 / second, 1e12, "equal proportional yield");
        assertGt(aliceOut, first, "alice profits");
        assertGt(bobOut, second, "bob profits");
    }
}
