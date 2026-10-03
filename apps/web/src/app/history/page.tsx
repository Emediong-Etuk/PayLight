"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { formatNgn } from "@paylight/shared";
import { api } from "@/lib/client";
import { useSiwe } from "@/lib/useSiwe";
import { ConnectButton } from "@/components/ConnectButton";

interface Row { orderId: string; status: string; disco: string; serviceID: string; meterNumber: string; meterMasked: string; amountNgn: number; createdAt: string }

export default function HistoryPage() {
  const { isConnected } = useAccount();
  const { signedIn, signIn } = useSiwe();
  const rows = useQuery({ queryKey: ["history", signedIn], queryFn: () => api<Row[]>("/api/orders"), enabled: signedIn });
  return (
    <div className="space-y-4">
      <h1 className="text-3xl font-extrabold">Your purchases</h1>
      {!isConnected ? (
        <ConnectButton />
      ) : !signedIn ? (
        <button className="btn btn-primary w-full" onClick={() => signIn()}>Sign in with your wallet</button>
      ) : rows.isLoading ? (
        <p>Loading…</p>
      ) : !rows.data?.length ? (
        <p className="card p-5">No purchases yet. <Link className="underline" href="/pay">Buy light</Link></p>
      ) : (
        <ul className="space-y-2">
          {rows.data.map((r) => (
            <li key={r.orderId} className="card flex items-center justify-between gap-3 p-4">
              <Link href={`/receipt/${r.orderId}`} className="min-w-0">
                <p className="font-bold">{formatNgn(r.amountNgn)} · {r.disco}</p>
                <p className="text-sm text-muted">Meter {r.meterMasked} · {new Date(r.createdAt).toLocaleString("en-NG")} · {r.status.toLowerCase().replace("_", " ")}</p>
              </Link>
              <Link className="btn btn-ghost !min-h-10 shrink-0 text-sm" href={`/pay?disco=${r.serviceID}&meter=${r.meterNumber}&amount=${r.amountNgn}`}>Buy again</Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
