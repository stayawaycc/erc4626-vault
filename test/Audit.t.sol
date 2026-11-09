// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";

/// @title AuditTest
/// @notice Adversarial probes for the review. Every test here is written to make a specific claim
///         fail if the claim is false; a passing test means the property actually holds.
contract AuditTest is Test {
    ERC4626Vault internal vault;
    MockERC20 internal asset;
    MockLendingPool internal pool;
    LendingStrategy internal strategy;

    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");
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

        asset.mint(alice, 1_000_000e18);
        asset.mint(attacker, 1_000_000e18);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        asset.approve(address(vault), type(uint256).max);
    }

    // =====================================================================
    // Claim 1: "dual-bucket accounting keeps donations out of totalAssets"
    // =====================================================================

    /// @notice A plain transfer into the vault DOES raise totalAssets on the next state-changing call.
    /// @dev This falsifies the README's first defence layer as written. `_syncIdle` reads
    ///      `balanceOf`, so a donation is absorbed into `totalIdle`. The real protection is that the
    ///      absorption cannot happen *inside* the attacker's own deposit transaction.
    function test_DonationDoesRaiseTotalAssets() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        uint256 before = vault.totalAssets();

        // Attacker donates directly to the vault.
        vm.prank(attacker);
        asset.transfer(address(vault), 5_000e18);

        // A view still reports the stale number, because totalAssets() is a pure storage read.
        assertEq(vault.totalAssets(), before, "view should not see the donation yet");

        // But the next state-changing call absorbs it.
        vm.prank(alice);
        vault.deposit(1, alice);

        assertGt(vault.totalAssets(), before, "donation is absorbed into totalIdle on the next touch");
        console2.log("totalAssets before donation :", before);
        console2.log("totalAssets after absorption:", vault.totalAssets());
    }

    /// @notice The classic inflation attack still has to be unprofitable, despite the absorption.
    /// @dev This is the claim that actually matters. If it passes, the design is safe even though the
    ///      README's wording about "not entering totalAssets" is imprecise.
    function test_InflationAttackStillUnprofitable() public {
        // Attacker is first depositor: 1 wei.
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(1, attacker);

        // Attacker donates a large amount to inflate the share price.
        vm.prank(attacker);
        asset.transfer(address(vault), 10_000e18);

        // Victim deposits.
        vm.prank(alice);
        uint256 victimShares = vault.deposit(10_000e18, alice);

        console2.log("attacker shares:", attackerShares);
        console2.log("victim shares  :", victimShares);

        assertGt(victimShares, 0, "victim must receive non-zero shares");

        // Victim's shares must be worth at least ~99% of what they put in.
        uint256 victimValue = vault.convertToAssets(victimShares);
        console2.log("victim value   :", victimValue);
        assertGe(victimValue, 9_900e18, "victim lost more than 1%");

        // Attacker must not profit.
        uint256 attackerValue = vault.convertToAssets(attackerShares);
        assertLe(attackerValue, 10_001e18, "attacker profited from the donation");
    }

    // =====================================================================
    // Claim 2: report() keeps totalAssets == totalIdle + totalDebt
    // =====================================================================

    /// @notice After a profitable harvest, totalAssets must equal idle + debt.
    /// @dev The suspicion: `report` never adds `profit` to `totalDebt`, and `_syncIdle` already
    ///      captured the transferred assets, so the identity may still hold. Verify numerically.
    function test_ReportKeepsAccountingIdentity() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        // Strategy earns 500.
        pool.simulateYield(500e18);

        uint256 idleBefore = vault.totalIdle();
        uint256 debtBefore = vault.totalDebt();
        uint256 assetsBefore = vault.totalAssets();

        vault.harvest();

        uint256 idleAfter = vault.totalIdle();
        uint256 debtAfter = vault.totalDebt();
        uint256 assetsAfter = vault.totalAssets();

        console2.log("idle before/after:", idleBefore, idleAfter);
        console2.log("debt before/after:", debtBefore, debtAfter);
        console2.log("assets before/after:", assetsBefore, assetsAfter);

        assertEq(assetsAfter, idleAfter + debtAfter, "identity broken after harvest");
        assertGt(assetsAfter, assetsBefore, "harvest should increase totalAssets");
    }

    // =====================================================================
    // Claim 3: harvest with a tiny profit cannot be value-destructive via fee minting
    // =====================================================================

    /// @notice A 1-wei profit must not mint a fee share that is worth more than the profit.
    /// @dev With decimalsOffset = 3, one share is worth up to 1e15 asset-wei. If `_sharesForFee`
    ///      rounds up, a 1-wei profit could mint a share worth 1e15 wei, diluting holders far more
    ///      than the fee should.
    function test_TinyProfitDoesNotMintDisproportionateFee() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        uint256 supplyBefore = vault.totalSupply();
        uint256 feeBalanceBefore = vault.balanceOf(feeRecipient);

        // Yield so small that the 10% fee rounds to 0 assets.
        pool.simulateYield(5);
        vault.harvest();

        uint256 mintedFeeShares = vault.balanceOf(feeRecipient) - feeBalanceBefore;
        console2.log("fee shares minted for a 5-wei profit:", mintedFeeShares);

        if (mintedFeeShares > 0) {
            uint256 feeValue = vault.convertToAssets(mintedFeeShares);
            console2.log("value of those shares:", feeValue);
            assertLe(feeValue, 5, "fee share worth more than the profit it was taken from");
        } else {
            assertEq(mintedFeeShares, 0);
        }

        // Supply must not have grown by a meaningful fraction.
        assertApproxEqRel(vault.totalSupply(), supplyBefore, 0.001e18, "supply grew unexpectedly");
    }

    // =====================================================================
    // Claim 4: rounding direction on every preview function
    // =====================================================================

    /// @notice Every preview must round in the vault's favour, never the caller's.
    function test_PreviewRoundingFavoursVault() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);
        pool.simulateYield(1_000e18);
        vault.harvest();

        uint256 assets = 1_000e18;
        uint256 shares = 1_000e18;

        // deposit: shares out must be <= the exact ratio (round down).
        uint256 previewDeposit = vault.previewDeposit(assets);
        uint256 exactDeposit = vault.convertToShares(assets);
        assertLe(previewDeposit, exactDeposit, "previewDeposit rounded up");

        // mint: assets in must be >= the exact ratio (round up).
        uint256 previewMint = vault.previewMint(shares);
        uint256 exactMint = vault.convertToAssets(shares);
        assertGe(previewMint, exactMint, "previewMint rounded down");

        // withdraw: shares burned must be >= the exact ratio (round up).
        uint256 previewWithdraw = vault.previewWithdraw(assets);
        assertGe(previewWithdraw, exactDeposit, "previewWithdraw rounded down");

        // redeem: assets out must be <= the exact ratio (round down).
        uint256 previewRedeem = vault.previewRedeem(shares);
        assertLe(previewRedeem, exactMint, "previewRedeem rounded up");
    }

    // =====================================================================
    // Claim 5: sweep cannot touch the asset or user funds
    // =====================================================================

    function test_SweepCannotTakeAsset() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        vm.expectRevert();
        vault.sweep(address(asset));
    }

    /// @notice Sweeping an unrelated token must not disturb the accounting.
    function test_SweepUnrelatedTokenKeepsAccounting() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        MockERC20 junk = new MockERC20("Junk", "JNK", 18);
        junk.mint(address(vault), 100e18);

        uint256 assetsBefore = vault.totalAssets();
        vault.sweep(address(junk));

        assertEq(junk.balanceOf(address(this)), 100e18);
        assertEq(vault.totalAssets(), assetsBefore, "sweep disturbed totalAssets");
    }

    // =====================================================================
    // Claim 6: setStrategy cannot strand debt
    // =====================================================================

    /// @notice Switching strategy while the old one is illiquid must revert, not silently lose funds.
    function test_SetStrategyRevertsWhenOldStrategyIlliquid() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        // Pull most of the cash out of the lending pool so the strategy cannot divest fully.
        pool.simulateIlliquidity(9_000e18);

        LendingStrategy newStrategy = new LendingStrategy(address(asset), address(vault), address(this), address(this));
        newStrategy.setLendingPool(address(pool));

        vm.expectRevert();
        vault.setStrategy(address(newStrategy));

        // Debt must be unchanged.
        assertGt(vault.totalDebt(), 0, "debt should still be recorded");
    }

    // =====================================================================
    // Claim 7: flash-loan style atomic donation cannot reprice shares
    // =====================================================================

    /// @notice Within one transaction, donating then depositing must not let the attacker mint
    ///         shares for the victim's loss, because `_syncIdle` runs before the deposit computes
    ///         shares but the attacker cannot interleave a second deposit at the inflated price.
    function test_AtomicDonationCannotFrontRunVictim() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        uint256 supplyBefore = vault.totalSupply();

        // Attacker donates then immediately deposits in the same transaction.
        vm.startPrank(attacker);
        asset.transfer(address(vault), 50_000e18);
        uint256 attackerShares = vault.deposit(50_000e18, attacker);
        vm.stopPrank();

        uint256 supplyAfter = vault.totalSupply();
        uint256 shareOfPool = (attackerShares * 1e18) / supplyAfter;

        console2.log("attacker share of pool (1e18 = 100%):", shareOfPool);

        // The attacker put in 50k + 50k donation = 100k against a 10k pool, so they should own
        // roughly 100k/110k = ~90%. They must NOT own materially more than they contributed.
        assertLe(shareOfPool, 0.95e18, "attacker captured more than they contributed");
    }
}
