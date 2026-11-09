import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { addresses } from "../config/addresses";
import { lendingPoolAbi, strategyAbi, vaultAbi } from "../config/abi";
import { formatAmount, parseAmount } from "../lib/format";
import { styles } from "../lib/styles";
import { StatRow, useAssetMeta } from "./TokenMeta";

/**
 * Strategy panel: shows where the vault's capital actually sits, and lets the local demo inject
 * yield or loss so the share-price mechanics can be observed end to end.
 *
 * `simulateYield` / `simulateLoss` belong to `MockLendingPool` and exist only because this is a
 * self-contained demo. A real lending integration would earn interest from borrowers.
 */
export function StrategyPanel() {
  const { isConnected } = useAccount();
  const meta = useAssetMeta();

  const [yieldAmount, setYieldAmount] = useState("");
  const [error, setError] = useState<string | null>(null);

  const { data: strategyAssets } = useReadContract({
    address: addresses.strategy,
    abi: strategyAbi,
    functionName: "totalAssets",
  });

  const { data: strategyLiquidity } = useReadContract({
    address: addresses.strategy,
    abi: strategyAbi,
    functionName: "availableLiquidity",
  });

  const { data: estimatedAPY } = useReadContract({
    address: addresses.strategy,
    abi: strategyAbi,
    functionName: "estimatedAPY",
  });

  const { data: keeper } = useReadContract({
    address: addresses.strategy,
    abi: strategyAbi,
    functionName: "keeper",
  });

  const { data: poolBalance } = useReadContract({
    address: addresses.lendingPool,
    abi: lendingPoolAbi,
    functionName: "balanceOf",
    args: [addresses.strategy],
  });

  const { data: harvestNeeded } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "harvestNeeded",
  });

  const { data: totalDebt } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalDebt",
  });

  const parsedYield = useMemo(() => parseAmount(yieldAmount, meta.decimals), [yieldAmount, meta.decimals]);

  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) {
      setYieldAmount("");
      reset();
    }
  }, [isSuccess, reset]);

  useEffect(() => {
    if (writeError) setError(writeError.message.split("\n")[0]);
  }, [writeError]);

  function handleSimulateYield() {
    setError(null);
    if (parsedYield === undefined) return;
    writeContract({
      address: addresses.lendingPool,
      abi: lendingPoolAbi,
      functionName: "simulateYield",
      args: [parsedYield],
    });
  }

  function handleHarvest() {
    setError(null);
    writeContract({
      address: addresses.vault,
      abi: vaultAbi,
      functionName: "harvest",
      args: [],
    });
  }

  const drift =
    totalDebt !== undefined && strategyAssets !== undefined ? strategyAssets - totalDebt : undefined;

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>策略与收益</h3>

      <StatRow label="策略总资产" value={`${formatAmount(strategyAssets, meta.decimals)} ${meta.symbol}`} />
      <StatRow label="策略可动用" value={`${formatAmount(strategyLiquidity, meta.decimals)} ${meta.symbol}`} />
      <StatRow label="借贷池中的头寸" value={`${formatAmount(poolBalance, meta.decimals)} ${meta.symbol}`} />
      <StatRow label="金库记账债务" value={`${formatAmount(totalDebt, meta.decimals)} ${meta.symbol}`} />
      <StatRow
        label="待 harvest 收益"
        value={
          drift !== undefined
            ? `${drift >= 0n ? "+" : ""}${formatAmount(drift, meta.decimals)} ${meta.symbol}`
            : "—"
        }
      />
      <StatRow label="预估 APY" value={estimatedAPY !== undefined ? `${(Number(estimatedAPY) / 100).toFixed(2)}%` : "—"} />
      <StatRow label="keeper" value={keeper ? `${keeper.slice(0, 6)}…${keeper.slice(-4)}` : "—"} />
      <StatRow
        label="是否需要 harvest"
        value={harvestNeeded === undefined ? "—" : harvestNeeded ? "是" : "否"}
      />

      <div style={styles.divider} />

      <label style={styles.label}>注入模拟利息 ({meta.symbol})</label>
      <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
        <input
          style={styles.input}
          inputMode="decimal"
          placeholder="0.0"
          value={yieldAmount}
          onChange={(e) => {
            setYieldAmount(e.target.value);
            setError(null);
          }}
        />
        <button
          style={styles.buttonSecondary}
          disabled={!isConnected || isPending || parsedYield === undefined || parsedYield === 0n}
          onClick={handleSimulateYield}
        >
          注入
        </button>
      </div>

      <button
        style={{
          ...styles.button,
          ...(isConnected && !isPending ? {} : styles.buttonDisabled),
        }}
        disabled={!isConnected || isPending}
        onClick={handleHarvest}
      >
        {isPending ? "等待确认…" : isConfirming ? "上链中…" : "执行 harvest"}
      </button>

      {hash && (
        <div style={styles.success}>
          交易已提交：<span style={styles.mono}>{hash.slice(0, 18)}…</span>
          {isConfirming && " （确认中）"}
          {isSuccess && " ✅ 已完成"}
        </div>
      )}
      {error && <div style={styles.error}>{error}</div>}

      <div style={styles.hint}>
        注入利息后策略的 <code style={styles.mono}>totalAssets</code> 会超过金库记账的{" "}
        <code style={styles.mono}>totalDebt</code>，差额就是待上报的收益。
        <code style={styles.mono}>harvest</code> 把它结算进金库：扣除绩效费后铸给 feeRecipient，
        其余抬高每份份额的价值。
      </div>
    </div>
  );
}
