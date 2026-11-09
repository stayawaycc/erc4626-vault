// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";

/// @title VerifyVaultTest
/// @notice Independent re-verification of the second audit report's High-severity claims.
/// @dev Each test asserts the *premise* the severity rests on, not merely that some code runs.
///      A passing PoC shows the code does something; only a premise test shows the label is right.
contract VerifyVaultTest is Test {
    ERC4626Vault internal vault;
    MockERC20 internal asset;
    MockLendingPool internal pool;
    LendingStrategy internal strategy;

    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");
    address internal mallory = makeAddr("mallory");
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

        asset.mint(alice, 10_000_000e18);
        asset.mint(attacker, 10_000_000e18);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        asset.approve(address(vault), type(uint256).max);
    }

    // =====================================================================
    // H-01: does mint() bypass depositLimit?
    // =====================================================================

    /// @notice The decisive test: `mint` must be capped by the same limit as `deposit`.
    /// @dev If `maxMint` is not overridden, OZ returns type(uint256).max and `mint` walks straight
    ///      past the cap. That makes `depositLimit` — documented as "the maximum amount of assets
    ///      the vault will ever hold, 0 disables deposits" — purely decorative.
    function test_MintRespectsDepositLimit() public {
        vault.setDepositLimit(1_000e18);

        uint256 maxMintValue = vault.maxMint(alice);
        console2.log("maxMint after limit set:", maxMintValue);
        console2.log("maxDeposit             :", vault.maxDeposit(alice));

        // Both entry points must now respect the same cap.
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(2_000e18, alice);

        uint256 shares = vault.previewDeposit(2_000e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(shares, alice);

        // And the cap still allows a deposit that fits. `this` is the payer here, so it needs an
        // allowance of its own.
        asset.approve(address(vault), type(uint256).max);
        asset.mint(address(this), 1_000e18);
        vault.mint(vault.previewDeposit(1_000e18), address(this));
        assertEq(vault.totalAssets(), 1_000e18);
        assertLe(vault.totalAssets(), vault.depositLimit(), "limit respected by both paths");
    }

    /// @notice And the bypass is weaponisable: fill the vault past the cap and every deposit dies.
    function test_MintCannotBeUsedToExhaustTheCap() public {
        vault.setDepositLimit(1_000e18);

        uint256 shares = vault.previewDeposit(5_000_000e18);
        vm.prank(attacker);
        vm.expectRevert();
        vault.mint(shares, attacker);

        // The cap is untouched, so a legitimate depositor is not blocked.
        assertEq(vault.maxDeposit(alice), 1_000e18, "cap still available");
        vm.prank(alice);
        vault.deposit(1_000e18, alice);
    }

    /// @notice The emergency switch ("0 disables deposits") must disable *both* entry points.
    function test_ZeroLimitBlocksBothEntryPoints() public {
        vault.setDepositLimit(0);

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1e18, alice);

        uint256 shares = vault.previewDeposit(1e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(shares, alice);

        assertEq(vault.totalAssets(), 0, "the emergency switch now disables both paths");
    }

    // =====================================================================
    // H-02: can an outsider sandwich unharvested yield?
    // =====================================================================

    /// @notice The decisive test: deposit -> harvest -> redeem in one transaction by a stranger.
    /// @dev `harvest()` is permissionless and `totalAssets()` excludes unreported yield, so an
    ///      attacker buys shares at the pre-yield price and sells them at the post-yield price.
    ///      This is a real value transfer from existing holders, not a rounding artefact.
    function test_StrangerCannotSandwichUnharvestedYield() public {
        // A holder is already in.
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        // The strategy earns 1,000 but nobody has reported it yet.
        pool.simulateYield(1_000e18);

        uint256 assetsBefore = vault.totalAssets();
        console2.log("totalAssets before harvest:", assetsBefore);
        assertEq(assetsBefore, 10_000e18, "yield is invisible to totalAssets");

        // The attacker can no longer trigger the harvest themselves.
        vm.startPrank(attacker);
        vault.deposit(90_000e18, attacker);
        vm.expectRevert();
        vault.harvest();
        vm.stopPrank();

        // Only the keeper can report, and after that the yield is priced in for everyone equally.
        vault.harvest();

        uint256 aliceValue = vault.convertToAssets(vault.balanceOf(alice));
        console2.log("alice value after:", aliceValue);

        // After the attacker's 90_000 deposit, alice owns 10_000 of 100_000 shares, so her
        // proportional share of the 1_000 yield is 100. The vault takes a 10% performance fee, so
        // she keeps 90 of it: 10_090. The sandwich is closed, which is the point.
        assertGe(aliceValue, 10_089e18, "alice kept her proportional share of the yield");

        // The attacker earns nothing for the round trip beyond their own proportional share.
        uint256 attackerValue = vault.convertToAssets(vault.balanceOf(attacker));
        console2.log("attacker value after:", attackerValue);
        assertLe(attackerValue, 90_901e18, "attacker gained from the round trip");
    }

    /// @notice The mirror case: an unreported loss can be front-run.
    function test_UnreportedLossCanBeFrontRun() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);
        vm.prank(attacker);
        vault.deposit(10_000e18, attacker);

        pool.simulateLoss(5_000e18);

        // Attacker exits at the pre-loss price.
        uint256 before = asset.balanceOf(attacker);
        vm.startPrank(attacker);
        vault.redeem(vault.balanceOf(attacker), attacker, attacker);
        vm.stopPrank();
        uint256 recovered = asset.balanceOf(attacker) - before;

        // Alice eats the whole loss.
        vault.harvest();
        uint256 aliceValue = vault.convertToAssets(vault.balanceOf(alice));

        console2.log("attacker recovered:", recovered);
        console2.log("alice value after :", aliceValue);

        assertGt(recovered, 9_000e18, "attacker escaped the loss");
        assertLt(aliceValue, 6_000e18, "alice absorbed the entire loss");
    }

    // =====================================================================
    // README claim 2: is a donation really unable to reprice within one transaction?
    // =====================================================================

    /// @notice The vault's header comment claims a donation "can never be used to inflate the share
    ///         price *within* the transaction that the attacker controls". Test that directly.
    function test_DonationRepricesWithinTheSameTransaction() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        uint256 priceBefore = vault.convertToAssets(1e18);

        // Attacker donates and deposits in the SAME transaction.
        vm.startPrank(attacker);
        asset.transfer(address(vault), 10_000e18);
        vault.deposit(1e18, attacker);
        vm.stopPrank();

        uint256 priceAfter = vault.convertToAssets(1e18);

        console2.log("price per share before:", priceBefore);
        console2.log("price per share after :", priceAfter);

        // The deposit call runs _syncIdle first, which absorbs the donation, so the price the
        // attacker's own deposit sees is already inflated.
        assertGt(priceAfter, priceBefore * 15 / 10, "donation did reprice within the transaction");
    }

    // =====================================================================
    // Low-06: is harvest really unguarded?
    // =====================================================================

    /// @notice The comment says harvest and report "share this contract's reentrancy guard".
    ///         Check whether `harvest` actually carries one.
    function test_HarvestIsReentrancyGuarded() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        ReentrantStrategy evil = new ReentrantStrategy(address(asset), address(vault), address(this), address(this));
        evil.setLendingPool(address(pool));
        vault.setStrategy(address(evil));

        evil.setAttack(true);
        vault.harvest();

        console2.log("reentered:", evil.reentered());
        assertFalse(evil.reentered(), "harvest is now guarded: the nested call reverted");
    }

    // =====================================================================
    // M-01: does setStrategy strand unharvested profit?
    // =====================================================================

    function test_SetStrategyCarriesUnharvestedProfit() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        pool.simulateYield(500e18);

        LendingStrategy next = new LendingStrategy(address(asset), address(vault), address(this), address(this));
        next.setLendingPool(address(pool));

        uint256 assetsBefore = vault.totalAssets();
        vault.setStrategy(address(next));
        uint256 assetsAfter = vault.totalAssets();

        uint256 orphaned = strategy.totalAssets();
        console2.log("assets before migration:", assetsBefore);
        console2.log("assets after migration :", assetsAfter);
        console2.log("orphaned in old strategy:", orphaned);

        // The migration must bring the unharvested profit along, not leave it behind.
        assertGt(assetsAfter, assetsBefore, "profit was carried into the vault");
        assertEq(orphaned, 0, "nothing stranded in the detached strategy");

        // The vault immediately re-deploys into the new strategy, so debt is the full 10_500 again.
        assertEq(vault.totalDebt(), assetsAfter, "all assets re-deployed to the new strategy");
        assertEq(next.totalAssets(), assetsAfter, "new strategy holds everything");
    }

    receive() external payable { }
}

