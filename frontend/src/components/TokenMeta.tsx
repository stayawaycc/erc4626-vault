import { useReadContract } from "wagmi";
import { addresses } from "../config/addresses";
import { erc20Abi } from "../config/abi";
import { formatAmount, shortAddress } from "../lib/format";
import { styles } from "../lib/styles";

/**
 * Asset metadata resolver. The vault has exactly one underlying asset, so this is simpler than
 * the AMM's per-token hook — but the decimals still must come from the contract, never assumed.
 */
export function useAssetMeta() {
  const { data: symbol } = useReadContract({
    address: addresses.asset,
    abi: erc20Abi,
    functionName: "symbol",
    query: { staleTime: Infinity },
  });

  const { data: decimals } = useReadContract({
    address: addresses.asset,
    abi: erc20Abi,
    functionName: "decimals",
    query: { staleTime: Infinity },
  });

  return {
    symbol: symbol ?? "???",
    decimals: decimals ?? 18,
  };
}

/** A single labelled row inside a card. */
export function StatRow({ label, value }: { label: string; value: string }) {
  return (
    <div style={styles.row}>
      <span style={styles.key}>{label}</span>
      <span style={styles.value}>{value}</span>
    </div>
  );
}

/** Displays an asset amount with its symbol. */
export function AssetAmount({ amount }: { amount: bigint | undefined }) {
  const meta = useAssetMeta();
  return (
    <span style={styles.value}>
      {formatAmount(amount, meta.decimals)} {meta.symbol}
    </span>
  );
}

/** Compact address chip for the underlying asset. */
export function AssetChip() {
  const meta = useAssetMeta();
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        padding: "3px 9px",
        borderRadius: 999,
        fontWeight: 600,
        background: "rgba(255,180,80,0.14)",
        border: "1px solid rgba(255,180,80,0.32)",
        color: "#ffcd8a",
        ...styles.mono,
      }}
      title={addresses.asset}
    >
      {meta.symbol} · {shortAddress(addresses.asset)}
    </span>
  );
}
