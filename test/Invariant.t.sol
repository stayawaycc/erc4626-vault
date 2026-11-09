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
 *         legitimate revert (limit reached, insufficient shares, ...) never aborts the run, and the
 *         handler tracks the ghost accounting the invariants are checked against.
 */
contract VaultHandler is Test {
    ERC4626Vault public immutable vault;
    MockERC20 public immutable asset;
    MockLendingPool public immutable pool;
    LendingStrategy public immutable strategy;

    address[] public actors;
    address internal currentActor;

    /// @notice Net assets each actor put in minus what it took out, i.e. the principal at risk.
    mapping(address => uint256) public ghostNetDeposited;
    /// @notice Sum of all `ghostNetDeposited`, used by the solvency invariant.
    uint256 public ghostTotalNetDeposited;
    /// @notice Set to true if a loss is ever simulated; the yield-monotonicity invariant is skipped then.
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

        try vault.deposit(amount, currentActor) {
            ghostNetDeposited[currentActor] += amount;
            ghostTotalNetDeposited += amount;
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
            ghostNetDeposited[currentActor] += assetsNeeded;
            ghostTotalNetDeposited += assetsNeeded;
        } catch { }
    }

    function withdraw(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 maxAssets = vault.maxWithdraw(currentActor);
        if (maxAssets == 0) return;
        amount = bound(amount, 1, maxAssets);

        try vault.withdraw(amount, currentActor, currentActor) {
            _recordOutflow(amount);
        } catch { }
    }

    function redeem(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        uint256 balance = vault.balanceOf(currentActor);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);

        uint256 expectedAssets = vault.previewRedeem(shares);
        try vault.redeem(shares, currentActor, currentActor) returns (uint256 assetsOut) {
            _recordOutflow(assetsOut);
            assertLe(assetsOut, expectedAssets, "redeem paid more than previewRedeem");
        } catch { }
    }

    function harvest(uint256) external {
        try vault.harvest() { } catch { }
    }

    function simulateYield(uint256 amount) external {
        if (ghostLossSimulated) return;
        amount = bound(amount, 1e15, 100_000e18);
        pool.simulateYield(amount);
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

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _recordOutflow(uint256 assetsOut) internal {
        uint256 deposited = ghostNetDeposited[currentActor];
        uint256 reduction = assetsOut < deposited ? assetsOut : deposited;
        ghostNetDeposited[currentActor] = deposited - reduction;
        ghostTotalNetDeposited -= reduction;
    }
}

/**
 * @title InvariantTest
 * @notice Stateful invariants over the vault + strategy + pool system.
 */
contract InvariantTest is Test {
    uint256 internal constant DEPOSIT_LIMIT = 10_000_000e18;

    MockERC20 internal asset;
    MockLendingPool internal pool;
    LendingStrategy internal strategy;
    ERC4626Vault internal vault;
    VaultHandler internal handler;

    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public {
        vm.warp(1_700_000_000);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        asset = new MockERC20("Mock USD", "mUSD", 18);
        pool = new MockLendingPool(address(asset));
        vault = new ERC4626Vault(IERC20(address(asset)), address(this), DEPOSIT_LIMIT, 1_000, makeAddr("fee"));
        strategy = new LendingStrategy(address(asset), address(vault), address(this), makeAddr("keeper"));

        strategy.setLendingPool(address(pool));
        pool.setYieldRecipient(address(strategy));
        vault.setStrategy(address(strategy));

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        for (uint256 i = 0; i < actors.length; ++i) {
            asset.mint(actors[i], 1_000_000e18);
        }

        handler = new VaultHandler(vault, asset, pool, strategy, actors);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.mint.selector;
        selectors[2] = VaultHandler.withdraw.selector;
        selectors[3] = VaultHandler.redeem.selector;
        selectors[4] = VaultHandler.harvest.selector;
        selectors[5] = VaultHandler.simulateYield.selector;
        selectors[6] = VaultHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @notice `totalAssets()` must always be exactly the sum of the tracked idle and debt buckets.
    function invariant_TotalAssetsEqualsIdlePlusDebt() public view {
        assertEq(vault.totalAssets(), vault.totalIdle() + vault.totalDebt(), "accounting identity broken");
    }

    /// @notice The vault must always hold enough assets to cover every outstanding share, and the
    ///         strategy debt must never exceed what the strategy actually has.
    function invariant_VaultNeverInsolvent() public view {
        assertGe(vault.totalAssets(), vault.totalDebt(), "debt exceeds total assets");

        address current = vault.strategy();
        if (current != address(0)) {
            uint256 strategyAssets = LendingStrategy(current).totalAssets();
            assertLe(vault.totalDebt(), strategyAssets, "vault believes it has more than the strategy holds");
        }
    }

    /// @notice Without simulated losses, the sum of what users put in must be fully covered: the vault
    ///         can never owe less than the net principal it took.
    function invariant_SharesNeverWorthLessThanDeposited() public view {
        if (handler.ghostLossSimulated()) return;

        uint256 owedToUsers = vault.convertToAssets(vault.totalSupply() - vault.balanceOf(vault.DEAD_ADDRESS()));
        assertGe(vault.totalAssets(), handler.ghostTotalNetDeposited(), "principal not covered");
        // Every outstanding user share must be redeemable for at least what the fuzzer recorded as net
        // principal, minus the dust held by the dead address and virtual shares.
        assertGe(owedToUsers + 1e6, handler.ghostTotalNetDeposited(), "shares worth less than net deposits");
    }

    /// @notice The share supply can never be zero while the vault holds assets.
    function invariant_SupplyNeverZeroWithAssets() public view {
        if (vault.totalAssets() > 0) {
            assertGt(vault.totalSupply(), 0, "assets without shares");
        }
    }
}
