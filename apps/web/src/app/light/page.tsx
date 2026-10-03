import { formatEther } from "viem";
import { onchainFacts } from "@/lib/onchain";
import { Addr } from "@/components/Addr";

export const dynamic = "force-dynamic";
export const metadata = { title: "PayLight transistors" };

const fmt = (v: bigint | null | undefined, fallback: string) => (v === null || v === undefined ? fallback : v.toLocaleString("en-NG"));

export default async function LightPage() {
  const f = await onchainFacts();
  const bps = (b: number | null | undefined, fb: string) => (b === null || b === undefined ? fb : `${(b / 100).toFixed(2)}%`);
  return (
    <div className="space-y-5">
      <h1 className="text-3xl font-extrabold">PayLight transistors ⚡</h1>
      <p className="text-lg text-muted">
        PayLight runs on its own <b>TapeOut processor</b> on X Layer. Its tokens are called <b>transistors</b> (NAND gates). You earn them as cashback when you buy electricity, and holding them lowers your fee.
      </p>

      <section className="card space-y-2 p-5">
        <h2 className="text-xl font-extrabold">Fixed, public parameters</h2>
        <dl className="grid grid-cols-2 gap-y-2 text-sm">
          <dt className="text-muted">Supply cap</dt><dd className="font-semibold">{fmt(f.supplyCap, "1,000,000")} transistors</dd>
          <dt className="text-muted">Unit price</dt><dd className="font-semibold">{f.mintPrice !== null && f.mintPrice !== undefined ? `${formatEther(f.mintPrice)} OKB` : "0.0001 OKB"}</dd>
          <dt className="text-muted">Minted so far</dt><dd className="font-semibold">{fmt(f.minted, "—")}</dd>
          <dt className="text-muted">Per-wallet cap</dt><dd className="font-semibold">None (TapeOut has no per-wallet cap)</dd>
          <dt className="text-muted">Quote token</dt><dd className="font-semibold">OKB (native; set by TapeOut)</dd>
          <dt className="text-muted">Cashback reserve</dt><dd className="font-semibold">max {fmt(f.maxReserve, "200,000")} (20%); minted {fmt(f.reserveMinted, "—")}, paid out {fmt(f.distributed, "—")}</dd>
        </dl>
        <p className="text-xs text-muted">Live from the contracts. Supply and price were set once when the processor was created and can’t be changed.</p>
      </section>

      <section className="card space-y-3 p-5">
        <h2 className="text-xl font-extrabold">Lower fees, decided on-chain</h2>
        <p className="text-sm text-muted">
          Every payment asks our <b>FeeTier circuit</b> (circuit #{f.circuitId?.toString() ?? "1"} on the PayLight processor, 7 NAND gates) which tier you’re in. The smart contract enforces the result, so nobody can overcharge you.
        </p>
        <table className="w-full text-sm">
          <thead><tr className="text-left text-muted"><th className="py-1">Tier</th><th>Who</th><th className="text-right">Fee</th></tr></thead>
          <tbody>
            <tr className="border-t border-border"><td className="py-2">0</td><td>Everyone</td><td className="text-right font-semibold">{bps(f.tierFees[0], "1.00%")}</td></tr>
            <tr className="border-t border-border"><td className="py-2">1</td><td>Hold ≥ {fmt(f.t1, "50")} transistors, or {f.r ?? 3}+ completed purchases</td><td className="text-right font-semibold">{bps(f.tierFees[1], "0.50%")}</td></tr>
            <tr className="border-t border-border"><td className="py-2">2</td><td>Hold ≥ {fmt(f.t2, "500")} transistors</td><td className="text-right font-semibold">{bps(f.tierFees[2], "0.25%")}</td></tr>
          </tbody>
        </table>
      </section>

      <section className="card space-y-2 p-5">
        <h2 className="text-xl font-extrabold">How you get them</h2>
        <p className="text-sm text-muted">1 transistor per ₦1,000 of electricity (up to 50 per purchase), paid out from a public reserve held by our CashbackRouter contract. That contract <b>cannot sell or move transistors anywhere except to paying customers</b>, one settled purchase at a time. The transistors in the reserve were minted at the public price, and the mint revenue went to the creator wallet, so you can think of the reserve as a disclosed creator allocation that’s locked so it can only reach customers.</p>
        <p className="text-sm text-muted">You can also use your transistors to build and tape out your own circuits on the PayLight processor with TapeOut.</p>
      </section>

      <section className="card space-y-2 p-5 text-sm">
        <h2 className="text-xl font-extrabold">Contracts</h2>
        <p>Processor: <Addr a={f.processor} /></p>
        <p>Transistors: <Addr a={f.transistors} /></p>
        <p>Creator / deployment wallet: <Addr a={f.creator ?? process.env.PUBLIC_DEPLOYER_ADDRESS} /></p>
        <p>Gateway: <Addr a={f.gateway} /></p>
        <p>CashbackRouter: <Addr a={f.router} /></p>
      </section>

      <p className="rounded-2xl bg-surface-2 p-4 text-sm text-muted">
        <b>Plain disclaimer:</b> transistors are a cashback reward and a fee discount. They are not an investment, and there’s no promise of any value or return. PayLight never sells or trades them.
      </p>
    </div>
  );
}
