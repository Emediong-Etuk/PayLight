"use client";
import { useCallback } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useAccount, useSignMessage } from "wagmi";
import { createSiweMessage } from "viem/siwe";
import { api } from "./client";

/** Sign-In with Ethereum: one signature proves you own the wallet, so only you can see your meter tokens. */
export function useSiwe() {
  const { address, chainId } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const qc = useQueryClient();
  const me = useQuery({ queryKey: ["me"], queryFn: () => api<{ address: string | null }>("/api/auth/me") });
  const signedIn = !!address && me.data?.address === address.toLowerCase();

  const signIn = useCallback(async () => {
    if (!address) throw new Error("Connect your wallet first");
    const { nonce } = await api<{ nonce: string }>("/api/auth/siwe/nonce", { method: "POST" });
    const message = createSiweMessage({
      address,
      chainId: chainId ?? 196,
      domain: window.location.host,
      nonce,
      uri: window.location.origin,
      version: "1",
      statement: "Sign in to PayLight to see your electricity tokens. This does not cost anything.",
    });
    const signature = await signMessageAsync({ message });
    await api("/api/auth/siwe/verify", { json: { message, signature } });
    await qc.invalidateQueries({ queryKey: ["me"] });
  }, [address, chainId, signMessageAsync, qc]);

  return { signedIn, signIn, loading: me.isLoading };
}
