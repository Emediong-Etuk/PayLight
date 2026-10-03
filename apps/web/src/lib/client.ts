"use client";
import { useQuery } from "@tanstack/react-query";

export class ApiError extends Error {
  constructor(message: string, readonly status: number, readonly code?: string) {
    super(message);
  }
}

export async function api<T>(path: string, init?: RequestInit & { json?: unknown }): Promise<T> {
  const res = await fetch(path, {
    ...init,
    method: init?.method ?? (init?.json !== undefined ? "POST" : "GET"),
    headers: { ...(init?.json !== undefined ? { "content-type": "application/json" } : {}), ...init?.headers },
    body: init?.json !== undefined ? JSON.stringify(init.json) : init?.body,
    credentials: "same-origin",
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError((data as { error?: string }).error ?? "Request failed", res.status, (data as { code?: string }).code);
  return data as T;
}

export interface AppConfig {
  chainId: number;
  gateway: `0x${string}` | null;
  router: `0x${string}` | null;
  processor: `0x${string}` | null;
  usdt0: `0x${string}`;
  explorer: string;
  gaslessEnabled: boolean;
}
export const useAppConfig = () => useQuery({ queryKey: ["config"], queryFn: () => api<AppConfig>("/api/config"), staleTime: Infinity });

export interface Disco {
  serviceID: string;
  short: string;
  name: string;
  region: string;
  minAmount: number;
  maxAmount: number | null;
}
export const useDiscos = () => useQuery({ queryKey: ["discos"], queryFn: () => api<Disco[]>("/api/discos"), staleTime: 600_000 });
