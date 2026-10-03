"use client";
import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useAccount, useBalance, useReadContract, useSignTypedData, useSwitchChain, useWriteContract, usePublicClient } from "wagmi";
import { parseSignature, type Hex } from "viem";
import {
  PERMIT_TYPES,
  RECEIVE_WITH_AUTHORIZATION_TYPES,
  erc20Abi,
  formatNgn,
  formatUsdt0,
  payLightGatewayAbi,
  usdt0Domain,
  type QuoteResponse,
} from "@paylight/shared";
import { api, ApiError, useAppConfig, useDiscos } from "@/lib/client";
import { useSiwe } from "@/lib/useSiwe";
import { ConnectButton } from "./ConnectButton";

const PRESETS = [1_000, 2_000, 5_000, 10_000];
const MIN_GAS_WEI = 200_000_000_000_000n; // 0.0002 OKB: below this we suggest the gasless option

type Step = 1 | 2 | 3;

function friendly(e: unknown): string {
  const m = (e as Error)?.message ?? String(e);
  if (/user rejected|denied|rejected the request/i.test(m)) return "You cancelled the request in your wallet.";
  if (/insufficient funds/i.test(m)) return "Not enough OKB to pay the network fee. Use “Pay without OKB” or see Help.";
  if (/TierChanged/i.test(m)) return "Your fee tier changed. Please refresh the quote.";
  if (/QuoteExpired|expired/i.test(m)) return "This quote expired. Tap refresh for a new one.";
  return m.split("\n")[0]!.slice(0, 200);
}

