import { useState } from "react";
import { styles } from "./lib/styles";
import { WalletBar } from "./components/WalletBar";
import { VaultPanel } from "./components/VaultPanel";
import { DepositPanel } from "./components/DepositPanel";
import { StrategyPanel } from "./components/StrategyPanel";
import { InflationPanel } from "./components/InflationPanel";
import { FaucetPanel } from "./components/FaucetPanel";
import { ContractsPanel } from "./components/ContractsPanel";

type Tab = "vault" | "security" | "dev";

/**
 * Application shell.
 *
 * Three tabs: the vault itself, the security lab (the reason this project is interesting), and
 * developer scaffolding. Keeping the attack demo in its own tab stops it from looking like a
 * product feature.
 */
export function App() {
  const [tab, setTab] = useState<Tab>("vault");

  return (
    <div style={styles.app}>
      <div style={styles.container}>
        <header style={styles.header}>
          <div>
            <h1 style={styles.title}>erc4626-vault</h1>
            <p style={styles.subtitle}>
              ERC-4626 收益聚合金库 · 借贷策略 · 通胀攻击防御 — Solidity 0.8.28 / Foundry
            </p>
          </div>
          <WalletBar />
        </header>

        <nav style={styles.tabs}>
          <button style={styles.tab(tab === "vault")} onClick={() => setTab("vault")}>
            金库
          </button>
          <button style={styles.tab(tab === "security")} onClick={() => setTab("security")}>
            安全实验
          </button>
          <button style={styles.tab(tab === "dev")} onClick={() => setTab("dev")}>
            开发工具
          </button>
        </nav>

        {tab === "vault" && (
          <div style={styles.grid}>
            <DepositPanel />
            <VaultPanel />
            <StrategyPanel />
          </div>
        )}

        {tab === "security" && (
          <div style={styles.grid}>
            <InflationPanel />
            <VaultPanel />
          </div>
        )}

        {tab === "dev" && (
          <div style={styles.grid}>
            <FaucetPanel />
            <ContractsPanel />
          </div>
        )}

        <footer style={{ marginTop: 36, color: "#5b6480", fontSize: 11.5, lineHeight: 1.7 }}>
          <div>本地 Anvil 链 · Chain ID 31337 · RPC http://127.0.0.1:8546</div>
          <div>
            <code style={styles.mono}>forge test</code> 运行 86 个测试，包含状态化不变量模糊测试与三个通胀攻击复现。
          </div>
        </footer>
      </div>
    </div>
  );
}
