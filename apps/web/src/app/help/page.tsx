import Link from "next/link";
import { DISCOS, USDT0 } from "@paylight/shared";

export const metadata = { title: "Help · PayLight" };

export default function HelpPage() {
  return (
    <div className="space-y-5">
      <h1 className="text-3xl font-extrabold">Help</h1>

      <section className="card space-y-3 p-5">
        <h2 className="text-xl font-extrabold">Get USD₮0 on X Layer</h2>
        <ol className="list-decimal space-y-2 pl-5">
          <li>On OKX, go to <b>Assets → Withdraw → USDT</b>.</li>
          <li>Paste your wallet address, then choose the network <b>“X Layer (USDT0)”</b>. Check it’s selected before you tap Next.</li>
          <li>Send a small test first, then the rest.</li>
        </ol>
        <p className="rounded-xl bg-surface-2 p-3 text-sm">
          In your wallet the token must show as <b>USD₮0</b> (with ₮), contract <span className="break-all font-mono">{USDT0.address}</span>. Plain “USDT” on X Layer is an older token and won’t work. Swap it on OKX DEX first.
        </p>
        <p className="text-sm text-muted">Buying USDT on OKX P2P? If a merchant shows a “T+N” withdrawal hold, choose another merchant.</p>
      </section>

      <section className="card space-y-2 p-5">
        <h2 className="text-xl font-extrabold">Do I need OKB?</h2>
        <p>No. Choose <b>“Pay without OKB”</b> and you just sign once; we pay the tiny network fee. If you’d rather pay it yourself, withdraw a little OKB on OKX to the <b>X Layer</b> network (0.001 OKB is enough for many purchases).</p>
      </section>

      <section className="card space-y-2 p-5">
        <h2 className="text-xl font-extrabold">Refunds: your money is protected</h2>
        <ul className="list-disc space-y-2 pl-5">
          <li>Your payment waits in a smart contract (escrow) until your token is delivered.</li>
          <li>If the electricity company declines the purchase, you’re refunded automatically.</li>
          <li>If a purchase isn’t completed within <b>24 hours</b>, a <b>“Claim refund”</b> button appears on your receipt. It takes your full payment back straight from the contract, even if PayLight is offline.</li>
        </ul>
      </section>

      <section className="card space-y-2 p-5">
        <h2 className="text-xl font-extrabold">Using your token</h2>
        <p>Type the 20 digits into your meter’s keypad and press Enter (or # on some meters). Lost it? Open <Link className="underline" href="/history">History</Link> and sign in with the same wallet.</p>
      </section>

      <section className="card space-y-2 p-5">
        <h2 className="text-xl font-extrabold">Supported electricity companies</h2>
        <ul className="grid grid-cols-1 gap-1 text-sm sm:grid-cols-2">
          {DISCOS.map((d) => <li key={d.serviceID}><b>{d.short}</b> · {d.region}</li>)}
        </ul>
        <p className="text-sm text-muted">Prepaid meters only for now.</p>
      </section>

      <section className="card space-y-2 p-5">
        <h2 className="text-xl font-extrabold">Still stuck?</h2>
        <p>Message us on Telegram with your receipt link (never your seed phrase; we will never ask for it): <a className="underline" href={process.env.NEXT_PUBLIC_SUPPORT_TELEGRAM ?? "https://t.me/"} target="_blank" rel="noreferrer">PayLight support</a>.</p>
      </section>
    </div>
  );
}
