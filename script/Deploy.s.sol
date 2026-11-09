// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626Vault } from "../src/ERC4626Vault.sol";
import { LendingStrategy } from "../src/strategies/LendingStrategy.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockLendingPool } from "../src/mocks/MockLendingPool.sol";

/**
 * @title Deploy
 * @notice Deploys the full stack (asset, lending pool, strategy, vault), wires it up and writes the
 *         resulting addresses to `deployments/<chainid>.json`.
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url local --broadcast
 *   forge script script/Deploy.s.sol            # dry run, still writes the address file
 */
contract Deploy is Script {
    uint256 internal constant INITIAL_MINT = 1_000_000e18;
    uint256 internal constant DEPOSIT_LIMIT = 100_000_000e18;
    uint256 internal constant PERFORMANCE_FEE = 1_000; // 10%
    uint256 internal constant SEED_DEPOSIT = 10_000e18;

    struct Deployment {
        address asset;
        address lendingPool;
        address strategy;
        address vault;
        address feeRecipient;
        address keeper;
        uint256 chainId;
        uint256 depositLimit;
        uint256 performanceFee;
    }

    /// @dev Anvil's first default account. Using its well-known private key as the fallback keeps
    ///      `forge script ... --broadcast` working with zero configuration on a local node, which
    ///      is what "clone and run" requires. On any real network `PRIVATE_KEY` must be set.
    uint256 internal constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", ANVIL_KEY_0);
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        deployment.chainId = block.chainid;
        deployment.feeRecipient = deployer;
        deployment.keeper = deployer;
        deployment.depositLimit = DEPOSIT_LIMIT;
        deployment.performanceFee = PERFORMANCE_FEE;

        // 1. Underlying asset
        MockERC20 asset = new MockERC20("Mock USD", "mUSD", 18);
        deployment.asset = address(asset);

        // 2. Lending venue
        MockLendingPool pool = new MockLendingPool(address(asset));
        deployment.lendingPool = address(pool);

        // 3. Vault
        ERC4626Vault vault =
            new ERC4626Vault(IERC20(address(asset)), deployer, DEPOSIT_LIMIT, PERFORMANCE_FEE, deployer);
        deployment.vault = address(vault);

        // 4. Strategy, wired to the vault and the pool
        LendingStrategy strategy = new LendingStrategy(address(asset), address(vault), deployer, deployer);
        strategy.setLendingPool(address(pool));
        pool.setYieldRecipient(address(strategy));
        deployment.strategy = address(strategy);

        // 5. Activate the strategy on the vault
        vault.setStrategy(address(strategy));

        // 6. Seed liquidity so the deployment is immediately usable
        asset.mint(deployer, INITIAL_MINT);
        asset.approve(address(vault), SEED_DEPOSIT);
        vault.deposit(SEED_DEPOSIT, deployer);

        vm.stopBroadcast();

        _write(deployment);

        console2.log("== ERC4626 yield aggregator deployed ==");
        console2.log("chainId     :", deployment.chainId);
        console2.log("asset       :", deployment.asset);
        console2.log("lendingPool :", deployment.lendingPool);
        console2.log("strategy    :", deployment.strategy);
        console2.log("vault       :", deployment.vault);
        console2.log("seeded      :", SEED_DEPOSIT);
    }

    /// @dev Serializes the deployment record to `deployments/<chainid>.json`.
    function _write(Deployment memory deployment) internal {
        string memory json = vm.serializeUint("deployment", "chainId", deployment.chainId);
        json = vm.serializeAddress("deployment", "asset", deployment.asset);
        json = vm.serializeAddress("deployment", "lendingPool", deployment.lendingPool);
        json = vm.serializeAddress("deployment", "strategy", deployment.strategy);
        json = vm.serializeAddress("deployment", "vault", deployment.vault);
        json = vm.serializeAddress("deployment", "feeRecipient", deployment.feeRecipient);
        json = vm.serializeAddress("deployment", "keeper", deployment.keeper);
        json = vm.serializeUint("deployment", "depositLimit", deployment.depositLimit);
        json = vm.serializeUint("deployment", "performanceFee", deployment.performanceFee);

        string memory path = string.concat("./deployments/", vm.toString(deployment.chainId), ".json");
        vm.writeJson(json, path);
        console2.log("addresses written to", path);
    }
}
