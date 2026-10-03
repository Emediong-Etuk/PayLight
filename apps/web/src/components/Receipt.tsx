"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useReadContract, useWriteContract, usePublicClient } from "wagmi";
import type { Hex } from "viem";
import { formatNgn, formatUsdt0, groupToken, payLightGatewayAbi } from "@paylight/shared";
import { api, useAppConfig } from "@/lib/client";
import { useSiwe } from "@/lib/useSiwe";
import { ConnectButton } from "./ConnectButton";

interface OrderView {
  orderId: string;
  status: string;
  disco: string;
  meterMasked: string;
  amountNgn: number;
  amountUsdt0: string;
  cashbackUnits: number;
  refundableAt: string | null;
  txPaid: string | null;
  txSettled: string | null;
  txRefund: string | null;
  isOwner: boolean;
  token: string | null;
  units: string | null;
  customerName: string | null;
  payer: string;
}

const STAGES = [
  { key: "paid", label: "Payment received" },
  { key: "vending", label: "Buying your units" },
  { key: "done", label: "Done" },
];
const stageOf = (s: string) =>
  ["QUOTED", "EXPIRED"].includes(s) ? -1 : ["PAID", "MISMATCH"].includes(s) ? 0 : ["PROVIDER_PENDING", "NEEDS_REVIEW"].includes(s) ? 1 : 2;

export function Receipt({ orderId }: { orderId: string }) {
  const { signedIn, signIn } = useSiwe();
  const { isConnected } = useAccount();
  const [copied, setCopied] = useState(false);
  const order = useQuery({
    queryKey: ["order", orderId, signedIn],
    queryFn: () => api<OrderView>(`/api/orders/${orderId}`),
    refetchInterval: (q) => (["SETTLED", "REFUNDED"].includes(q.state.data?.status ?? "") && (q.state.data?.token || !q.state.data?.isOwner) ? false : 2000),
  });
  const o = order.data;
  if (order.isLoading) return <p className="card p-5">Loading…</p>;
  if (!o) return <p className="card p-5">Order not found.</p>;
  const stage = stageOf(o.status);
  const failed = ["PROVIDER_FAILED", "REFUNDING", "REFUNDED"].includes(o.status);

  return (
    <div className="space-y-4">
      {o.status === "QUOTED" && <p className="card p-5">Waiting for your payment to reach X Layer…</p>}

      {!failed && stage >= 0 && (
        <ol className="card space-y-3 p-5">
          {STAGES.map((s, i) => (
            <li key={s.key} className="flex items-center gap-3">
              <span className={`grid h-7 w-7 place-items-center rounded-full text-sm font-bold ${i < stage || (i === 2 && stage === 2) ? "bg-ok text-white" : i === stage ? "bg-brand text-brand-ink animate-pulse" : "bg-surface-2 text-muted"}`}>
                {i < stage || (i === 2 && stage === 2) ? "✓" : i + 1}
              </span>
              <span className={i <= stage ? "font-semibold" : "text-muted"}>{s.label}</span>
            </li>
          ))}
          {o.status === "NEEDS_REVIEW" && <p className="text-sm text-muted">This is taking longer than usual. We’re checking with the electricity company. Your money is safe in escrow; you can claim a full refund after the deadline if it isn’t resolved.</p>}
        </ol>
      )}

      {stage === 2 && !failed && (
        <section className="card space-y-3 p-5 text-center">
          <p className="text-sm font-semibold text-muted">Your meter token</p>
          {o.token ? (
            <>
              <p className="select-all break-words font-mono text-3xl font-extrabold leading-snug tracking-wider">{groupToken(o.token)}</p>
              {o.units && <p className="text-muted">{o.units} units · {o.disco} · meter {o.meterMasked}</p>}
              <button
                className="btn btn-primary w-full"
                onClick={async () => {
                  await navigator.clipboard.writeText(o.token!);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 1500);
                }}
              >
                {copied ? "Copied ✓" : "Copy token"}
              </button>
              <p className="text-sm text-muted">Type this token into your meter keypad and press Enter.</p>
            </>
          ) : !isConnected ? (
            <ConnectButton />
          ) : !signedIn ? (
            <button className="btn btn-primary w-full" onClick={() => signIn().then(() => order.refetch())}>Sign in to show my token</button>
          ) : !o.isOwner ? (
            <p className="text-muted">Only the wallet that paid can see this token.</p>
          ) : (
            <p className="text-muted">Getting your token…</p>
          )}
        </section>
      )}

      {failed && (
        <section className="card space-y-2 p-5">
          <p className="text-lg font-bold">{o.status === "REFUNDED" ? "Refunded" : "We couldn’t complete this purchase"}</p>
          <p className="text-muted">
            {o.status === "REFUNDED"
              ? `${formatUsdt0(BigInt(o.amountUsdt0))} USD₮0 has been returned to your wallet.`
              : "The electricity company declined this purchase. Your full payment is being refunded automatically."}
          </p>
        </section>
      )}

      <SelfRefund order={o} />

      <section className="card space-y-1 p-5 text-sm">
        <p><b>{formatNgn(o.amountNgn)}</b> · {o.disco} · meter {o.meterMasked}</p>
        <p>Paid {formatUsdt0(BigInt(o.amountUsdt0))} USD₮0{o.cashbackUnits > 0 ? ` · cashback ${o.cashbackUnits} transistors` : ""}</p>
        <p className="flex flex-wrap gap-x-4 pt-1 text-muted">
          {o.txPaid && <a className="underline" href={o.txPaid} target="_blank" rel="noreferrer">Payment tx</a>}
          {o.txSettled && <a className="underline" href={o.txSettled} target="_blank" rel="noreferrer">Settlement tx</a>}
          {o.txRefund && <a className="underline" href={o.txRefund} target="_blank" rel="noreferrer">Refund tx</a>}
        </p>
      </section>
      <Link href="/pay" className="btn btn-ghost w-full">Buy again</Link>
      <p className="text-center text-sm text-muted">Problem? <Link className="underline" href="/help">Get help</Link></p>
    </div>
  );
}

