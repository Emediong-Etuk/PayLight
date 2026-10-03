/** Placeholder mark: Greg will supply original artwork (replace this component). */
export function Logo({ size = 28 }: { size?: number }) {
  return (
    <span className="inline-flex items-center gap-2 font-extrabold tracking-tight">
      <svg width={size} height={size} viewBox="0 0 32 32" aria-hidden>
        <circle cx="16" cy="16" r="15" fill="var(--brand)" />
        <path d="M18 5 9 18h6l-1 9 9-13h-6l1-9z" fill="var(--brand-ink)" />
      </svg>
      <span className="text-lg">PayLight</span>
    </span>
  );
}
