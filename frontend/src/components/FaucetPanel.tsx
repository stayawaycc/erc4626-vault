import { useState } from "react";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { addresses } from "../config/addresses";
import { erc20Abi } from "../config/abi";
import { formatAmount } from "../lib/format";
import { styles } from "../lib/styles";
import { StatRow, useAssetMeta } from "./TokenMeta";

/**
 * Dev faucet. The demo asset is a `MockERC20` with a public `mint`, so a fresh chain would
 * otherwise be unusable.
 */
export function FaucetPanel() {
  const { address, isConnected } = useAccount();
  const meta = useAssetMeta();
  const [error, setError] = useState<string | null>(null);

  const { data: balance } = useReadContract({
    address: addresses.asset,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { writeContract, data: hash, isPending, error: writeError } = useWriteContract();

  if (writeError && !error) setError(writeError.message.split("\n")[0]);

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>
        测试资产水龙头 <span style={{ ...styles.badge, fontSize: 10, marginLeft: 6 }}>DEV ONLY</span>
      </h3>

      <StatRow label={`${meta.symbol} 余额`} value={formatAmount(balance, meta.decimals)} />

      <div style={{ display: "flex", gap: 8, marginTop: 14 }}>
        <button
          style={{
            ...styles.buttonSecondary,
            flex: 1,
            ...(isConnected && !isPending ? {} : styles.buttonDisabled),
          }}
          disabled={!isConnected || isPending}
          onClick={() =>
            writeContract({
              address: addresses.asset,
              abi: erc20Abi,
              functionName: "mint",
              args: [address!, 10_000n * 10n ** BigInt(meta.decimals)],
            })
          }
        >
          +10,000 {meta.symbol}
        </button>
      </div>

      {hash && (
        <div style={styles.success}>
          铸造中：<span style={styles.mono}>{hash.slice(0, 18)}…</span>
        </div>
      )}
      {error && <div style={styles.error}>{error}</div>}

      <div style={styles.hint}>
        演示资产是 <code style={styles.mono}>MockERC20</code>，mint 无权限限制，仅用于本地开发。
        在真实金库中资产由外部协议发行，不存在这个入口。
      </div>
    </div>
  );
}
