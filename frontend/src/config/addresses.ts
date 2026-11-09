/**
 * Typed contract addresses for the vault stack.
 *
 * Written by `script/Deploy.s.sol` into `deployments/<chainid>.json` and inlined at build time,
 * so a stale deployment can never silently desync from the UI.
 */
import deployment from "../../../deployments/31337.json";

export interface VaultDeployment {
  asset: `0x${string}`;
  lendingPool: `0x${string}`;
  strategy: `0x${string}`;
  vault: `0x${string}`;
  keeper: `0x${string}`;
  feeRecipient: `0x${string}`;
  performanceFee: number;
  depositLimit: string;
  chainId: number;
}

const raw = deployment as unknown as Record<string, unknown>;

export const addresses: VaultDeployment = {
  asset: raw.asset as `0x${string}`,
  lendingPool: raw.lendingPool as `0x${string}`,
  strategy: raw.strategy as `0x${string}`,
  vault: raw.vault as `0x${string}`,
  keeper: raw.keeper as `0x${string}`,
  feeRecipient: raw.feeRecipient as `0x${string}`,
  performanceFee: Number(raw.performanceFee ?? 0),
  depositLimit: String(raw.depositLimit ?? "0"),
  chainId: Number(raw.chainId ?? 31337),
};

/** Anvil chain id used by `npm run dev:all`. */
export const LOCAL_CHAIN_ID = 31337;

/** Anvil's default port for this project. */
export const RPC_URL = "http://127.0.0.1:8546";
