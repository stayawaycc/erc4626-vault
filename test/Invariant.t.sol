// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";

/**
 * @title VaultHandler
 * @notice Bounded action surface for the invariant fuzzer. Every action is wrapped in try/catch so a
 *         legitimate revert (limit reached, insufficient shares, ...) never aborts the run.
 *
 *         The ghost ledger tracks shares, never assets. ERC-4626 mandates that `deposit` rounds
 *         shares down and `withdraw` rounds assets down, so an asset-denominated ledger drifts by up
 *         to one share's worth after every action — and with `_decimalsOffset() = 3` one share can
 *         be worth 1e15 asset-wei. Any asset-based assertion would therefore need a tolerance so
 *         wide it would stop detecting real bugs. Share counts are exact: the vault reports exactly
 *         how many shares it minted and burned.
 */
contract VaultHandler is Test {
    ERC4626Vault public immutable vault;
    MockERC20 public immutable asset;
    MockLendingPool public immutable pool;
    LendingStrategy public immutable strategy;

    address[] public actors;
    address internal currentActor;

    /// @notice Shares the handler minted and has not yet burned, across all actors.
    uint256 public ghostTotalShares;
    /// @notice Assets the handler paid to obtain `ghostTotalShares`.
    uint256 public ghostTotalAssetsPaid;
    /// @notice Assets the handler has taken back out.
    uint256 public ghostTotalAssetsOut;
    /// @notice Yield the handler injected into the lending pool, which is a legitimate inflow.
    uint256 public ghostTotalYieldInjected;
    /// @notice Highest share price ever observed, in assets per 1e18 shares.
    uint256 public ghostPeakPricePerShare;
    /// @notice Set to true if a loss is ever simulated; the monotonicity invariants are skipped then.
    bool public ghostLossSimulated;

    modifier useActor(uint256 seed) {
        currentActor = actors[seed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        ERC4626Vault vault_,
        MockERC20 asset_,
        MockLendingPool pool_,
        LendingStrategy strategy_,
        address[] memory actors_
    ) {
        vault = vault_;
        asset = asset_;
        pool = pool_;
        strategy = strategy_;
        actors = actors_;

        ghostPeakPricePerShare = vault.convertToAssets(1e18);

        for (uint256 i = 0; i < actors_.length; ++i) {
            vm.prank(actors_[i]);
            asset_.approve(address(vault_), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    function deposit(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 balance = asset.balanceOf(currentActor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        try vault.deposit(amount, currentActor) returns (uint256 shares) {
            ghostTotalShares += shares;
            ghostTotalAssetsPaid += amount;
        } catch { }
    }

    function mint(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        uint256 balance = asset.balanceOf(currentActor);
        if (balance == 0) return;

        uint256 maxShares = vault.previewDeposit(balance);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);

        uint256 assetsNeeded = vault.previewMint(shares);
        try vault.mint(shares, currentActor) {
            ghostTotalShares += shares;
            ghostTotalAssetsPaid += assetsNeeded;
        } catch { }
    }

    function withdraw(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 maxAssets = vault.maxWithdraw(currentActor);
        if (maxAssets == 0) return;
        amount = bound(amount, 1, maxAssets);

        uint256 sharesBefore = vault.balanceOf(currentActor);
        try vault.withdraw(amount, currentActor, currentActor) {
            ghostTotalShares -= (sharesBefore - vault.balanceOf(currentActor));
            ghostTotalAssetsOut += amount;
        } catch { }
    }

    function redeem(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        uint256 balance = vault.balanceOf(currentActor);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);

        uint256 expectedAssets = vault.previewRedeem(shares);
        try vault.redeem(shares, currentActor, currentActor) returns (uint256 assetsOut) {
            ghostTotalShares -= shares;
            ghostTotalAssetsOut += assetsOut;
            assertLe(assetsOut, expectedAssets, "redeem paid more than previewRedeem");
        } catch { }
    }

    function harvest(uint256) external {
        try vault.harvest() {
            // Record the new peak so the monotonicity invariant can be checked without storing
            // per-step history.
            uint256 price = vault.convertToAssets(1e18);
            if (price > ghostPeakPricePerShare) ghostPeakPricePerShare = price;
        } catch { }
    }

    function simulateYield(uint256 amount) external {
        if (ghostLossSimulated) return;
        amount = bound(amount, 1e15, 100_000e18);
        pool.simulateYield(amount);
        ghostTotalYieldInjected += amount;
    }

    function simulateLoss(uint256 amount) external {
        uint256 position = pool.balanceOf(address(strategy));
        if (position == 0) return;
        amount = bound(amount, 1, position / 10);
        pool.simulateLoss(amount);
        ghostLossSimulated = true;
    }

    function warp(uint256 secondsElapsed) external {
        vm.warp(block.timestamp + bound(secondsElapsed, 1, 30 days));
    }

    /// @notice Sum of every actor's live share balance, read from the vault.
    function vaultShareBalanceSum() external view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += vault.balanceOf(actors[i]);
        }
    }
}

/**
 * @title InvariantTest
 * @notice Stateful fuzzing of the vault's core safety properties.
 * @dev The properties below are chosen so that each one is either exactly checkable or explicitly
 *      scoped to the states where it is meant to hold. A loose assertion with a magic tolerance is
 *      worse than no assertion: it passes for the wrong reasons and hides real regressions.
 */
contract InvariantTest is Test {
    ERC4626Vault internal vault;
    MockERC20 internal asset;
    MockLendingPool internal pool;
    LendingStrategy internal strategy;
    VaultHandler internal handler;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant INITIAL_BALANCE = 1_000_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20("Mock USD", "mUSD", 18);
        pool = new MockLendingPool(address(asset));
        vault = new ERC4626Vault(IERC20(address(asset)), address(this), 100_000_000e18, 1000, address(this));
        strategy = new LendingStrategy(address(asset), address(vault), address(this), address(this));

        strategy.setLendingPool(address(pool));
        pool.setYieldRecipient(address(strategy));
        vault.setStrategy(address(strategy));

        address[3] memory actorList = [alice, bob, carol];
        for (uint256 i; i < actorList.length; ++i) {
            asset.mint(actorList[i], INITIAL_BALANCE);
        }

        // Seed the vault so the fuzzer does not spend its budget re-testing the empty-vault branch.
        asset.mint(address(this), 10_000e18);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e18, address(this));

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        handler = new VaultHandler(vault, asset, pool, strategy, actors);

        targetContract(address(handler));
    }

    /// @notice The accounting identity the whole design rests on.
    function invariant_TotalAssetsEqualsIdlePlusDebt() public view {
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "totalAssets != totalIdle + totalDebt");
    }

    /// @notice The vault must never claim more debt than the strategy actually holds.
    ///
    /// @dev Skipped once a loss is simulated. A loss is reported through `harvest`, so between the
    ///      loss occurring and the next harvest the vault's nominal `totalDebt` legitimately exceeds
    ///      the strategy's real assets. That window is the point of the report mechanism, not a
    ///      violation — asserting through it would demand the vault read the strategy's live balance
    ///      on every call, which is exactly the design this project rejects.
    function invariant_VaultNeverInsolvent() public view {
        assertGe(vault.totalAssets(), vault.totalDebt(), "debt exceeds total assets");

        if (handler.ghostLossSimulated()) return;

        address current = vault.strategy();
        if (current != address(0)) {
            uint256 strategyAssets = LendingStrategy(current).totalAssets();
            assertLe(vault.totalDebt(), strategyAssets, "vault believes it has more than the strategy holds");
        }
    }

    /// @notice The handler's share ledger must equal the sum of the actors' real balances.
    ///
    /// @dev This is the exact form of "shares are not minted or burned behind a user's back". It has
    ///      no tolerance because share counts are integers that the vault either reports correctly
    ///      or does not: any discrepancy is a bug, not rounding.
    function invariant_HandlerShareLedgerMatchesVault() public view {
        assertEq(
            handler.ghostTotalShares(),
            handler.vaultShareBalanceSum(),
            "handler share ledger diverged from actual balances"
        );
    }

    /// @notice Without a simulated loss, the share price never falls below its recorded peak.
    ///
    /// @dev `convertToAssets(1e18)` is the canonical share price. Deposits, withdrawals and harvests
    ///      must never move it down: deposits round shares down (price unchanged or up), withdrawals
    ///      round assets down (unchanged or up), and a profitable harvest raises it. A decrease means
    ///      value leaked from holders to someone else.
    function invariant_SharePriceNeverDrops() public view {
        if (handler.ghostLossSimulated()) return;

        uint256 price = vault.convertToAssets(1e18);
        assertGe(price, handler.ghostPeakPricePerShare(), "share price dropped without a reported loss");
    }

    /// @notice The vault never pays out more than went in.
    ///
    /// @dev There are exactly three ways assets enter the vault in this handler: a deposit, a mint,
    ///      or simulated yield earned by the strategy. If cumulative withdrawals ever exceed
    ///      deposits + yield, the vault is paying out money it never received. The yield term is
    ///      what makes this an honest solvency check rather than a tautology that only holds while
    ///      no interest accrues.
    function invariant_WithdrawalsNeverExceedInflows() public view {
        if (handler.ghostLossSimulated()) return;
        assertLe(
            handler.ghostTotalAssetsOut(),
            handler.ghostTotalAssetsPaid() + handler.ghostTotalYieldInjected(),
            "withdrew more than was deposited plus earned"
        );
    }

    /// @notice The share supply can never be zero while the vault holds assets.
    function invariant_SupplyNeverZeroWithAssets() public view {
        if (vault.totalAssets() > 0) {
            assertGt(vault.totalSupply(), 0, "assets without shares");
        }
    }

    /// @notice The dead-share floor is never violated: 0xdEaD keeps at least DEAD_SHARES forever.
    function invariant_DeadSharesNeverBurned() public view {
        assertGe(vault.balanceOf(vault.DEAD_ADDRESS()), vault.DEAD_SHARES(), "dead shares were removed");
    }
}
