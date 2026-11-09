import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { addresses } from "../config/addresses";
import { erc20Abi, vaultAbi } from "../config/abi";
import { formatAmount, parseAmount } from "../lib/format";
import { styles } from "../lib/styles";
import { useAssetMeta } from "./TokenMeta";

/**
 * Deposit and withdraw panel.
 *
 * Both directions show the ERC-4626 preview values before submitting, so the user sees the exact
 * rounding the contract will apply. Deposits round shares down and withdrawals round assets down,
 * which is why the previewed number is sometimes one wei below a naive division.
 */
export function DepositPanel() {
  const { address, isConnected } = useAccount();
  const meta = useAssetMeta();

  const [mode, setMode] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("");
  const [error, setError] = useState<string | null>(null);

  const parsed = useMemo(
    () => parseAmount(amount, mode === "deposit" ? meta.decimals : 18),
    [amount, mode, meta.decimals],
  );

  const { data: assetBalance } = useReadContract({
    address: addresses.asset,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: shareBalance } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: assetAllowance } = useReadContract({
    address: addresses.asset,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, addresses.vault] : undefined,
    query: { enabled: Boolean(address) },
  });

  // Preview in the direction that matches the current mode.
  const { data: previewShares } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "previewDeposit",
    args: mode === "deposit" && parsed !== undefined ? [parsed] : undefined,
    query: { enabled: mode === "deposit" && parsed !== undefined && parsed > 0n },
  });

  const { data: previewAssets } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "previewRedeem",
    args: mode === "withdraw" && parsed !== undefined ? [parsed] : undefined,
    query: { enabled: mode === "withdraw" && parsed !== undefined && parsed > 0n },
  });

  const { data: maxDeposit } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "maxDeposit",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: maxRedeem } = useReadContract({
    address: addresses.vault,
    abi: vaultAbi,
    functionName: "maxRedeem",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const needsApproval =
    mode === "deposit" &&
    parsed !== undefined &&
    assetAllowance !== undefined &&
    assetAllowance < parsed;

  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) {
      setAmount("");
      reset();
    }
  }, [isSuccess, reset]);

  useEffect(() => {
    if (writeError) setError(writeError.message.split("\n")[0]);
  }, [writeError]);

  function handleApprove() {
    setError(null);
    if (parsed === undefined) return;
    writeContract({
      address: addresses.asset,
      abi: erc20Abi,
      functionName: "approve",
      args: [addresses.vault, parsed],
    });
  }

  function handleDeposit() {
    setError(null);
    if (parsed === undefined || !address) return;
    writeContract({
      address: addresses.vault,
      abi: vaultAbi,
      functionName: "deposit",
      args: [parsed, address],
    });
  }

  function handleRedeem() {
    setError(null);
    if (parsed === undefined || !address) return;
    writeContract({
      address: addresses.vault,
      abi: vaultAbi,
      functionName: "redeem",
      args: [parsed, address, address],
    });
  }

  const canDeposit =
    isConnected &&
    parsed !== undefined &&
    parsed > 0n &&
    !isPending &&
    !needsApproval &&
    (maxDeposit === undefined || parsed <= maxDeposit);

  const canRedeem =
    isConnected &&
    parsed !== undefined &&
    parsed > 0n &&
    !isPending &&
    (maxRedeem === undefined || parsed <= maxRedeem);

  const available =
    mode === "deposit"
      ? assetBalance !== undefined
        ? formatAmount(assetBalance, meta.decimals)
        : "—"
      : shareBalance !== undefined
        ? formatAmount(shareBalance, 18, 6)
        : "—";

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>存入 / 赎回</h3>

      <div style={{ display: "flex", gap: 8, marginBottom: 14 }}>
        <button
          style={{ ...styles.toggle(mode === "deposit"), flex: 1 }}
          onClick={() => {
            setMode("deposit");
            setAmount("");
            setError(null);
          }}
        >
          存入
        </button>
        <button
          style={{ ...styles.toggle(mode === "withdraw"), flex: 1 }}
          onClick={() => {
            setMode("withdraw");
            setAmount("");
            setError(null);
          }}
        >
          赎回
        </button>
      </div>

      <label style={styles.label}>
        {mode === "deposit" ? `存入数量 (${meta.symbol})` : "赎回份额 (agSHARE)"}
        <span style={{ float: "right", color: "#6f7b96" }}>可用 {available}</span>
      </label>
      <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
        <input
          style={styles.input}
          inputMode="decimal"
          placeholder="0.0"
          value={amount}
          onChange={(e) => {
            setAmount(e.target.value);
            setError(null);
          }}
        />
        <button
          style={styles.buttonSecondary}
          onClick={() => {
            if (mode === "deposit" && assetBalance !== undefined) {
              setAmount(formatAmount(assetBalance, meta.decimals, meta.decimals));
            } else if (mode === "withdraw" && shareBalance !== undefined) {
              setAmount(formatAmount(shareBalance, 18, 18));
            }
          }}
        >
          最大
        </button>
      </div>

      <div
        style={{
          padding: "12px 14px",
          borderRadius: 10,
          background: "rgba(6,10,22,0.6)",
          border: "1px solid rgba(255,255,255,0.09)",
          marginBottom: 14,
        }}
      >
        <div style={{ ...styles.key, marginBottom: 4 }}>
          {mode === "deposit" ? "预计获得份额" : "预计获得资产"}
        </div>
        <div style={{ ...styles.value, fontSize: 19, fontWeight: 700, color: "#9df3cb" }}>
          {mode === "deposit"
            ? previewShares !== undefined
              ? `${formatAmount(previewShares, 18, 8)} agSHARE`
              : "—"
            : previewAssets !== undefined
              ? `${formatAmount(previewAssets, meta.decimals, 8)} ${meta.symbol}`
              : "—"}
        </div>
      </div>

      {mode === "deposit" && maxDeposit !== undefined && (
        <div style={styles.row}>
          <span style={styles.key}>本次可存上限</span>
          <span style={styles.value}>{formatAmount(maxDeposit, meta.decimals)} {meta.symbol}</span>
        </div>
      )}
      {mode === "withdraw" && maxRedeem !== undefined && (
        <div style={styles.row}>
          <span style={styles.key}>本次可赎上限</span>
          <span style={styles.value}>{formatAmount(maxRedeem, 18, 6)} agSHARE</span>
        </div>
      )}

      <div style={{ marginTop: 16 }}>
        {needsApproval ? (
          <button style={styles.button} disabled={isPending} onClick={handleApprove}>
            {isPending ? "授权中…" : `授权 ${meta.symbol}`}
          </button>
        ) : (
          <button
            style={{
              ...styles.button,
              ...((mode === "deposit" ? canDeposit : canRedeem) ? {} : styles.buttonDisabled),
            }}
            disabled={mode === "deposit" ? !canDeposit : !canRedeem}
            onClick={mode === "deposit" ? handleDeposit : handleRedeem}
          >
            {!isConnected
              ? "请先连接钱包"
              : isPending
                ? "等待钱包确认…"
                : isConfirming
                  ? "上链中…"
                  : mode === "deposit"
                    ? "存入"
                    : "赎回"}
          </button>
        )}
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
        份额精度是 <code style={styles.mono}>assetDecimals + 3</code>（虚拟份额防御通胀攻击的代价）。
        界面上的「份额价值」通过 <code style={styles.mono}>convertToAssets</code> 换算，不要用余额直接除。
      </div>
    </div>
  );
}
