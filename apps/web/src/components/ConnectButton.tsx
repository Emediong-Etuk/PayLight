"use client";
import { useAccount, useConnect, useDisconnect } from "wagmi";

export function ConnectButton({ className = "btn btn-primary w-full" }: { className?: string }) {
  const { isConnected, address } = useAccount();
  const { connect, connectors, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  if (isConnected && address) {
    return (
      <button className="text-sm text-muted underline" onClick={() => disconnect()}>
        {address.slice(0, 6)}…{address.slice(-4)} · disconnect
      </button>
    );
  }
  return (
    <div className="space-y-2">
      {connectors.map((c) => (
        <button key={c.uid} className={className} disabled={isPending} onClick={() => connect({ connector: c })}>
          {isPending ? "Connecting…" : c.type === "injected" ? "Connect wallet" : `Connect with ${c.name}`}
        </button>
      ))}
      {error && <p className="text-sm text-danger">{error.message.split("\n")[0]}</p>}
      {connectors.length === 0 && <p className="text-sm text-muted">Open this page inside the OKX Wallet app (Discover → paste link) or a browser with a crypto wallet.</p>}
    </div>
  );
}
