/** X Layer + token + TapeOut constants. Every value is sourced in docs/RESEARCH.md (verified on-chain 2026-10-03). */
export const XLAYER = {
  chainId: 196,
  name: "X Layer",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: ["https://rpc.xlayer.tech", "https://xlayerrpc.okx.com"],
  explorer: "https://web3.okx.com/explorer/x-layer",
  /** Public RPC caps eth_getLogs at 100 blocks per request. */
  maxLogRange: 100n,
  /** Blocks to wait before vending (D-07). */
  confirmations: 3,
} as const;

export const USDT0 = {
  address: "0x779Ded0c9e1022225f8E0630b35a9b54bE713736",
  decimals: 6,
  symbol: "USD₮0",
  /** Legacy X Layer "USDT" — NOT accepted; shown in /help as the wrong token. */
  legacyUsdt: "0x1E4a5963aBFD975d8c9021ce480b42188849D41d",
} as const;

export const TAPEOUT = {
  factory: "0x1f09daefa827f02cbb40967cc91b259763760761",
  nandId: 0n,
  latchId: 1n,
} as const;

export const explorerTx = (hash: string) => `${XLAYER.explorer}/tx/${hash}`;
export const explorerAddress = (addr: string) => `${XLAYER.explorer}/evm/address/${addr}`;
