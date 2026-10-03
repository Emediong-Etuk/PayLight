"use client";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { ORDER_STATUSES } from "@paylight/shared";
import { api } from "@/lib/client";
import { useSiwe } from "@/lib/useSiwe";
import { ConnectButton } from "@/components/ConnectButton";

interface AdminOrder { orderId: string; status: string; payer: string; amountNgn: number; serviceID: string; meter: string; providerStatus: string | null; lastError: string | null; updatedAt: string }
interface Cfg { rateKobo: string; spreadBps: number; quotesPaused: boolean; autoPausedReason: string | null; providerFloatNgn: number | null }

export default function AdminPage() {
  const { isConnected } = useAccount();
  const { signedIn, signIn } = useSiwe();
  const [status, setStatus] = useState("NEEDS_REVIEW");
  const [rate, setRate] = useState("");
  const [spread, setSpread] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const cfg = useQuery({ queryKey: ["admin-cfg"], queryFn: () => api<Cfg>("/api/admin/config"), enabled: signedIn });
  const orders = useQuery({ queryKey: ["admin-orders", status], queryFn: () => api<AdminOrder[]>(`/api/admin/orders?status=${status}`), enabled: signedIn, refetchInterval: 10_000 });

  if (!isConnected) return <ConnectButton />;
  if (!signedIn) return <button className="btn btn-primary w-full" onClick={() => signIn()}>Sign in (admin wallet)</button>;
  const act = async (fn: () => Promise<unknown>, ok: string) => {
    try {
      await fn();
      setMsg(ok);
      void cfg.refetch();
      void orders.refetch();
    } catch (e) {
      setMsg((e as Error).message);
    }
  };

  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-extrabold">Admin</h1>
      {msg && <p className="card p-3 text-sm">{msg}</p>}
      <section className="card space-y-2 p-4 text-sm">
        <p>Rate: <b>₦{cfg.data ? (Number(cfg.data.rateKobo) / 100).toFixed(2) : "—"}</b> / USD₮0 · spread {cfg.data?.spreadBps ?? "—"} bps</p>
        <p>VTpass float: <b>{cfg.data?.providerFloatNgn !== null && cfg.data?.providerFloatNgn !== undefined ? `₦${cfg.data.providerFloatNgn.toLocaleString("en-NG")}` : "unreadable"}</b></p>
        <p>Quotes: <b>{cfg.data?.quotesPaused ? "PAUSED" : "live"}</b>{cfg.data?.autoPausedReason ? ` (auto: ${cfg.data.autoPausedReason})` : ""}</p>
        <div className="flex gap-2">
          <input className="input" placeholder="Rate e.g. 1352.50" value={rate} onChange={(e) => setRate(e.target.value)} />
          <input className="input" placeholder="Spread bps" value={spread} onChange={(e) => setSpread(e.target.value)} />
        </div>
        <div className="flex gap-2">
          <button className="btn btn-primary flex-1" onClick={() => act(() => api("/api/admin/config", { json: { ...(rate ? { rate } : {}), ...(spread ? { spreadBps: Number(spread) } : {}) } }), "Saved")}>Save rate</button>
          <button className="btn btn-ghost flex-1" onClick={() => act(() => api("/api/admin/config", { json: { quotesPaused: !cfg.data?.quotesPaused } }), "Toggled")}>{cfg.data?.quotesPaused ? "Resume quotes" : "Pause quotes"}</button>
        </div>
      </section>
      <section className="space-y-2">
        <select className="input" value={status} onChange={(e) => setStatus(e.target.value)}>
          {ORDER_STATUSES.map((s) => <option key={s}>{s}</option>)}
        </select>
        {orders.data?.map((o) => (
          <div key={o.orderId} className="card space-y-1 p-3 text-sm">
            <p className="font-mono">{o.orderId.slice(0, 18)}… · <b>{o.status}</b></p>
            <p>₦{o.amountNgn.toLocaleString("en-NG")} · {o.serviceID} · {o.meter} · payer {o.payer.slice(0, 8)}…</p>
            {o.lastError && <p className="text-danger">{o.lastError}</p>}
            <div className="flex gap-2">
              <a className="btn btn-ghost !min-h-9 flex-1 text-sm" href={`/api/admin/orders/${o.orderId}`} target="_blank" rel="noreferrer">Events</a>
              <button className="btn btn-ghost !min-h-9 flex-1 text-sm" onClick={() => act(() => api(`/api/admin/orders/${o.orderId}/requery`, { method: "POST" }), "Requery scheduled")}>Requery</button>
              <button className="btn btn-ghost !min-h-9 flex-1 text-sm" onClick={() => confirm("Refund this order to the payer?") && act(() => api(`/api/admin/orders/${o.orderId}/refund`, { method: "POST" }), "Refund queued")}>Refund</button>
            </div>
          </div>
        ))}
      </section>
    </div>
  );
}
