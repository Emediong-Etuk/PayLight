import Link from "next/link";
import { prisma } from "@paylight/db";
import { formatNgn } from "@paylight/shared";

export const dynamic = "force-dynamic";

async function stats() {
  try {
    const settled = await prisma.order.findMany({ where: { status: "SETTLED" }, select: { payer: true, quote: { select: { amountNgn: true } } } });
    return { bills: settled.length, payers: new Set(settled.map((o) => o.payer)).size, ngn: settled.reduce((s, o) => s + o.quote.amountNgn, 0) };
  } catch {
    return { bills: 0, payers: 0, ngn: 0 };
  }
}

export default async function Home() {
  const s = await stats();
  return (
    <div className="space-y-8">
      <section className="space-y-4 pt-4">
        {/* Hero illustration slot: Greg supplies original artwork */}
        <div className="grid h-40 place-items-center rounded-3xl bg-brand text-6xl" aria-hidden>💡</div>
        <h1 className="text-4xl font-extrabold leading-tight">Pay for light with USDT.</h1>
        <p className="text-lg text-muted">No P2P, no waiting for naira. Pick your electricity company, enter your meter number, pay in USD₮0 and get your token on screen in seconds.</p>
        <Link href="/pay" className="btn btn-primary w-full text-lg">Buy light now</Link>
      </section>

      <section className="grid grid-cols-3 gap-2 text-center">
        <div className="card p-3"><p className="text-2xl font-extrabold">{s.bills}</p><p className="text-xs text-muted">bills paid</p></div>
        <div className="card p-3"><p className="text-2xl font-extrabold">{formatNgn(s.ngn)}</p><p className="text-xs text-muted">delivered</p></div>
        <div className="card p-3"><p className="text-2xl font-extrabold">{s.payers}</p><p className="text-xs text-muted">customers</p></div>
      </section>

      <section className="card space-y-4 p-5">
        <h2 className="text-xl font-extrabold">How it works</h2>
        <ol className="space-y-3">
          <li><b>1. Your meter.</b> Choose your disco (Ikeja, Eko, AEDC, PHED and 8 more) and type your prepaid meter number.</li>
          <li><b>2. Check the name.</b> We show you the meter owner’s name so you never pay for the wrong meter.</li>
          <li><b>3. Pay &amp; get your token.</b> Pay in USD₮0 on X Layer. Your 20-digit token appears right here. Type it into your meter.</li>
        </ol>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-extrabold">Questions</h2>
        <details className="card p-4"><summary className="font-semibold">What if something goes wrong?</summary><p className="mt-2 text-muted">Your USD₮0 waits in a smart contract until your token is delivered. If the purchase fails, you’re refunded automatically. If we ever disappear, you can take your money back yourself after 24 hours.</p></details>
        <details className="card p-4"><summary className="font-semibold">What does it cost?</summary><p className="mt-2 text-muted">A 1% service fee (lower for regular customers and transistor holders), shown before you pay. Network fees on X Layer are a tiny fraction of a cent, and you can even pay without OKB.</p></details>
        <details className="card p-4"><summary className="font-semibold">What are PayLight transistors?</summary><p className="mt-2 text-muted">Cashback you earn on every purchase. Holding them lowers your fee. <Link className="underline" href="/light">Learn more</Link></p></details>
      </section>
    </div>
  );
}
