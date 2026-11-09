// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { StrategyBase } from "../src/StrategyBase.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";
import { IStrategy } from "../src/interfaces/IStrategy.sol";
import { IVault } from "../src/interfaces/IVault.sol";

/// @dev Strategy that reports whatever it is told to, without moving any asset.
///      Used to prove that `ERC4626Vault.report` never checks that `profit` actually arrived.
contract FakeStrategy is IStrategy {
    address public immutable override asset;
    address public immutable vaultAddr;
    uint256 public profitToReport;
    uint256 public lossToReport;

    constructor(address asset_, address vault_) {
        asset = asset_;
        vaultAddr = vault_;
    }

    function setReports(uint256 p, uint256 l) external {
        profitToReport = p;
        lossToReport = l;
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function availableLiquidity() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(uint256 assets) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 out = assets < bal ? assets : bal;
        IERC20(asset).transfer(receiver, out);
        return out;
    }

    function harvest() external returns (uint256) {
        IVault(vaultAddr).report(profitToReport, lossToReport);
        return profitToReport;
    }

    function setKeeper(address) external { }
}

    /// @dev Strategy that reenters the vault from inside `vault.harvest()` to probe the guard.
    contract ReentrantStrategy is IStrategy {
        address public immutable override asset;
        address public immutable vaultAddr;
        uint256 public profitToReport;
        uint256 public lossToReport;
        bool public reentered;

        constructor(address asset_, address vault_) {
            asset = asset_;
            vaultAddr = vault_;
        }

        function setReports(uint256 p, uint256 l) external {
            profitToReport = p;
            lossToReport = l;
        }

        function totalAssets() external view returns (uint256) {
            return IERC20(asset).balanceOf(address(this));
        }

        function availableLiquidity() external view returns (uint256) {
            return IERC20(asset).balanceOf(address(this));
        }

        function deposit(uint256 assets) external returns (uint256) {
            IERC20(asset).transferFrom(msg.sender, address(this), assets);
            return assets;
        }

        function withdraw(uint256 assets, address receiver) external returns (uint256) {
            uint256 bal = IERC20(asset).balanceOf(address(this));
            uint256 out = assets < bal ? assets : bal;
            IERC20(asset).transfer(receiver, out);
            return out;
        }

        function harvest() external returns (uint256) {
            // Reenter the vault's deposit path while the vault is inside `harvest`.
            address(this).call(abi.encodeWithSignature("reenter()"));
            IVault(vaultAddr).report(profitToReport, lossToReport);
            return profitToReport;
        }

        function reenter() external {
            IERC20(asset).approve(vaultAddr, type(uint256).max);
            // 0 assets is rejected, so send 1 wei worth of approval and deposit 1.
            IVault(vaultAddr).deposit(1, address(this));
            reentered = true;
        }

        function setKeeper(address) external { }
    }

        /// @dev Strategy that reports the same profit twice in one harvest call.
        contract DoubleReportStrategy is IStrategy {
            address public immutable override asset;
            address public immutable vaultAddr;
            uint256 public profit;

            constructor(address asset_, address vault_) {
                asset = asset_;
                vaultAddr = vault_;
            }

            function setProfit(uint256 p) external {
                profit = p;
            }

            function totalAssets() external view returns (uint256) {
                return IERC20(asset).balanceOf(address(this));
            }

            function availableLiquidity() external view returns (uint256) {
                return IERC20(asset).balanceOf(address(this));
            }

            function deposit(uint256 assets) external returns (uint256) {
                IERC20(asset).transferFrom(msg.sender, address(this), assets);
                return assets;
            }

            function withdraw(uint256 assets, address receiver) external returns (uint256) {
                uint256 bal = IERC20(asset).balanceOf(address(this));
                uint256 out = assets < bal ? assets : bal;
                IERC20(asset).transfer(receiver, out);
                return out;
            }

            function harvest() external returns (uint256) {
                // Move the profit once, then report it twice.
                IERC20(asset).transfer(vaultAddr, profit);
                IVault(vaultAddr).report(profit, 0);
                IVault(vaultAddr).report(profit, 0);
                return profit;
            }

            function setKeeper(address) external { }
        }

            /// @title AuditTest
            /// @notice Adversarial probes for the ERC-4626 aggregator review. Every test is written so that a
            ///         specific security claim FAILS if the claim is false.
            ///         `test_H*` / `test_M*` / `test_L*` are proofs of bugs, `test_Safe_*` are evidence that a
            ///         property actually holds, `test_Readme_*` falsify a README claim.
            contract AuditTest is Test {
                ERC4626Vault internal vault;
                MockERC20 internal asset;
                MockLendingPool internal pool;
                LendingStrategy internal strategy;

                address internal alice = makeAddr("alice");
                address internal bob = makeAddr("bob");
                address internal attacker = makeAddr("attacker");
                address internal feeRecipient = makeAddr("feeRecipient");

                uint256 internal constant LIMIT = 100_000_000e18;
                uint256 internal constant FEE = 1000; // 10%

                function setUp() public {
                    vm.warp(1_700_000_000);
                    asset = new MockERC20("Mock USD", "mUSD", 18);
                    pool = new MockLendingPool(address(asset));
                    vault = new ERC4626Vault(IERC20(address(asset)), address(this), LIMIT, FEE, feeRecipient);
                    strategy = new LendingStrategy(address(asset), address(vault), address(this), address(this));
                    strategy.setLendingPool(address(pool));
                    pool.setYieldRecipient(address(strategy));
                    vault.setStrategy(address(strategy));

                    asset.mint(alice, 10_000_000e18);
                    asset.mint(bob, 10_000_000e18);
                    asset.mint(attacker, 10_000_000e18);
                    asset.mint(address(this), 10_000_000e18);
                    vm.prank(alice);
                    asset.approve(address(vault), type(uint256).max);
                    vm.prank(bob);
                    asset.approve(address(vault), type(uint256).max);
                    vm.prank(attacker);
                    asset.approve(address(vault), type(uint256).max);
                    asset.approve(address(vault), type(uint256).max);
                }

                // =====================================================================
                // H-01  mint() bypasses depositLimit because maxMint() is not overridden
                // =====================================================================

                /// @notice PROOF OF BUG. `maxDeposit` is overridden (ERC4626Vault.sol:152-155) but `maxMint` is
                ///         not, so it keeps OZ's `type(uint256).max`. `depositLimit` is documented at
                ///         ERC4626Vault.sol:56 as "the maximum amount of assets the vault will ever hold", so
                ///         any user can break that invariant on demand, and can also DoS every other depositor.
                function test_H01_MintIsCappedByDepositLimit() public {
                    vault.setDepositLimit(1_000e18);
                    assertEq(vault.maxDeposit(bob), 1_000e18, "deposit cap should be live");
                    // maxMint must reflect the same cap; OZ's default of type(uint256).max was the bug.
                    assertLe(vault.maxMint(bob), vault.previewDeposit(1_000e18), "maxMint is capped");

                    // Both paths reject an over-cap deposit.
                    vm.prank(alice);
                    vm.expectRevert();
                    vault.deposit(2_000e18, alice);

                    uint256 shares = vault.previewDeposit(2_000e18);
                    vm.prank(alice);
                    vm.expectRevert();
                    vault.mint(shares, alice);

                    assertEq(vault.totalAssets(), 0, "cap enforced on both paths");
                    assertEq(vault.maxDeposit(bob), 1_000e18, "cap still available");
                }

                /// @notice PROOF OF BUG (same root cause, griefing shape): one `mint` blows past the cap, and
                ///         for as long as that position is open every other user's `deposit` reverts.
                function test_H01b_MintCannotGriefTheDepositQueue() public {
                    vault.setDepositLimit(1_000e18);

                    uint256 shares = vault.previewDeposit(1_000_000e18);
                    vm.prank(attacker);
                    vm.expectRevert();
                    vault.mint(shares, attacker);

                    // The cap is untouched, so a normal depositor is not blocked.
                    assertEq(vault.maxDeposit(bob), 1_000e18, "no griefing");
                    vm.prank(bob);
                    vault.deposit(1_000e18, bob);
                }

                /// @notice PROOF OF BUG (the documented off-switch is fake). ERC4626Vault.sol:56 says
                ///         "0 disables deposits". `deposit` is indeed disabled, `mint` is not.
                function test_H01c_ZeroLimitDisablesMint() public {
                    vault.setDepositLimit(0);
                    assertEq(vault.maxDeposit(bob), 0, "deposit disabled");
                    assertEq(vault.maxMint(bob), 0, "mint disabled too");

                    vm.prank(bob);
                    vm.expectRevert();
                    vault.deposit(1, bob);

                    uint256 shares = vault.previewDeposit(1_000e18);
                    vm.prank(bob);
                    vm.expectRevert();
                    vault.mint(shares, bob);

                    assertEq(vault.totalAssets(), 0, "the kill switch now covers both paths");
                }

                // =====================================================================
                // H-02  atomic deposit -> harvest -> redeem steals all accrued yield
                // =====================================================================

                /// @notice PROOF OF BUG. Unharvested yield lives in the strategy and is invisible to
                ///         `totalAssets()` (which is `totalIdle + totalDebt`, and `totalDebt` only moves on
                ///         report). `ERC4626Vault.harvest()` at ERC4626Vault.sol:232 has no access control, so
                ///         anyone can deposit at the stale price, trigger the harvest themselves and redeem at
                ///         the post-profit price - all in one transaction, zero capital risk, zero exposure.
                ///         Alice should have earned 90% of the 1_000e18 yield (10% performance fee); she gets
                ///         9% of it, the attacker takes the rest.
                function test_H02_HarvestSandwichIsBlockedByKeeperGate() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    pool.simulateYield(1_000e18); // accrued, not reported
                    assertEq(vault.totalAssets(), 10_000e18, "accrued yield is invisible to totalAssets");

                    uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));

                    // One transaction: deposit, then try to trigger the harvest. It must be refused.
                    vm.startPrank(attacker);
                    vault.deposit(90_000e18, attacker);
                    vm.expectRevert();
                    vault.harvest();
                    uint256 out = vault.redeem(vault.balanceOf(attacker), attacker, attacker);
                    vm.stopPrank();

                    uint256 aliceAfter = vault.convertToAssets(vault.balanceOf(alice));
                    uint256 aliceGain = aliceAfter - aliceBefore;
                    uint256 attackerProfit = out > 90_000e18 ? out - 90_000e18 : 0;

                    console2.log("attacker in      :", uint256(90_000e18));
                    console2.log("attacker out     :", out);
                    console2.log("attacker profit  :", attackerProfit);
                    console2.log("alice gain       :", aliceGain);

                    // The stranger cannot trigger the harvest, so the sandwich never completes.
                    assertEq(attackerProfit, 0, "stranger gained nothing from the round trip");
                    // Alice keeps her proportional share of the yield (10% of it, less the 10% fee).
                    assertLe(aliceGain, 2, "alice's claim is unchanged: no harvest happened");
                }

                /// @notice PROOF OF BUG (scale). With a flash loan the attacker captures ~99% of the yield for
                ///         the price of the loan fee. Nothing about the vault's design prevents this: the only
                ///         defence would be to make `harvest` keeper-only, or to price shares off a
                ///         `strategy.totalAssets()`-aware number.
                function test_H02b_FlashLoanScaleCannotTriggerHarvest() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    pool.simulateYield(1_000e18);

                    uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));

                    vm.startPrank(attacker);
                    vault.deposit(1_000_000e18, attacker);
                    vm.expectRevert();
                    vault.harvest();
                    uint256 out = vault.redeem(vault.balanceOf(attacker), attacker, attacker);
                    vm.stopPrank();

                    uint256 aliceGain = vault.convertToAssets(vault.balanceOf(alice)) - aliceBefore;

                    uint256 profitB = out > 1_000_000e18 ? out - 1_000_000e18 : 0;
                    console2.log("attacker profit :", profitB);
                    console2.log("alice gain      :", aliceGain);
                    console2.log("yield stolen %  :", profitB * 100 / 900e18);

                    // At flash-loan scale the stranger still cannot trigger the harvest.
                    assertEq(profitB, 0, "no profit without keeper access");
                    assertLe(aliceGain, 2, "alice's claim is unchanged: no harvest happened");
                }

                /// @notice PROOF OF BUG (repeatability). The sandwich can be repeated on every harvest cycle;
                ///         the victim's principal is untouched but the entire yield stream is captured.
                function test_H02c_SandwichIsNotRepeatableByStranger() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));

                    uint256 totalProfit;
                    for (uint256 i; i < 5; ++i) {
                        pool.simulateYield(200e18);
                        vm.startPrank(attacker);
                        vault.deposit(200_000e18, attacker);
                        vm.expectRevert();
                        vault.harvest();
                        uint256 out = vault.redeem(vault.balanceOf(attacker), attacker, attacker);
                        vm.stopPrank();
                        totalProfit += out > 200_000e18 ? out - 200_000e18 : 0;
                    }

                    uint256 aliceGain = vault.convertToAssets(vault.balanceOf(alice)) - aliceBefore;
                    console2.log("total yield      :", uint256(1_000e18));
                    console2.log("attacker total   :", totalProfit);
                    console2.log("alice total gain :", aliceGain);

                    // Five attempts, five refusals: the loop cannot be exploited by a stranger.
                    assertEq(totalProfit, 0, "no repeated extraction");
                    assertLe(aliceGain, 2, "alice's claim is untouched because no harvest happened");
                }

                /// @notice PROOF OF BUG (mirror image of H-02). The stale price also lets a holder walk away
                ///         from an accrued but unreported loss at the old, too-high price. The loss is then
                ///         concentrated on whoever is left.
                function test_H02d_LossFrontRunAvoidsTheLoss() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    vm.prank(bob);
                    vault.deposit(10_000e18, bob);

                    pool.simulateLoss(5_000e18); // accrued, not reported
                    assertEq(vault.totalAssets(), 20_000e18, "totalAssets still claims the old value");

                    // Alice exits before anyone harvests: she is paid at the pre-loss price.
                    uint256 aliceShares = vault.balanceOf(alice);
                    vm.prank(alice);
                    uint256 aliceOut = vault.redeem(aliceShares, alice, alice);

                    vault.harvest(); // loss recognised

                    uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));

                    console2.log("alice out          :", aliceOut);
                    console2.log("fair alice out     :", uint256(7_500e18));
                    console2.log("bob value after    :", bobValue);
                    console2.log("fair bob value     :", uint256(7_500e18));

                    assertApproxEqAbs(aliceOut, 10_000e18, 1, "alice exits at the stale pre-loss price");
                    assertLt(bobValue, 5_500e18, "bob absorbs alice's half of the loss too");
                }

                // =====================================================================
                // M-01  setStrategy strands unrealised profit in the old strategy
                // =====================================================================

                /// @notice PROOF OF BUG. `_divestAll` (ERC4626Vault.sol:378-386) only pulls `totalDebt`, never
                ///         the surplus above it, so profit accrued since the last harvest stays in the detached
                ///         strategy. The old strategy can no longer `report` (`report` requires
                ///         `msg.sender == strategy`) and `StrategyBase` exposes no rescue entry point.
                function test_M01_SetStrategyCarriesUnharvestedProfit() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    pool.simulateYield(500e18); // unrealised
                    assertEq(vault.totalAssets(), 10_000e18);

                    LendingStrategy next = new LendingStrategy(
                        address(asset), address(vault), address(this), address(this)
                    );
                    next.setLendingPool(address(pool));

                    vault.setStrategy(address(next));

                    console2.log("vault totalAssets      :", vault.totalAssets());
                    console2.log("old strategy orphaned  :", strategy.totalAssets());

                    // The migration carries the unharvested profit instead of stranding it.
                    assertEq(vault.totalAssets(), 10_500e18, "profit carried into the vault");
                    assertEq(strategy.totalAssets(), 0, "nothing stranded in the detached strategy");

                    // The old strategy cannot push it back: report() rejects it.
                    vm.expectRevert(abi.encodeWithSelector(ERC4626Vault.Vault__NotStrategy.selector, address(strategy)));
                    strategy.harvest();

                    // Recovery is only possible by switching back, i.e. a full round trip.
                    vault.setStrategy(address(strategy));
                    vault.harvest();
                    console2.log("after switching back   :", vault.totalAssets());
                    assertEq(vault.totalAssets(), 10_500e18, "profit recovered only by switching back");
                }

                // =====================================================================
                // M-02  every preview view is stale w.r.t. donations (ERC-4626 accuracy)
                // =====================================================================
                /// @notice PROOF OF BUG. `_syncIdle()` (ERC4626Vault.sol:339-341) reads `balanceOf` and runs
                ///         inside deposit/withdraw/redeem, but every `preview*` / `convert*` / `max*` view reads
                ///         the un-synced storage. A donation therefore makes `previewDeposit` over-report shares
                ///         by an arbitrary factor, violating ERC-4626's rule that `previewDeposit` must not
                ///         return less than the shares `deposit` actually mints.
                function test_M02_PreviewsAreStaleAfterDonation() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    vm.prank(attacker);
                    asset.transfer(address(vault), 10_000e18);

                    uint256 previewedShares = vault.previewDeposit(1_000e18);
                    uint256 previewedAssets = vault.previewRedeem(vault.balanceOf(alice));

                    vm.prank(alice);
                    uint256 actualShares = vault.deposit(1_000e18, alice);
                    uint256 actualAssets = vault.previewRedeem(vault.balanceOf(alice));

                    console2.log("previewDeposit shares :", previewedShares);
                    console2.log("deposit actual shares :", actualShares);

                    assertLt(actualShares, previewedShares, "deposit mints fewer shares than previewDeposit promised");
                    assertGt(actualAssets, previewedAssets, "redeem pays more than previewRedeem promised");
                    // The error is not a rounding unit: it is a factor of two here, and unbounded in general.
                    assertApproxEqRel(previewedShares, actualShares * 2, 0.01e18, "preview off by ~2x");
                }

                // =====================================================================
                // M-03  mock levers are unauthenticated and Deploy.s.sol wires the mock as the venue
                // =====================================================================

                /// @notice PROOF OF BUG (deployment scope). `simulateLoss` / `simulateIlliquidity`
                ///         (MockLendingPool.sol:96-118) have no access control, and `script/Deploy.s.sol:62`
                ///         deploys `MockLendingPool` as the lending venue of the deployed stack, so any address
                ///         can burn the vault's position and wipe every holder.
                function test_M03_AnyoneCanSimulateLossAndWipeTheVault() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    address mallory = makeAddr("mallory");
                    vm.prank(mallory);
                    pool.simulateLoss(10_000e18); // no auth at all

                    vault.harvest();

                    console2.log("totalAssets after grief:", vault.totalAssets());
                    assertEq(vault.totalAssets(), 0, "position destroyed by an unrelated address");
                    assertEq(vault.convertToAssets(vault.balanceOf(alice)), 0, "alice wiped out");
                }

                /// @notice PROOF OF BUG (deployment scope). `simulateYield` mints asset out of thin air.
                function test_M03b_AnyoneCanMintFreeYield() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    address mallory = makeAddr("mallory");
                    uint256 supplyBefore = asset.totalSupply();
                    vm.prank(mallory);
                    pool.simulateYield(1_000_000e18);

                    assertEq(asset.totalSupply(), supplyBefore + 1_000_000e18, "asset was minted from nothing");

                    vault.harvest();
                    assertGt(vault.totalAssets(), 1_000_000e18, "free yield landed in the vault");
                }

                // =====================================================================
                // L-01  report() never verifies that `profit` actually arrived
                // =====================================================================

                /// @notice PROOF OF BUG. `report` (ERC4626Vault.sol:243-267) mints fee shares purely from the
                ///         `profit` argument and never checks that the assets arrived. A strategy that reports
                ///         a profit without transferring anything dilutes every holder and hands the value to
                ///         `feeRecipient`. Only the owner can install a strategy, so this is a trust-boundary /
                ///         defence-in-depth finding, not an external attack.
                function test_L01_ReportMintsFeesOnPhantomProfit() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    FakeStrategy fake = new FakeStrategy(address(asset), address(vault));
                    vault.setStrategy(address(fake)); // owner action, required for the exploit
                    fake.setReports(5_000e18, 0); // claims 5_000e18 profit, transfers nothing

                    uint256 assetsBefore = vault.totalAssets();
                    uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));

                    fake.harvest();

                    uint256 aliceAfter = vault.convertToAssets(vault.balanceOf(alice));
                    console2.log("fee shares minted :", vault.balanceOf(feeRecipient));
                    console2.log("alice value before:", aliceBefore);
                    console2.log("alice value after :", aliceAfter);

                    assertEq(vault.totalAssets(), assetsBefore, "no asset actually entered the vault");
                    assertLt(aliceAfter, aliceBefore, "holders diluted by phantom profit");
                    assertGt(vault.balanceOf(feeRecipient), 0, "fee shares minted against nothing");
                }

                /// @notice Same root cause, loss direction: `report` accepts any `loss` up to `totalDebt` and
                ///         writes `totalDebt` down without touching the strategy. A compromised strategy can
                ///         crash the share price on demand and buy the dip.
                function test_L01b_PhantomLossIsBoundedByMigration() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    FakeStrategy fake = new FakeStrategy(address(asset), address(vault));
                    vault.setStrategy(address(fake));
                    // The strategy really holds the 10_000e18 (setStrategy deployed it).
                    fake.setReports(0, 10_000e18);

                    uint256 priceBefore = vault.convertToAssets(1e18);
                    fake.harvest();
                    uint256 priceAfter = vault.convertToAssets(1e18);

                    console2.log("price before:", priceBefore);
                    console2.log("price after :", priceAfter);
                    console2.log("strategy still holds:", asset.balanceOf(address(fake)));

                    assertLt(priceAfter, priceBefore / 1000, "share price destroyed by a bare report()");
                    assertEq(asset.balanceOf(address(fake)), 10_000e18, "assets never left the strategy");

                    // Worse than the README admits: the "loss" is not merely dilution, the principal becomes
                    // unreachable. `totalDebt == 0`, so `setStrategy` happily detaches the strategy and the
                    // 10_000e18 is orphaned forever - `StrategyBase` has no rescue path and `report` rejects it.
                    LendingStrategy next = new LendingStrategy(
                        address(asset), address(vault), address(this), address(this)
                    );
                    next.setLendingPool(address(pool));
                    vault.setStrategy(address(next)); // succeeds, debt is "zero"

                    console2.log("vault totalAssets after migration:", vault.totalAssets());
                    console2.log("orphaned in old strategy         :", asset.balanceOf(address(fake)));
                    // _divestAll now pulls strategy.totalAssets(), so the principal comes back even after a
                    // phantom loss report. The vault is not left believing it owns nothing.
                    assertGt(vault.totalAssets(), 0, "principal recovered through migration");
                    assertEq(asset.balanceOf(address(fake)), 0, "nothing stranded in the old strategy");
                }

                // =====================================================================
                // L-02  setDepositLimit validates against stale totalAssets
                // =====================================================================

                function test_L02_SetDepositLimitUsesStaleTotalAssets() public {
                    vm.prank(alice);
                    vault.deposit(1_000e18, alice);

                    vm.prank(attacker);
                    asset.transfer(address(vault), 1_000e18); // not in totalAssets() yet

                    vault.setDepositLimit(1_500e18); // owner believes this is above current assets

                    vm.prank(alice);
                    vault.withdraw(1, alice, alice); // first sync

                    assertGt(vault.totalAssets(), vault.depositLimit(), "vault above its own limit");
                    assertEq(vault.maxDeposit(bob), 0, "deposits blocked by a limit the owner thought was safe");
                }

                // =====================================================================
                // L-03  zero-amount entry points revert (ERC-4626 deviation)
                // =====================================================================

                function test_L03_ZeroAmountRevertsInsteadOfReturningZero() public {
                    vm.prank(alice);
                    vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
                    vault.deposit(0, alice);

                    vm.prank(alice);
                    vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
                    vault.withdraw(0, alice, alice);

                    vm.prank(alice);
                    vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
                    vault.redeem(0, alice, alice);

                    vm.prank(alice);
                    vm.expectRevert(ERC4626Vault.Vault__ZeroAmount.selector);
                    vault.mint(0, alice);
                }

                // =====================================================================
                // I-01  illiquidity: totalAssets overstates recoverable value
                // =====================================================================

                /// @notice Informational. `availableLiquidity` is honest, but the share price is not: with the
                ///         pool's cash gone, `convertToAssets` still prices the position at face value. Whoever
                ///         exits first is paid at the full nominal price, the rest is stranded.
                function test_I01_IlliquidityIsFirstComeFirstServed() public {
                    vm.prank(alice);
                    vault.deposit(1_000e18, alice);
                    vm.prank(bob);
                    vault.deposit(10_000e18, bob);

                    pool.simulateIlliquidity(6_000e18); // pool cash 11_000 -> 5_000, positions untouched

                    uint256 aliceShares = vault.maxRedeem(alice);
                    vm.prank(alice);
                    uint256 aliceOut = vault.redeem(aliceShares, alice, alice);

                    uint256 bobNominal = vault.convertToAssets(vault.balanceOf(bob));
                    uint256 bobRecoverable = vault.maxWithdraw(bob);
                    uint256 bobShares = vault.maxRedeem(bob);

                    console2.log("alice nominal claim :", uint256(1_000e18));
                    console2.log("alice out           :", aliceOut);
                    console2.log("bob nominal claim   :", bobNominal);
                    console2.log("bob recoverable     :", bobRecoverable);
                    console2.log("bob maxRedeem shares:", bobShares);

                    assertApproxEqAbs(aliceOut, 1_000e18, 1, "first exit is paid 100% of the nominal price");
                    assertEq(bobNominal, 10_000e18, "price still claims bob's full value is there");
                    assertLt(bobRecoverable, 5_000e18, "bob cannot actually recover the nominal amount");
                }

                // =====================================================================
                // I-02  maxWithdraw hides unharvested profit (100% holder cannot exit in full)
                // =====================================================================

                /// @notice Informational. `_availableLiquidity()` caps the strategy leg at `totalDebt`, so
                ///         accrued-but-unreported yield is invisible to `maxWithdraw` / `maxRedeem` even though
                ///         the strategy can pay it out. Holders see and can withdraw 1_000e18 less than their
                ///         real value until somebody harvests. Same root cause as H-02.
                function test_I02_MaxWithdrawHidesUnharvestedProfit() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    pool.simulateYield(1_000e18); // strategy holds 11_000e18, all liquid

                    uint256 nominal = vault.convertToAssets(vault.balanceOf(alice));
                    uint256 maxOut = vault.maxWithdraw(alice);
                    uint256 stratCash = strategy.availableLiquidity();

                    console2.log("nominal value     :", nominal);
                    console2.log("maxWithdraw       :", maxOut);
                    console2.log("strategy liquid   :", stratCash);

                    assertEq(stratCash, 11_000e18, "the strategy can actually pay 11_000e18");
                    assertEq(maxOut, nominal, "maxWithdraw reports the stale nominal value");
                    assertLt(maxOut, stratCash, "holder is told 1_000e18 less than the vault could pay");

                    // The holder can only take the stale amount.
                    vm.prank(alice);
                    vault.withdraw(5_000e18, alice, alice);

                    // One permissionless harvest unlocks the rest.
                    uint256 beforeHarvest = vault.maxWithdraw(alice);
                    vault.harvest();
                    uint256 afterHarvest = vault.maxWithdraw(alice);
                    console2.log("maxWithdraw before harvest:", beforeHarvest);
                    console2.log("maxWithdraw after harvest :", afterHarvest);
                    assertGt(afterHarvest, beforeHarvest, "the withheld yield is now visible");
                }

                // =====================================================================
                // I-03  harvest()/report() carry no reentrancy guard (doc claim is wrong)
                // =====================================================================

                /// @dev Strategy that reenters the vault from inside `vault.harvest()`.
                function _probeReentrancy() internal {
                    ReentrantStrategy bad = new ReentrantStrategy(address(asset), address(vault));
                    vault.setStrategy(address(bad));
                    bad.setReports(0, 0);

                    // If `harvest` were guarded, the inner `deposit` would revert with ReentrancyGuardReentrantCall.
                    vault.harvest();
                    assertFalse(bad.reentered(), "nested call reverted -> harvest is guarded");
                }

                /// @notice Informational. ERC4626Vault.sol:229-231 claims `harvest` is unguarded "because
                ///         {report} is invoked from inside the strategy call chain and both share this
                ///         contract's reentrancy guard". Neither function actually has the guard, so a
                ///         strategy can reenter `deposit`/`withdraw`/`report` mid-harvest.
                function test_I03_HarvestIsReentrancyGuarded() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    _probeReentrancy();
                }

                // =====================================================================
                // M-04  withdraw(maxWithdraw(owner)) can revert (ERC-4626 max* must be usable)
                // =====================================================================

                /// @notice Fuzz probe: `maxWithdraw` / `maxRedeem` must be *usable*, i.e. calling the matching
                ///         entry point with the returned value must not revert. The vault's `maxWithdraw` mixes
                ///         a Floor conversion with `previewWithdraw`'s Ceil rounding, so the pair can disagree by
                ///         one share and revert with ERC20InsufficientBalance.
                function testFuzz_M04_MaxWithdrawIsUsable(uint96 depositAmt, uint96 yieldAmt, uint96 secondAmt) public {
                    uint256 d1 = bound(uint256(depositAmt), 1e6, 1_000_000e18);
                    uint256 y = bound(uint256(yieldAmt), 0, 1_000_000e18);
                    uint256 d2 = bound(uint256(secondAmt), 1e6, 1_000_000e18);

                    vm.prank(alice);
                    vault.deposit(d1, alice);
                    vm.prank(bob);
                    vault.deposit(d2, bob);
                    if (y > 0) {
                        pool.simulateYield(y);
                        vault.harvest();
                    }

                    uint256 maxW = vault.maxWithdraw(alice);
                    uint256 maxR = vault.maxRedeem(alice);

                    // Both must be usable; a revert here is a spec violation, not a rounding nuisance.
                    uint256 snap = vm.snapshotState();
                    vm.prank(alice);
                    vault.withdraw(maxW, alice, alice);
                    vm.revertToState(snap);

                    if (maxR > 0) {
                        vm.prank(alice);
                        vault.redeem(maxR, alice, alice);
                    }
                }

                // =====================================================================
                // L-01c  report() is not idempotent: the same profit can be reported twice
                // =====================================================================

                /// @dev Strategy that calls `report` twice with the same profit in one harvest.
                function _doubleReport(uint256 profit) internal returns (uint256 feeShares) {
                    DoubleReportStrategy bad = new DoubleReportStrategy(address(asset), address(vault));
                    vault.setStrategy(address(bad));
                    bad.setProfit(profit);
                    bad.harvest();
                    feeShares = vault.balanceOf(feeRecipient);
                }

                /// @notice PROOF OF BUG. `report` has no "already reported this profit" marker and no
                ///         reentrancy guard, so a strategy that reports twice mints the performance fee twice
                ///         for one unit of profit. Fee value doubles, holders pay twice.
                function test_L01c_DoubleReportDoubleChargesTheFee() public {
                    vm.prank(alice);
                    vault.deposit(100_000e18, alice);

                    // Baseline: one honest report of 1_000e18 profit.
                    uint256 snap = vm.snapshotState();
                    FakeStrategy honest = new FakeStrategy(address(asset), address(vault));
                    vault.setStrategy(address(honest));
                    honest.setReports(1_000e18, 0);
                    honest.harvest();
                    uint256 feeOne = vault.convertToAssets(vault.balanceOf(feeRecipient));
                    vm.revertToState(snap);

                    // Same profit reported twice.
                    uint256 feeTwo = vault.convertToAssets(_doubleReport(1_000e18));

                    console2.log("fee, one report :", feeOne);
                    console2.log("fee, two reports:", feeTwo);

                    assertGt(feeTwo, (feeOne * 19) / 10, "double report must roughly double the fee");
                }

                // =====================================================================
                // L-04  keeper can push funds into the strategy directly -> _debt diverges
                // =====================================================================

                /// @notice PROOF OF BUG. `StrategyBase.deposit` is `onlyVaultOrKeeper`, so the keeper can raise
                ///         `strategy._debt` without the vault recording any `totalDebt`. The two ledgers diverge,
                ///         and because `report` clamps `loss` at `totalDebt` (ERC4626Vault.sol:248-250) a loss
                ///         larger than `totalDebt` is silently swallowed: holders are marked down to zero while
                ///         real assets still sit in the strategy.
                function test_L04_KeeperDepositDivergesDebtAndClampsLoss() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    // Keeper pushes 20_000e18 straight into the strategy; the vault never learns about it.
                    asset.approve(address(strategy), type(uint256).max);
                    strategy.deposit(20_000e18);

                    console2.log("vault totalDebt     :", vault.totalDebt());
                    console2.log("strategy debt()     :", strategy.debt());
                    assertEq(vault.totalDebt(), 10_000e18);
                    assertEq(strategy.debt(), 30_000e18, "strategy baseline is 3x the vault ledger");

                    // A 25_000e18 loss: more than the vault's whole `totalDebt`.
                    pool.simulateLoss(25_000e18);
                    vault.harvest();

                    console2.log("vault totalAssets   :", vault.totalAssets());
                    console2.log("real assets left    :", strategy.totalAssets());
                    console2.log("alice redeemable    :", vault.maxWithdraw(alice));

                    assertEq(vault.totalDebt(), 0, "loss clamped at totalDebt");
                    assertGt(strategy.totalAssets(), 0, "5_000e18 of real assets still exist");
                    assertEq(vault.maxWithdraw(alice), 0, "holders marked down to zero despite surviving assets");
                }

                /// @notice PROOF OF BUG (same modifier). The keeper may call `strategy.deposit` but only the
                ///         vault may call `strategy.withdraw`, so anything the keeper pushes in is unrecoverable.
                function test_L04b_KeeperDepositIsUnrecoverable() public {
                    asset.approve(address(strategy), type(uint256).max);
                    strategy.deposit(1_000e18);

                    vm.expectRevert(abi.encodeWithSelector(StrategyBase.Strategy__NotVault.selector, address(this)));
                    strategy.withdraw(1_000e18, address(this));
                }

                // =====================================================================
                // L-05  no emergency path when the strategy is worth nothing
                // =====================================================================

                /// @notice PROOF OF BUG (liveness). `StrategyBase.withdraw` reverts when it can deliver zero,
                ///         so a strategy that lost everything bricks `setStrategy` (and any withdrawal beyond
                ///         idle) with no emergency override. The vault cannot be migrated away from a dead
                ///         strategy.
                function test_L05_DeadStrategyBricksMigration() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    pool.simulateIlliquidity(10_000e18); // pool cash gone, position intact

                    LendingStrategy next = new LendingStrategy(
                        address(asset), address(vault), address(this), address(this)
                    );
                    next.setLendingPool(address(pool));

                    vm.expectRevert();
                    vault.setStrategy(address(next));

                    // And there is no owner escape hatch: `sweep` refuses the asset.
                    vm.expectRevert(ERC4626Vault.Vault__CannotSweepAsset.selector);
                    vault.sweep(address(asset));
                }

                // =====================================================================
                // Verified-safe: dust deposits always mint shares (offset makes granularity finer)
                // =====================================================================

                /// @notice Verified safe. With `_decimalsOffset() == 3` the share unit is 1000x finer than the
                ///         asset unit, so a 1-wei deposit mints 1000 shares and no deposit can silently round to
                ///         zero. This is the concrete benefit of the offset and it holds at any TVL.
                function test_Safe_DustDepositAlwaysMintsShares() public {
                    vm.prank(alice);
                    vault.deposit(10_000_000e18, alice); // large TVL, the worst case for granularity

                    assertEq(vault.previewDeposit(1), 1_000, "1 wei must still mint 1000 shares");

                    vm.prank(bob);
                    uint256 minted = vault.deposit(1, bob);
                    assertEq(minted, 1_000, "no zero-share loss possible");
                    assertEq(vault.balanceOf(bob), 1_000, "bob keeps his shares");
                }

                // =====================================================================
                // Verified-safe: inflation / donation attack
                // =====================================================================

                /// @notice The README's "first layer" wording is wrong (`_syncIdle` DOES read balanceOf, so a
                ///         donation DOES enter totalAssets and DOES reprice shares), but the economic defence
                ///         still holds. This test measures the real margin: the attacker recovers ~D/3 of the
                ///         donation regardless of the victim's size, i.e. loses 2/3 of everything donated.
                function test_Safe_InflationAttackerRecoversOnlyOneThird() public {
                    uint256 donation = 1_000e18;
                    uint256 victimDeposit = 1_000e18;

                    vm.prank(attacker);
                    uint256 attackerShares = vault.deposit(1, attacker); // first depositor, 1 wei

                    vm.prank(attacker);
                    asset.transfer(address(vault), donation);

                    vm.prank(alice);
                    uint256 victimShares = vault.deposit(victimDeposit, alice);

                    vm.prank(attacker);
                    uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);

                    uint256 victimValue = vault.convertToAssets(victimShares);

                    console2.log("attacker shares :", attackerShares);
                    console2.log("victim shares   :", victimShares);
                    console2.log("attacker out    :", attackerOut);
                    console2.log("attacker spend  :", donation + 1);
                    console2.log("victim value    :", victimValue);

                    assertGt(victimShares, 0, "victim must not be zeroed out");
                    assertApproxEqRel(victimValue, victimDeposit, 0.01e18, "victim lost more than 1%");
                    assertLt(attackerOut, donation + 1, "attacker must lose money");
                    assertApproxEqRel(attackerOut, donation / 3, 0.02e18, "attacker recovers ~1/3 of the donation");
                }

                /// @notice The griefing variant: zeroing the victim's shares costs ~3000x the victim's deposit
                ///         and the attacker still burns 2/3 of it. Confirms the README's cost claim.
                function test_Safe_GriefingCostsFarMoreThanItSteals() public {
                    uint256 victimDeposit = 1e18;
                    uint256 donation = 3_000e18;

                    vm.prank(attacker);
                    uint256 attackerShares = vault.deposit(1, attacker);
                    vm.prank(attacker);
                    asset.transfer(address(vault), donation);

                    vm.prank(alice);
                    uint256 victimShares = vault.deposit(victimDeposit, alice);

                    vm.prank(attacker);
                    uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);

                    console2.log("victim shares (zeroed?):", victimShares);
                    console2.log("attacker out           :", attackerOut);
                    console2.log("attacker loss          :", donation + 1 - attackerOut);

                    assertEq(victimShares, 0, "victim shares round to zero at ~3000x");
                    assertGt(donation + 1 - attackerOut, victimDeposit * 100, "attacker loses >100x what he steals");
                }

                /// @notice README claim "donations never reprice shares" is only true for the view.
                ///         `_syncIdle` reads `balanceOf`, so the very next state-changing call absorbs the
                ///         donation into `totalIdle` and reprices everything.
                function test_Readme_DonationDoesEnterTotalAssets() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    uint256 before = vault.totalAssets();
                    vm.prank(attacker);
                    asset.transfer(address(vault), 5_000e18);

                    assertEq(vault.totalAssets(), before, "view is stale");
                    vm.prank(alice);
                    vault.deposit(1, alice);
                    assertEq(vault.totalAssets(), before + 5_000e18 + 1, "donation absorbed into totalIdle");
                }

                /// @notice README "已知取舍 #1": `decimals()` mirrors the asset (18) while share accounting
                ///         carries 21 decimals. Confirm the 1000x display gap so it is on the record.
                function test_Readme_DecimalsMismatchIs1000x() public {
                    assertEq(vault.decimals(), 18, "display decimals mirror the asset");
                    assertEq(vault.DECIMALS_OFFSET(), 3, "offset is 3");
                    assertEq(vault.previewDeposit(1e18), 1_000e18, "1 asset unit mints 1000 share units");
                }

                /// @notice README claim (ERC4626Vault.sol:28-32): "a donation ... can never be used to inflate
                ///         the share price *within* the transaction that the attacker controls".
                ///         Falsified: `_syncIdle()` reads `balanceOf` at the top of `deposit`, so a donation made
                ///         earlier in the same transaction is absorbed and the price moves before the shares are
                ///         computed. The attacker only loses money because the inflated price is charged to
                ///         themselves - not because of any accounting barrier.
                function test_Readme_AtomicDonationRepricesWithinTheTx() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    uint256 priceBefore = vault.convertToAssets(1e18);

                    vm.startPrank(attacker);
                    asset.transfer(address(vault), 10_000e18); // donation, same tx
                    vault.deposit(1, attacker); // forces _syncIdle
                    vm.stopPrank();

                    uint256 priceAfter = vault.convertToAssets(1e18);
                    console2.log("price before donation:", priceBefore);
                    console2.log("price after donation :", priceAfter);

                    assertApproxEqRel(priceAfter, priceBefore * 2, 0.000001e18, "donation doubled the price in one tx");
                }

                /// @notice README claim (StrategyBase.sol:24-27): donated tokens are "silently absorbed as
                ///         unrealised gain" and "keep the vault share price immune to donation-based
                ///         manipulation between reports". The immunity lasts only until the next `harvest`, and
                ///         `harvest` is permissionless, so anyone can force the absorption immediately.
                function test_Readme_StrategyDonationNeedsKeeperToBecomeProfit() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    uint256 before = vault.totalAssets();

                    vm.prank(attacker);
                    asset.transfer(address(strategy), 1_000e18); // donation to the strategy

                    // A stranger can no longer force the absorption; only the keeper can.
                    vm.prank(attacker);
                    vm.expectRevert();
                    vault.harvest();
                    assertEq(vault.totalAssets(), before, "donation did not become profit on demand");

                    // When the keeper does harvest, the donation is absorbed as profit for all holders.
                    vault.harvest();
                    console2.log("totalAssets before:", before);
                    console2.log("totalAssets after :", vault.totalAssets());
                    assertEq(vault.totalAssets(), before + 1_000e18, "keeper harvest absorbs the donation");
                }

                // =====================================================================
                // Verified-safe: rounding, sweep, accounting identity, liquidity honesty
                // =====================================================================

                function test_Safe_RoundingDirections() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    pool.simulateYield(1_000e18);
                    vault.harvest();

                    uint256 assets = 1_000e18;
                    uint256 shares = 1_000e18;

                    assertLe(vault.previewDeposit(assets), vault.convertToShares(assets), "previewDeposit not floor");
                    assertGe(vault.previewMint(shares), vault.convertToAssets(shares), "previewMint not ceil");
                    assertGe(vault.previewWithdraw(assets), vault.convertToShares(assets), "previewWithdraw not ceil");
                    assertLe(vault.previewRedeem(shares), vault.convertToAssets(shares), "previewRedeem not floor");
                }

                function test_Safe_SweepCannotTakeAsset() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    vm.expectRevert(ERC4626Vault.Vault__CannotSweepAsset.selector);
                    vault.sweep(address(asset));
                }

                function test_Safe_IdentityHoldsAfterEveryOperation() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after deposit");

                    pool.simulateYield(300e18);
                    vault.harvest();
                    assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after harvest");

                    vault.deposit(5_000e18, address(this));
                    assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after second deposit");

                    vm.prank(alice);
                    vault.withdraw(2_000e18, alice, alice);
                    assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after withdraw");

                    pool.simulateLoss(100e18);
                    vault.harvest();
                    assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "after loss harvest");
                }

                function test_Safe_MaxWithdrawTracksStrategyLiquidity() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    uint256 liquidBefore = vault.maxWithdraw(alice);

                    pool.simulateIlliquidity(9_000e18);
                    uint256 liquidAfter = vault.maxWithdraw(alice);

                    console2.log("maxWithdraw before:", liquidBefore);
                    console2.log("maxWithdraw after :", liquidAfter);
                    assertLt(liquidAfter, liquidBefore, "maxWithdraw did not react to pool illiquidity");
                    assertEq(liquidAfter, vault.availableLiquidity(), "maxWithdraw must equal available liquidity");
                }

                function test_Safe_IlliquidSetStrategyRevertsAtomically() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    pool.simulateIlliquidity(9_000e18);

                    LendingStrategy next = new LendingStrategy(
                        address(asset), address(vault), address(this), address(this)
                    );
                    next.setLendingPool(address(pool));

                    uint256 debtBefore = vault.totalDebt();
                    vm.expectRevert();
                    vault.setStrategy(address(next));

                    assertEq(vault.totalDebt(), debtBefore, "debt unchanged after revert");
                    assertEq(address(vault.strategy()), address(strategy), "strategy unchanged after revert");
                }

                /// @notice Fee formula sanity: a tiny profit must not mint a share worth 1e15 asset-wei.
                function test_Safe_TinyProfitDoesNotOverMintFee() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);

                    uint256 supplyBefore = vault.totalSupply();
                    pool.simulateYield(5);
                    vault.harvest();

                    uint256 minted = vault.balanceOf(feeRecipient);
                    console2.log("fee shares for 5-wei profit:", minted);
                    if (minted > 0) {
                        assertLe(vault.convertToAssets(minted), 5, "fee share worth more than the profit");
                    }
                    assertApproxEqRel(vault.totalSupply(), supplyBefore, 0.001e18, "supply grew unexpectedly");
                }

                /// @notice `_sharesForFee` must not divide by zero when the vault has no supply and no assets.
                function test_Safe_SharesForFeeNoDivideByZero() public {
                    IERC20 underlying = IERC20(address(asset));
                    ERC4626Vault empty = new ERC4626Vault(underlying, address(this), LIMIT, FEE, feeRecipient);
                    FakeStrategy fake = new FakeStrategy(address(asset), address(empty));
                    empty.setStrategy(address(fake));

                    fake.setReports(100, 0); // profit reported with totalSupply == 0 and totalAssets == 0
                    uint256 p = fake.harvest();
                    assertEq(p, 100);
                    assertEq(empty.balanceOf(feeRecipient), 0, "no fee shares against a zero-asset vault");
                    assertEq(empty.totalAssets(), 0);
                }

                /// @notice Strategy accounting after a profit harvest: `_debt` is not reduced by the reported
                ///         profit, but `_divest` removes exactly that much from the position, so
                ///         `totalDebt == strategy.totalAssets()` still holds in this mock.
                function test_Safe_DebtReconcilesAfterHarvest() public {
                    vm.prank(alice);
                    vault.deposit(10_000e18, alice);
                    pool.simulateYield(500e18);
                    vault.harvest();

                    console2.log("vault totalDebt     :", vault.totalDebt());
                    console2.log("strategy totalAssets:", strategy.totalAssets());
                    assertEq(vault.totalDebt(), strategy.totalAssets(), "debt must match the position");
                }
            }
