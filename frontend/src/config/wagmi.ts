import { createConfig, http } from "wagmi";
import { defineChain } from "viem";
import { injected } from "wagmi/connectors";
import { RPC_URL } from "./addresses";

/**
 * The vault project runs its own Anvil instance on port 8546 so it never collides with the
 * AMM project's chain on 8545.
 */
export const anvil = defineChain({
  id: 31337,
  name: "Anvil Local (Vault)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [RPC_URL] },
  },
  testnet: true,
});

export const wagmiConfig = createConfig({
  chains: [anvil],
  connectors: [injected()],
  transports: {
    [anvil.id]: http(RPC_URL),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
