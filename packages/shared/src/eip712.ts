/** EIP-712 typed data for PayLightGateway quotes. Must match the contract exactly (see docs/SECURITY.md §3). */
export const QUOTE_TYPES = {
  Quote: [
    { name: "orderId", type: "bytes32" },
    { name: "payer", type: "address" },
    { name: "baseAmount", type: "uint128" },
    { name: "fee", type: "uint128" },
    { name: "tier", type: "uint8" },
    { name: "cashbackUnits", type: "uint32" },
    { name: "expiry", type: "uint64" },
  ],
} as const;

export const gatewayDomain = (chainId: number, verifyingContract: `0x${string}`) =>
  ({ name: "PayLightGateway", version: "1", chainId, verifyingContract }) as const;

/** EIP-3009 for gasless payments: ReceiveWithAuthorization on USD₮0, nonce = orderId, to = gateway. */
export const RECEIVE_WITH_AUTHORIZATION_TYPES = {
  ReceiveWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

export const PERMIT_TYPES = {
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

/** USD₮0's own EIP-712 domain (verified: recomputed separator matches DOMAIN_SEPARATOR() on-chain). */
export const usdt0Domain = (chainId: number, verifyingContract: `0x${string}`) =>
  ({ name: "USD₮0", version: "1", chainId, verifyingContract }) as const;

export interface Quote {
  orderId: `0x${string}`;
  payer: `0x${string}`;
  baseAmount: bigint;
  fee: bigint;
  tier: number;
  cashbackUnits: number;
  expiry: bigint;
}
