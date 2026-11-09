import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { addresses } from "../config/addresses";
import { erc20Abi, vaultAbi } from "../config/abi";
import { formatAmount, parseAmount } from "../lib/format";
import { styles } from "../lib/styles";
import { StatRow, useAssetMeta } from "./TokenMeta";

/**
 * Inflation-attack lab.
 *
 * This panel exists because the defence is the most interesting thing in the project and it is
 * otherwise invisible: with `_decimalsOffset() = 3` plus the dead-share mint, an attacker who
 * donates assets to move the share price cannot push a victim's shares to zero, and the donation
 * is shared with every existing holder.
 *
 * The panel does not simulate anything — it reports the live numbers so a reviewer can verify the
 * claim on-chain rather than trusting the README.
 */
export function InflationPanel() {
  const { isConnected } = useAccount();
  const meta = useAssetMeta();

  const [donationAmount, setDonationAmount] = useState("");
  const [error, setError] = useState<string | null>(null);

  const { data: totalAssets } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalAssets",
  });

  const { data: shareSupply } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "totalSupply",
  });

  const { data: deadShares } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "DEAD_SHARES",
    query: { staleTime: Infinity },
  });

  const { data: decimalsOffset } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "DECIMALS_OFFSET",
    query: { staleTime: Infinity },
  });

  const { data: deadBalance } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "balanceOf",
    args: ["0x000000000000000000000000000000000000dEaD"],
  });


  const parsedDonation = useMemo(
    () => parseAmount(donationAmount, meta.decimals),
    [donationAmount, meta.decimals],
  );

  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) {
      setDonationAmount("");
      reset();
    }
  }, [isSuccess, reset]);

  useEffect(() => {
    if (writeError) setError(writeError.message.split("\n")[0]);
  }, [writeError]);

  /**
   * What a 1-unit deposit would mint *right now*, which is the number an inflation attack tries to
   * round down to zero. Computed with the same formula the vault uses: shares = assets * (supply +
   * 10**offset) / (totalAssets + 1).
   */
  const oneUnitShares = useMemo(() => {
    if (totalAssets === undefined || shareSupply === undefined || decimalsOffset === undefined) return undefined;
    const offset = 10n ** BigInt(decimalsOffset);
    return (1n * (shareSupply + offset)) / (totalAssets + 1n);
  }, [totalAssets, shareSupply, decimalsOffset]);

  /** Assets needed to make a 1-wei deposit round down to zero shares. */
  const griefingCost = useMemo(() => {
    if (shareSupply === undefined || decimalsOffset === undefined) return undefined;
    const offset = 10n ** BigInt(decimalsOffset);
    // shares = (1 * (supply + offset)) / (assets + 1) == 0  <=>  assets + 1 > supply + offset
    return shareSupply + offset;
  }, [shareSupply, decimalsOffset]);

  function handleDonate() {
    setError(null);
    if (parsedDonation === undefined) return;
    // A plain transfer is exactly the donation vector: it raises the vault's token balance without
    // changing totalIdle or totalDebt, so it cannot inflate totalAssets at all.
    writeContract({
      address: addresses.asset,
      abi: erc20Abi,
      functionName: "transfer",
      args: [addresses.vault, parsedDonation],
    });
  }

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>
        通胀攻击实验台{" "}
        <span style={{ ...styles.badge, fontSize: 10, marginLeft: 6 }}>EDUCATIONAL</span>
      </h3>

      <StatRow label="虚拟份额偏移" value={decimalsOffset !== undefined ? `10^${decimalsOffset}` : "—"} />
      <StatRow label="死份额" value={deadShares !== undefined ? formatAmount(deadShares, 0) : "—"} />
      <StatRow label="0xdEaD 持有份额" value={deadBalance !== undefined ? formatAmount(deadBalance, 18, 6) : "—"} />
      <StatRow label="份额总量" value={shareSupply !== undefined ? formatAmount(shareSupply, 18, 6) : "—"} />
      <StatRow label="总资产" value={`${formatAmount(totalAssets, meta.decimals)} ${meta.symbol}`} />

      <div style={styles.divider} />

      <StatRow
        label="1 wei 存款可换份额"
        value={oneUnitShares !== undefined ? formatAmount(oneUnitShares, 18, 8) : "—"}
      />
      <StatRow
        label="把份额压到 0 的成本"
        value={
          griefingCost !== undefined
            ? `约 ${formatAmount(griefingCost, meta.decimals, 2)} ${meta.symbol}`
            : "—"
        }
      />

      <div style={styles.divider} />

      <label style={styles.label}>直接向金库转账（模拟捐赠攻击）</label>
      <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
        <input
          style={styles.input}
          inputMode="decimal"
          placeholder="0.0"
          value={donationAmount}
          onChange={(e) => {
            setDonationAmount(e.target.value);
            setError(null);
          }}
        />
        <button
          style={styles.buttonSecondary}
          disabled={!isConnected || isPending || parsedDonation === undefined || parsedDonation === 0n}
          onClick={handleDonate}
        >
          转账
        </button>
      </div>

      {hash && (
        <div style={styles.success}>
          交易已提交：<span style={styles.mono}>{hash.slice(0, 18)}…</span>
          {isConfirming && " （确认中）"}
          {isSuccess && " ✅ 已完成"}
        </div>
      )}
      {error && <div style={styles.error}>{error}</div>}

      <div style={styles.hint}>
        转账完成后刷新：<strong>总资产不会变化</strong>，因为{" "}
        <code style={styles.mono}>totalAssets</code> 只读 <code style={styles.mono}>totalIdle + totalDebt</code>。
        这就是第一层防御——捐赠根本不进入记账。
        第二层是 <code style={styles.mono}>_decimalsOffset()</code> 注入的 1000 份虚拟份额，
        它让初始汇率是 1:1000 而不是 1:1，攻击者必须先把价格推高约 1000 倍才能让受害者的份额取整为 0。
        第三层是首笔存款后铸给 <code style={styles.mono}>0xdEaD</code> 的死份额，
        保证供应量永远不会归零。
        <br />
        若你持有资产余额，可在此直接捐赠做对比实验。
      </div>
    </div>
  );
}
