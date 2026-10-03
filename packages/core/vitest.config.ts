import { defineConfig } from "vitest/config";
export default defineConfig({
  test: {
    env: {
      DATABASE_URL: process.env.TEST_DATABASE_URL ?? "postgresql://paylight:paylight@localhost:5432/paylight_test",
      TOKEN_ENCRYPTION_KEY: "0".repeat(63) + "1",
      NODE_ENV: "test",
    },
    fileParallelism: false,
  },
});
