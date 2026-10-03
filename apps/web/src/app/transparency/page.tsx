import { prisma } from "@paylight/db";
import { explorerTx, formatNgn, formatUsdt0 } from "@paylight/shared";
import { onchainFacts, teamWallets } from "@/lib/onchain";
import { Addr } from "@/components/Addr";

export const dynamic = "force-dynamic";
export const metadata = { title: "Transparency · PayLight" };

export default async function TransparencyPage() {
  const f = await onchainFacts();
  let totals = { orders: 0, payers: 0, ngn: 0, usdt: 0n, refunds: 0 };
  let payouts: { orderId: string; payer: string; units: number; txHash: string; createdAt: Date }[] = [];
  try {
    const settled = await prisma.order.findMany({ where: { status: "SETTLED" }, select: { payer: true, amount: true, quote: { select: { amountNgn: true } } } });
    totals = {
      orders: settled.length,
      payers: new Set(settled.map((o) => o.payer)).size,
      ngn: settled.reduce((s, o) => s + o.quote.amountNgn, 0),
      usdt: settled.reduce((s, o) => s + o.amount, 0n),
      refunds: await prisma.order.count({ where: { status: "REFUNDED" } }),
    };
    payouts = await prisma.cashbackPayout.findMany({ orderBy: { createdAt: "desc" }, take: 50 });
  } catch {
    /* DB not reachable: show contracts only */
  }
  return (
    <div className="space-y-5">
      <h1 className="text-3xl font-extrabold">Transparency</h1>
      <p className="text-muted">Every figure here comes from on-chain events indexed by our worker. You can check each one on the X Layer explorer.</p>

      <section className="grid grid-cols-2 gap-2 text-center">
        <div className="card p-3"><p className="text-2xl font-extrabold">{totals.orders}</p><p className="text-xs text-muted">bills paid</p></div>
        <div className="card p-3"><p className="text-2xl font-extrabold">{totals.payers}</p><p className="text-xs text-muted">unique customers</p></div>
        <div className="card p-3"><p className="text-2xl font-extrabold">{formatNgn(totals.ngn)}</p><p className="text-xs text-muted">electricity delivered</p></div>
        <div className="card p-3"><p className="text-2xl font-extrabold">{formatUsdt0(totals.usdt)}</p><p className="text-xs text-muted">USD₮0 processed</p></div>
      </section>
      <p className="text-sm text-muted">{totals.refunds} purchases refunded.</p>

      <section className="card space-y-2 p-5 text-sm">
        <h2 className="text-xl font-extrabold">Contracts</h2>
        <p>PayLightGateway (escrow): <Addr a={f.gateway} /></p>
        <p>CashbackRouter (no-sell reserve): <Addr a={f.router} /></p>
        <p>TapeOut processor: <Addr a={f.processor} /></p>
        <p>Transistors: <Addr a={f.transistors} /></p>
      </section>

      <section className="card space-y-2 p-5 text-sm">
        <h2 className="text-xl font-extrabold">Team &amp; protocol wallets</h2>
        {teamWallets().length === 0 ? <p className="text-muted">Published at mainnet launch.</p> : teamWallets().map(([label, a]) => <p key={a}>{label}: <Addr a={a} /></p>)}
      </section>

      <section className="card space-y-2 p-5 text-sm">
        <h2 className="text-xl font-extrabold">No-sell policy</h2>
        <ul className="list-disc space-y-1 pl-5 text-muted">
          <li>No PayLight wallet ever sells or trades transistors.</li>
          <li>The CashbackRouter contract has no sell, swap, approve or withdraw function for transistors. It only pays customers, one settled purchase at a time, and rejects any tokens sent to it.</li>
          <li>Every cashback payout below is linked to the electricity order that earned it.</li>
          <li>Cashback reserve: minted {f.reserveMinted?.toString() ?? "—"} of max {f.maxReserve?.toString() ?? "200,000"}; paid out {f.distributed?.toString() ?? "—"}.</li>
        </ul>
      </section>

      <section className="card space-y-2 p-5 text-sm">
        <h2 className="text-xl font-extrabold">Latest cashback payouts</h2>
        {payouts.length === 0 ? (
          <p className="text-muted">None yet.</p>
        ) : (
          <table className="w-full">
            <thead><tr className="text-left text-muted"><th>Order</th><th>Customer</th><th className="text-right">Transistors</th></tr></thead>
            <tbody>
              {payouts.map((p) => (
                <tr key={p.orderId} className="border-t border-border">
                  <td className="py-2 font-mono"><a className="underline" href={explorerTx(p.txHash)} target="_blank" rel="noreferrer">{p.orderId.slice(0, 10)}…</a></td>
                  <td className="font-mono">{p.payer.slice(0, 6)}…{p.payer.slice(-4)}</td>
                  <td className="text-right">{p.units}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
