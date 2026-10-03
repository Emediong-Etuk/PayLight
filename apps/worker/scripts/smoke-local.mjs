// Full-stack smoke test over HTTP against a running local stack (anvil + worker + next).
// Usage: node scripts/smoke-local.mjs <baseUrl> <rpc> <userPk> <gateway> <usdt0>
import { createPublicClient, createWalletClient, http, parseSignature } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createSiweMessage } from "viem/siwe";

const [base, rpc, userPk, gateway, usdt0] = process.argv.slice(2);
const chain = { id: 196, name: "local", nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: http(rpc) });
const account = privateKeyToAccount(userPk);
const wallet = createWalletClient({ account, chain, transport: http(rpc) });
let cookie = "";
async function call(path, body, method) {
  const res = await fetch(base + path, { method: method ?? (body ? "POST" : "GET"), headers: { "content-type": "application/json", cookie, host: new URL(base).host }, body: body ? JSON.stringify(body) : undefined });
  const sc = res.headers.get("set-cookie");
  if (sc) cookie = sc.split(";")[0];
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${path} ${res.status}: ${JSON.stringify(data)}`);
  return data;
}
const erc20 = [{ type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] }];

// SIWE
const { nonce } = await call("/api/auth/siwe/nonce", {});
const message = createSiweMessage({ address: account.address, chainId: 196, domain: new URL(base).host, nonce, uri: base, version: "1", statement: "Sign in to PayLight" });
await call("/api/auth/siwe/verify", { message, signature: await account.signMessage({ message }) });
console.log("SIWE ok:", (await call("/api/auth/me")).address);

console.log("discos:", (await call("/api/discos")).length);
console.log("verify:", await call("/api/meter/verify", { serviceID: "portharcourt-electric", meterNumber: "1111111111111", meterType: "prepaid", payer: account.address }));

async function waitSettled(orderId) {
  for (let i = 0; i < 60; i++) {
    const o = await call(`/api/orders/${orderId}`);
    if (["SETTLED", "REFUNDED", "NEEDS_REVIEW"].includes(o.status)) return o;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error("timeout waiting for settlement");
}

// 1) approve + pay
let q = await call("/api/quote", { serviceID: "portharcourt-electric", meterNumber: "1111111111111", meterType: "prepaid", amountNgn: 5000, payer: account.address });
console.log("quote:", { total: q.totalUsdt0, fee: q.fee, tier: q.tier, units: q.cashbackUnits, rate: q.rateKoboPerUsdt0 });
const quote = (x) => ({ orderId: x.orderId, payer: x.payer, baseAmount: BigInt(x.baseAmount), fee: BigInt(x.fee), tier: x.tier, cashbackUnits: x.cashbackUnits, expiry: BigInt(x.expiry) });
await pub.waitForTransactionReceipt({ hash: await wallet.writeContract({ address: usdt0, abi: erc20, functionName: "approve", args: [gateway, BigInt(q.totalUsdt0)] }) });
const payAbi = [{ type: "function", name: "pay", stateMutability: "nonpayable", inputs: [{ type: "tuple", components: [{ name: "orderId", type: "bytes32" }, { name: "payer", type: "address" }, { name: "baseAmount", type: "uint128" }, { name: "fee", type: "uint128" }, { name: "tier", type: "uint8" }, { name: "cashbackUnits", type: "uint32" }, { name: "expiry", type: "uint64" }] }, { type: "bytes" }], outputs: [] }];
await pub.waitForTransactionReceipt({ hash: await wallet.writeContract({ address: gateway, abi: payAbi, functionName: "pay", args: [quote(q), q.signature] }) });
let o = await waitSettled(q.orderId);
console.log("order 1:", { status: o.status, isOwner: o.isOwner, token: o.token, units: o.units, txSettled: !!o.txSettled });

// 2) gasless via relay (EIP-3009)
q = await call("/api/quote", { serviceID: "portharcourt-electric", meterNumber: "1111111111111", meterType: "prepaid", amountNgn: 2000, payer: account.address });
const now = BigInt(Math.floor(Date.now() / 1000));
const sig = await account.signTypedData({
  domain: { name: "USD₮0", version: "1", chainId: 196, verifyingContract: usdt0 },
  types: { ReceiveWithAuthorization: [{ name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" }, { name: "validAfter", type: "uint256" }, { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" }] },
  primaryType: "ReceiveWithAuthorization",
  message: { from: account.address, to: gateway, value: BigInt(q.totalUsdt0), validAfter: now - 3600n, validBefore: now + 3600n, nonce: q.orderId },
});
const { r, s, v, yParity } = parseSignature(sig);
console.log("relay:", await call("/api/relay/authorization", { orderId: q.orderId, validAfter: (now - 3600n).toString(), validBefore: (now + 3600n).toString(), v: Number(v ?? BigInt(yParity + 27)), r, s }));
o = await waitSettled(q.orderId);
console.log("order 2 (gasless):", { status: o.status, token: o.token });
console.log("history:", (await call("/api/orders")).length, "orders");
console.log("stats:", await call("/api/stats"));