export function PayFlow() {
  const router = useRouter();
  const params = useSearchParams();
  const { address, isConnected, chainId } = useAccount();
  const { data: cfg } = useAppConfig();
  const { data: discos } = useDiscos();
  const { signedIn, signIn } = useSiwe();

  const [step, setStep] = useState<Step>(1);
  const [serviceID, setServiceID] = useState(params.get("disco") ?? "");
  const [meterNumber, setMeter] = useState(params.get("meter") ?? "");
  const [amount, setAmount] = useState<number>(Number(params.get("amount")) || 2_000);
  const [phone, setPhone] = useState("");
  const [search, setSearch] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [owner, setOwner] = useState<{ customerName: string; addressMasked: string | null } | null>(null);

  const disco = discos?.find((d) => d.serviceID === serviceID);
  const filtered = useMemo(
    () => (discos ?? []).filter((d) => `${d.name} ${d.short} ${d.region}`.toLowerCase().includes(search.toLowerCase())),
    [discos, search],
  );

  async function verify() {
    setError(null);
    if (!address) return setError("Connect your wallet first.");
    setBusy(true);
    try {
      if (!signedIn) await signIn(); // so only you can see your token later
      const r = await api<{ customerName: string; addressMasked: string | null }>("/api/meter/verify", {
        json: { serviceID, meterNumber, meterType: "prepaid", payer: address },
      });
      setOwner(r);
      setStep(2);
    } catch (e) {
      setError(friendly(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-5">
      <ol className="flex gap-2 text-xs font-bold text-muted" aria-label="Progress">
        {["Meter", "Confirm", "Pay", "Token"].map((s, i) => (
          <li key={s} className={`flex-1 rounded-full py-1 text-center ${i + 1 <= step ? "bg-brand text-brand-ink" : "bg-surface-2"}`}>{s}</li>
        ))}
      </ol>

      {step === 1 && (
        <section className="card space-y-4 p-5">
          <h1 className="text-2xl font-extrabold">Buy light</h1>
          <div>
            <label className="mb-1 block text-sm font-semibold" htmlFor="disco">Electricity company</label>
            {!disco ? (
              <>
                <input id="disco" className="input" placeholder="Search: Ikeja, PHED, Abuja…" value={search} onChange={(e) => setSearch(e.target.value)} />
                <ul className="mt-2 max-h-64 overflow-auto rounded-2xl border border-border">
                  {filtered.map((d) => (
                    <li key={d.serviceID}>
                      <button className="w-full px-4 py-3 text-left hover:bg-surface-2" onClick={() => setServiceID(d.serviceID)}>
                        <span className="font-bold">{d.short}</span> · {d.name}
                        <span className="block text-xs text-muted">{d.region}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              </>
            ) : (
              <button className="input flex items-center justify-between text-left" onClick={() => setServiceID("")}>
                <span><b>{disco.short}</b> · {disco.name}</span>
                <span className="text-sm text-muted">Change</span>
              </button>
            )}
          </div>
          <div>
            <label className="mb-1 block text-sm font-semibold" htmlFor="meter">Prepaid meter number</label>
            <input id="meter" className="input tracking-widest" inputMode="numeric" autoComplete="off" placeholder="e.g. 45012345678" value={meterNumber} onChange={(e) => setMeter(e.target.value.replace(/\D/g, "").slice(0, 15))} />
          </div>
          <div>
            <span className="mb-1 block text-sm font-semibold">Amount</span>
            <div className="grid grid-cols-4 gap-2">
              {PRESETS.map((p) => (
                <button key={p} className={`btn !min-h-11 !px-0 text-[0.8rem] ${amount === p ? "btn-primary" : "btn-ghost"}`} onClick={() => setAmount(p)}>
                  {formatNgn(p)}
                </button>
              ))}
            </div>
            <input className="input mt-2" inputMode="numeric" aria-label="Custom amount in naira" value={amount ? String(amount) : ""} onChange={(e) => setAmount(Number(e.target.value.replace(/\D/g, "").slice(0, 7)))} />
            <p className="mt-1 text-xs text-muted">Minimum ₦{(disco?.minAmount ?? 500).toLocaleString("en-NG")}. Pilot maximum ₦39,000 per purchase.</p>
          </div>
          <div>
            <label className="mb-1 block text-sm font-semibold" htmlFor="phone">Phone (optional)</label>
            <input id="phone" className="input" inputMode="tel" placeholder="0803…" value={phone} onChange={(e) => setPhone(e.target.value.slice(0, 14))} />
          </div>
          {!isConnected ? (
            <ConnectButton />
          ) : (
            <button className="btn btn-primary w-full" disabled={busy || !serviceID || meterNumber.length < 6 || amount < 500} onClick={verify}>
              {busy ? "Checking meter…" : "Continue"}
            </button>
          )}
          {error && <p className="text-sm text-danger" role="alert">{error}</p>}
        </section>
      )}

      {step === 2 && owner && (
        <section className="card space-y-5 p-5">
          <p className="text-lg">This meter belongs to</p>
          <p className="text-2xl font-extrabold">{owner.customerName}</p>
          {owner.addressMasked && <p className="text-muted">{owner.addressMasked}</p>}
          <p className="text-sm text-muted">{disco?.name} · meter ending {meterNumber.slice(-4)} · {formatNgn(amount)}</p>
          <button className="btn btn-primary w-full" onClick={() => setStep(3)}>Yes, that’s me / my meter</button>
          <button className="btn btn-ghost w-full" onClick={() => setStep(1)}>Go back</button>
        </section>
      )}

      {step === 3 && address && cfg?.gateway && (
        <PayStep
          request={{ serviceID, meterNumber, meterType: "prepaid", amountNgn: amount, phone: phone || undefined, payer: address }}
          wrongNetwork={chainId !== cfg.chainId}
          config={cfg as Required<typeof cfg> & { gateway: Hex }}
          onPaid={(orderId) => router.push(`/receipt/${orderId}?new=1`)}
          onBack={() => setStep(1)}
        />
      )}
      {step === 3 && !cfg?.gateway && <p className="card p-5">PayLight isn’t deployed on this network yet.</p>}
      <p className="text-center text-sm text-muted">Need USD₮0 on X Layer? <Link className="underline" href="/help">Here’s how</Link></p>
    </div>
  );
}

function PayStep({
  request,
  wrongNetwork,
  config,
  onPaid,
  onBack,
}: {
  request: { serviceID: string; meterNumber: string; meterType: "prepaid"; amountNgn: number; phone?: string; payer: Hex };
  wrongNetwork: boolean;
  config: { chainId: number; gateway: Hex; usdt0: Hex; gaslessEnabled: boolean };
  onPaid: (orderId: string) => void;
  onBack: () => void;
}) {
  const [quote, setQuote] = useState<QuoteResponse | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  const { switchChain } = useSwitchChain();
  const { signTypedDataAsync } = useSignTypedData();
  const { writeContractAsync } = useWriteContract();
  const pub = usePublicClient();
  const okb = useBalance({ address: request.payer, chainId: config.chainId });
  const usdt = useReadContract({ address: config.usdt0, abi: erc20Abi, functionName: "balanceOf", args: [request.payer], chainId: config.chainId });

  async function getQuote() {
    setErr(null);
    setBusy("Getting your price…");
    try {
      setQuote(await api<QuoteResponse>("/api/quote", { json: request }));
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : friendly(e));
    } finally {
      setBusy(null);
    }
  }
  useEffect(() => {
    void getQuote();
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const secondsLeft = quote ? Number(quote.expiry) - now : 0;
  const expired = quote ? secondsLeft <= 5 : false;
  const total = quote ? BigInt(quote.totalUsdt0) : 0n;
  const enoughUsdt = usdt.data !== undefined && (usdt.data as bigint) >= total;
  const hasGas = (okb.data?.value ?? 0n) >= MIN_GAS_WEI;
  const q = quote && {
    orderId: quote.orderId as Hex,
    payer: quote.payer as Hex,
    baseAmount: BigInt(quote.baseAmount),
    fee: BigInt(quote.fee),
    tier: quote.tier,
    cashbackUnits: quote.cashbackUnits,
    expiry: BigInt(quote.expiry),
  };

  async function payGasless() {
    if (!q || !quote) return;
    setErr(null);
    setBusy("Confirm in your wallet (no OKB needed)…");
    try {
      const validAfter = BigInt(now - 60);
      const validBefore = q.expiry + 600n;
      const sig = await signTypedDataAsync({
        domain: usdt0Domain(config.chainId, config.usdt0),
        types: RECEIVE_WITH_AUTHORIZATION_TYPES,
        primaryType: "ReceiveWithAuthorization",
        message: { from: q.payer, to: config.gateway, value: total, validAfter, validBefore, nonce: q.orderId },
      });
      const { r, s, v, yParity } = parseSignature(sig);
      setBusy("Sending your payment…");
      await api("/api/relay/authorization", {
        json: { orderId: q.orderId, validAfter: validAfter.toString(), validBefore: validBefore.toString(), v: Number(v ?? BigInt(yParity + 27)), r, s },
      });
      onPaid(quote.orderId);
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : friendly(e));
      setBusy(null);
    }
  }

  async function payWithPermit() {
    if (!q || !quote || !pub) return;
    setErr(null);
    setBusy("Approve the exact amount in your wallet…");
    try {
      const nonce = (await pub.readContract({ address: config.usdt0, abi: erc20Abi, functionName: "nonces", args: [q.payer] })) as bigint;
      const sig = await signTypedDataAsync({
        domain: usdt0Domain(config.chainId, config.usdt0),
        types: PERMIT_TYPES,
        primaryType: "Permit",
        message: { owner: q.payer, spender: config.gateway, value: total, nonce, deadline: q.expiry },
      });
      const { r, s, v, yParity } = parseSignature(sig);
      setBusy("Confirm the payment in your wallet…");
      const hash = await writeContractAsync({
        address: config.gateway,
        abi: payLightGatewayAbi,
        functionName: "payWithPermit",
        args: [q, quote.signature as Hex, { deadline: q.expiry, v: Number(v ?? BigInt(yParity + 27)), r, s }],
        chainId: config.chainId,
      });
      setBusy("Waiting for X Layer…");
      await pub.waitForTransactionReceipt({ hash });
      onPaid(quote.orderId);
    } catch (e) {
      setErr(friendly(e));
      setBusy(null);
    }
  }

  async function payWithApprove() {
    if (!q || !quote || !pub) return;
    setErr(null);
    try {
      setBusy("Approve the exact amount (1 of 2)…");
      const a = await writeContractAsync({ address: config.usdt0, abi: erc20Abi, functionName: "approve", args: [config.gateway, total], chainId: config.chainId });
      await pub.waitForTransactionReceipt({ hash: a });
      setBusy("Confirm the payment (2 of 2)…");
      const hash = await writeContractAsync({ address: config.gateway, abi: payLightGatewayAbi, functionName: "pay", args: [q, quote.signature as Hex], chainId: config.chainId });
      await pub.waitForTransactionReceipt({ hash });
      onPaid(quote.orderId);
    } catch (e) {
      setErr(friendly(e));
      setBusy(null);
    }
  }

  return (
    <section className="card space-y-4 p-5">
      <h2 className="text-xl font-extrabold">Your price</h2>
      {quote ? (
        <dl className="space-y-2 text-base">
          <Row k="Electricity" v={formatNgn(quote.amountNgn)} />
          <Row k="Rate" v={`₦${(Number(quote.rateKoboPerUsdt0) / 100).toLocaleString("en-NG", { minimumFractionDigits: 2 })} per USD₮0`} />
          <Row k={`Service fee (tier ${quote.tier})`} v={`${formatUsdt0(BigInt(quote.fee))} USD₮0`} />
          <div className="border-t border-border pt-2">
            <Row k={<b>You pay</b>} v={<b className="text-xl">{formatUsdt0(total)} USD₮0</b>} />
          </div>
          {quote.cashbackUnits > 0 && <Row k="Cashback" v={`+${quote.cashbackUnits} PayLight transistors ⚡`} />}
          <p className={`text-sm ${expired ? "text-danger" : "text-muted"}`}>{expired ? "Price expired." : `Price held for ${secondsLeft}s`}</p>
        </dl>
      ) : (
        !err && <p className="text-muted">Getting your price…</p>
      )}

      {wrongNetwork ? (
        <button className="btn btn-primary w-full" onClick={() => switchChain({ chainId: config.chainId })}>Switch to X Layer</button>
      ) : expired || (!quote && err) ? (
        <button className="btn btn-primary w-full" disabled={!!busy} onClick={getQuote}>Refresh price</button>
      ) : quote ? (
        <div className="space-y-2">
          {!enoughUsdt && usdt.data !== undefined && (
            <p className="text-sm text-danger">
              You have {formatUsdt0(usdt.data as bigint)} USD₮0 on X Layer. You need {formatUsdt0(total)}. <Link className="underline" href="/help">Top up</Link>
            </p>
          )}
          {config.gaslessEnabled && (
            <button className={`btn w-full ${!hasGas ? "btn-primary" : "btn-ghost"}`} disabled={!!busy || !enoughUsdt} onClick={payGasless}>
              Pay without OKB (one signature)
            </button>
          )}
          <button className={`btn w-full ${hasGas ? "btn-primary" : "btn-ghost"}`} disabled={!!busy || !enoughUsdt || !hasGas} onClick={payWithPermit}>
            Pay {formatUsdt0(total)} USD₮0
          </button>
          {!hasGas && !config.gaslessEnabled && <p className="text-sm text-danger">You need a little OKB on X Layer for the network fee. <Link className="underline" href="/help">How to get OKB</Link></p>}
          <button className="w-full text-sm text-muted underline" disabled={!!busy || !enoughUsdt || !hasGas} onClick={payWithApprove}>
            Wallet doesn’t support signatures? Pay in 2 steps
          </button>
        </div>
      ) : null}
      {busy && <p className="text-center font-semibold">{busy}</p>}
      {err && <p className="text-sm text-danger" role="alert">{err}</p>}
      <button className="w-full text-sm text-muted underline" onClick={onBack}>Change meter or amount</button>
    </section>
  );
}

function Row({ k, v }: { k: React.ReactNode; v: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4">
      <dt className="text-muted">{k}</dt>
      <dd className="text-right">{v}</dd>
    </div>
  );
}
