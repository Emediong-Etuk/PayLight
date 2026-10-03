"use client";
import { createConfig, http, injected } from "wagmi";
import { defineChain } from "viem";

export const xlayer = defineChain({
  id: 196,
  name: "X Layer",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.xlayer.tech", "https://xlayerrpc.okx.com"] } },
  blockExplorers: { default: { name: "OKX Explorer", url: "https://web3.okx.com/explorer/x-layer" } },
});

/**
 * Injected connector only: the target is the OKX Wallet in-app browser (and MetaMask/other injected wallets).
 * WalletConnect was dropped for now because wagmi's connectors barrel pulls in unrelated SDKs with missing optional
 * deps; re-add via a direct import when needed.
 */
export const wagmiConfig = createConfig({
  chains: [xlayer],
  connectors: [injected({ shimDisconnect: true })],
  transports: { [xlayer.id]: http() },
  ssr: true,
});
