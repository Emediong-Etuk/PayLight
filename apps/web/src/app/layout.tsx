import type { Metadata, Viewport } from "next";
import Link from "next/link";
import type { ReactNode } from "react";
import "./globals.css";
import { Providers } from "@/components/Providers";
import { Logo } from "@/components/Logo";

export const metadata: Metadata = {
  title: "PayLight: pay for light with USDT",
  description: "Buy prepaid electricity for any Nigerian meter with USD₮0 on X Layer. Token on screen in seconds.",
};
export const viewport: Viewport = { width: "device-width", initialScale: 1, themeColor: "#f5b301" };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en-NG">
      <body className="min-h-dvh antialiased">
        <Providers>
          <header className="mx-auto flex max-w-xl items-center justify-between px-4 py-4">
            <Link href="/" aria-label="PayLight home"><Logo /></Link>
            <nav className="flex gap-4 text-sm font-semibold text-muted">
              <Link href="/history">History</Link>
              <Link href="/help">Help</Link>
            </nav>
          </header>
          <main className="mx-auto max-w-xl px-4 pb-16">{children}</main>
          <footer className="mx-auto max-w-xl px-4 pb-10 text-sm text-muted">
            <div className="flex flex-wrap gap-x-4 gap-y-2">
              <Link href="/light">PayLight transistors</Link>
              <Link href="/transparency">Transparency</Link>
              <Link href="/help">Help &amp; refunds</Link>
            </div>
            <p className="mt-3">Runs on X Layer. Payments in USD₮0. Not affiliated with any electricity company.</p>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
