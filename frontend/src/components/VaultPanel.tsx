import { useReadContract } from "wagmi";
import { addresses } from "../config/addresses";
import { strategyAbi, vaultAbi } from "../config/abi";
import { formatAmount, shortAddress } from "../lib/format";
import { styles } from "../lib/styles";
import { AssetChip, StatRow, useAssetMeta } from "./TokenMeta";

/**
 * Vault overview: the accounting that makes an ERC-4626 vault honest.
 *
 * `totalAssets` is deliberately `totalIdle + totalDebt` rather than `asset.balanceOf(vault)`.
 * Reading the token balance would let anyone inflate the share price by transferring assets in
 * directly; tracking idle and debt separately means only real deposits and real strategy returns
 * move the number.
 */
export function VaultPanel() {
  const meta = useAssetMeta();

  const { data: totalAssets } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalAssets",
  });

  const { data: totalIdle } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalIdle",
  });

  const { data: totalDebt } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalDebt",
  });

  const { data: liquidity } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "availableLiquidity",
  });

  const { data: shareSupply } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalSupply",
  });

  const { data: shareDecimals } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "decimals",
    query: { staleTime: Infinity },
  });

  const { data: depositLimit } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "depositLimit",
  });

  const { data: performanceFee } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "performanceFee",
  });

  const { data: lastReport } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "lastReport",
  });

  const { data: lastProfit } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "lastProfit",
  });

  const { data: strategy } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "strategy",
  });

  const { data: estimatedAPY } = useReadContract({
    address: addresses.strategy,
    abi: strategyAbi,
    functionName: "estimatedAPY",
  });

  // Share price expressed as assets per 1e18 shares. This is the number that must go up over time;
  // it is derived through `convertToAssets`, never by dividing raw balances, because the vault
  // carries 3 extra decimals of internal share precision.
  const { data: pricePerShare } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "convertToAssets",
    args: [10n ** 18n],
  });

  const utilisation =
    totalAssets !== undefined && totalAssets > 0n && totalDebt !== undefined
      ? Number((totalDebt * 10_000n) / totalAssets) / 100
      : null;

  const limitUsed =
    depositLimit !== undefined && depositLimit > 0n && totalAssets !== undefined
      ? Number((totalAssets * 10_000n) / depositLimit) / 100
      : null;

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>金库总览</h3>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14 }}>
        <AssetChip />
      </div>

      <StatRow label="总资产 (totalAssets)" value={`${formatAmount(totalAssets, meta.decimals)} ${meta.symbol}`} />
      <StatRow label="闲置资金 (totalIdle)" value={`${formatAmount(totalIdle, meta.decimals)} ${meta.symbol}`} />
      <StatRow label="策略债务 (totalDebt)" value={`${formatAmount(totalDebt, meta.decimals)} ${meta.symbol}`} />
      <StatRow
        label="可动用流动性"
        value={`${formatAmount(liquidity, meta.decimals)} ${meta.symbol}`}
      />

      <div style={styles.divider} />

      <StatRow
        label="份额总量"
        value={formatAmount(shareSupply, shareDecimals ?? 18, 6)}
      />
      <StatRow
        label="1 份额价值"
        value={`${formatAmount(pricePerShare, meta.decimals, 8)} ${meta.symbol}`}
      />
      <StatRow
        label="资金利用率"
        value={utilisation !== null ? `${utilisation.toFixed(2)}%` : "—"}
      />
      <StatRow
        label="存款上限使用"
        value={limitUsed !== null ? `${limitUsed.toFixed(2)}%` : "—"}
      />

      <div style={styles.divider} />

      <StatRow
        label="绩效费"
        value={performanceFee !== undefined ? `${(Number(performanceFee) / 100).toFixed(2)}%` : "—"}
      />
      <StatRow
        label="策略预估 APY"
        value={estimatedAPY !== undefined ? `${(Number(estimatedAPY) / 100).toFixed(2)}%` : "—"}
      />
      <StatRow
        label="上次 harvest"
        value={
          lastReport !== undefined && lastReport > 0n
            ? new Date(Number(lastReport) * 1000).toLocaleString("zh-CN")
            : "从未"
        }
      />
      <StatRow
        label="上次上报收益"
        value={`${formatAmount(lastProfit, meta.decimals)} ${meta.symbol}`}
      />
      <StatRow label="策略地址" value={shortAddress(strategy)} />

      <div style={styles.hint}>
        <code style={styles.mono}>totalAssets = totalIdle + totalDebt</code>，而不是直接读代币余额。
        直接读余额会让任何人都能通过转账抬高份额价格；分账记账则只有真实存款与策略收益能改变这个数字。
      </div>
    </div>
  );
}