/** Works even if the PayLight backend is down: reads the order on-chain and calls claimRefund directly. */
function SelfRefund({ order }: { order: OrderView }) {
  const { data: cfg } = useAppConfig();
  const pub = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const [msg, setMsg] = useState<string | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 10_000);
    return () => clearInterval(t);
  }, []);
  const onchain = useReadContract({
    address: cfg?.gateway ?? undefined,
    abi: payLightGatewayAbi,
    functionName: "getOrder",
    args: [order.orderId as Hex],
    chainId: cfg?.chainId,
    query: { enabled: !!cfg?.gateway, refetchInterval: 15_000 },
  });
  const o = onchain.data as { status: number; refundableAt: bigint } | undefined;
  if (!o || o.status !== 1 || !cfg?.gateway) return null;
  const refundableAt = Number(o.refundableAt);
  if (now <= refundableAt) return null;
  return (
    <section className="card space-y-2 border-2 border-brand p-5">
      <p className="font-bold">This order wasn’t completed in time</p>
      <p className="text-sm text-muted">You can take your full payment back now, straight from the smart contract. No need to contact us.</p>
      <button
        className="btn btn-primary w-full"
        onClick={async () => {
          try {
            setMsg("Confirm in your wallet…");
            const hash = await writeContractAsync({ address: cfg.gateway!, abi: payLightGatewayAbi, functionName: "claimRefund", args: [order.orderId as Hex], chainId: cfg.chainId });
            await pub?.waitForTransactionReceipt({ hash });
            setMsg("Refunded ✓");
            void onchain.refetch();
          } catch (e) {
            setMsg((e as Error).message.split("\n")[0]!);
          }
        }}
      >
        Claim refund
      </button>
      {msg && <p className="text-sm">{msg}</p>}
    </section>
  );
}