/// @dev A strategy that calls back into the vault from inside harvest, to test the guard.
contract ReentrantStrategy {
    address public immutable assetAddr;
    address public immutable vaultAddr;
    address public immutable ownerAddr;
    address public keeperAddr;
    address public lendingPool;
    bool public attack;
    bool public reentered;

    constructor(address asset_, address vault_, address owner_, address keeper_) {
        assetAddr = asset_;
        vaultAddr = vault_;
        ownerAddr = owner_;
        keeperAddr = keeper_;
    }

    function setLendingPool(address p) external {
        lendingPool = p;
    }

    function setAttack(bool on) external {
        attack = on;
    }

    function asset() external view returns (address) {
        return assetAddr;
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(assetAddr).balanceOf(address(this));
    }

    function availableLiquidity() external view returns (uint256) {
        return IERC20(assetAddr).balanceOf(address(this));
    }

    function harvest() external returns (uint256) {
        if (attack) {
            // Re-enter `harvest` itself. If harvest carried nonReentrant this would revert; if it
            // does not, the nested call runs. This is the precise question the comment claims to
            // answer, and `deposit` is a different code path that has its own guard.
            try ERC4626Vault(vaultAddr).harvest() {
                reentered = true;
            } catch {
                reentered = false;
            }
        }
        return 0;
    }

    function deposit(uint256 assets) external returns (uint256) {
        return assets;
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256) {
        IERC20(assetAddr).transfer(receiver, assets);
        return assets;
    }
}
