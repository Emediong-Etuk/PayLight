# One image for both web and worker (pnpm monorepo). Build: docker build -t paylight .
ARG BASE=node:22-bookworm-slim
FROM ${BASE} AS base
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN corepack enable && corepack prepare pnpm@10.28.0 --activate
WORKDIR /app

FROM base AS build
COPY . .
RUN pnpm install --frozen-lockfile
RUN pnpm db:generate
# NEXT_PUBLIC_* values are baked in at build time
ARG NEXT_PUBLIC_SUPPORT_TELEGRAM=https://t.me/
ENV NEXT_PUBLIC_SUPPORT_TELEGRAM=$NEXT_PUBLIC_SUPPORT_TELEGRAM NEXT_TELEMETRY_DISABLED=1
RUN pnpm --filter @paylight/web build

FROM base AS runtime
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
COPY --from=build /app /app
# default: web. The worker service overrides the command.
CMD ["pnpm", "--filter", "@paylight/web", "start"]
