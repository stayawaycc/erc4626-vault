import { useState } from "react";
import { addresses } from "../config/addresses";
import { shortAddress } from "../lib/format";
import { styles } from "../lib/styles";

/** Contract registry: every deployed address, copyable, for verifying the deployment. */
export function ContractsPanel() {
  const [copied, setCopied] = useState<string | null>(null);

  function copy(label: string, value: string) {
    navigator.clipboard?.writeText(value).then(
      () => {
        setCopied(label);
        setTimeout(() => setCopied(null), 1200);
      },
      () => setCopied(null),
    );
  }

  const entries: Array<[string, string]> = [
    ["ERC4626Vault", addresses.vault],
    ["LendingStrategy", addresses.strategy],
    ["MockLendingPool", addresses.lendingPool],
    ["Asset (MockERC20)", addresses.asset],
    ["Keeper", addresses.keeper],
    ["FeeRecipient", addresses.feeRecipient],
  ];

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>合约地址</h3>

      {entries.map(([label, value]) => (
        <div key={label} style={styles.row}>
          <span style={styles.key}>{label}</span>
          <button
            style={{
              background: "none",
              border: "none",
              padding: 0,
              color: copied === label ? "#9df3cb" : "#a9c6ff",
              cursor: "pointer",
              ...styles.mono,
            }}
            onClick={() => copy(label, value)}
            title={value}
          >
            {copied === label ? "已复制" : shortAddress(value)}
          </button>
        </div>
      ))}

      <div style={styles.hint}>
        地址来自 <code style={styles.mono}>deployments/31337.json</code>，由{" "}
        <code style={styles.mono}>script/Deploy.s.sol</code> 生成。
        本地 Anvil 链 RPC <code style={styles.mono}>http://127.0.0.1:8546</code>，Chain ID 31337。
      </div>
    </div>
  );
}
