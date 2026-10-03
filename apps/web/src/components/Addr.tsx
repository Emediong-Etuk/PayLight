import { explorerAddress } from "@paylight/shared";
export function Addr({ a }: { a?: string | null }) {
  if (!a) return <span className="text-muted">not deployed yet</span>;
  return (
    <a className="break-all font-mono text-sm underline" href={explorerAddress(a)} target="_blank" rel="noreferrer">
      {a}
    </a>
  );
}
