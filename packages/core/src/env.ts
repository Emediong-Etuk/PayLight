import { z } from "zod";

/** All server env vars, validated once. Documented in .env.example. Private keys are only read where needed. */
const schema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  CHAIN_ID: z.coerce.number().default(196),
  RPC_URL: z.string().url().default("https://rpc.xlayer.tech"),
  RPC_URL_FALLBACK: z.string().url().optional(),
  USDT0_ADDRESS: z.string().default("0x779Ded0c9e1022225f8E0630b35a9b54bE713736"),
  GATEWAY_ADDRESS: z.string().optional(),
  CASHBACK_ROUTER_ADDRESS: z.string().optional(),
  PROCESSOR_ADDRESS: z.string().optional(),
  CONFIRMATIONS: z.coerce.number().int().min(0).default(3),
  START_BLOCK: z.coerce.bigint().optional(),

  PROVIDER: z.enum(["vtpass", "mock"]).default("mock"),
  VTPASS_BASE_URL: z.string().url().default("https://sandbox.vtpass.com/api/"),
  VTPASS_API_KEY: z.string().optional(),
  VTPASS_PUBLIC_KEY: z.string().optional(),
  VTPASS_SECRET_KEY: z.string().optional(),
  DEFAULT_PHONE: z.string().default("08011111111"),

  DATABASE_URL: z.string().optional(),
  TOKEN_ENCRYPTION_KEY: z.string().optional(), // 32 bytes, hex or base64
  QUOTE_TTL_SECONDS: z.coerce.number().int().min(30).max(600).default(120),
  MAX_ORDER_NGN: z.coerce.number().int().default(39_000),
  DAILY_WALLET_CAP_NGN: z.coerce.number().int().default(80_000),
  FLOAT_MIN_NGN: z.coerce.number().int().default(5_000),
  MIN_OPERATOR_OKB_WEI: z.coerce.bigint().default(5_000_000_000_000_000n), // 0.005 OKB

  TELEGRAM_BOT_TOKEN: z.string().optional(),
  TELEGRAM_ALERT_CHAT_ID: z.string().optional(),
});

export type Env = z.infer<typeof schema>;
let cached: Env | undefined;
/** Blank values (e.g. `GATEWAY_ADDRESS=` in a Docker env file) count as unset, so defaults and optionals apply. */
const nonBlank = (e: NodeJS.ProcessEnv) => Object.fromEntries(Object.entries(e).filter(([, v]) => v !== undefined && v.trim() !== ""));
export const env = (): Env => (cached ??= schema.parse(nonBlank(process.env)));
/** For tests. */
export const resetEnv = () => {
  cached = undefined;
};
