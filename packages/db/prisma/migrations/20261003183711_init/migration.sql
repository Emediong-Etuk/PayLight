-- CreateEnum
CREATE TYPE "OrderStatus" AS ENUM ('QUOTED', 'EXPIRED', 'PAID', 'MISMATCH', 'PROVIDER_PENDING', 'DELIVERED', 'SETTLED', 'PROVIDER_FAILED', 'REFUNDING', 'REFUNDED', 'NEEDS_REVIEW');

-- CreateTable
CREATE TABLE "Quote" (
    "orderId" TEXT NOT NULL,
    "payer" TEXT NOT NULL,
    "serviceID" TEXT NOT NULL,
    "meterNumber" TEXT NOT NULL,
    "meterType" TEXT NOT NULL DEFAULT 'prepaid',
    "customerName" TEXT NOT NULL,
    "customerAddress" TEXT,
    "phone" TEXT,
    "amountNgn" INTEGER NOT NULL,
    "rateKobo" BIGINT NOT NULL,
    "baseAmount" BIGINT NOT NULL,
    "fee" BIGINT NOT NULL,
    "tier" INTEGER NOT NULL,
    "cashbackUnits" INTEGER NOT NULL,
    "expiry" TIMESTAMP(3) NOT NULL,
    "signature" TEXT NOT NULL,
    "gateway" TEXT NOT NULL,
    "chainId" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Quote_pkey" PRIMARY KEY ("orderId")
);

-- CreateTable
CREATE TABLE "Order" (
    "orderId" TEXT NOT NULL,
    "status" "OrderStatus" NOT NULL DEFAULT 'QUOTED',
    "payer" TEXT NOT NULL,
    "amount" BIGINT NOT NULL,
    "fee" BIGINT NOT NULL,
    "tier" INTEGER NOT NULL,
    "cashbackUnits" INTEGER NOT NULL,
    "txHashPaid" TEXT,
    "blockPaid" BIGINT,
    "paidAt" TIMESTAMP(3),
    "refundableAt" TIMESTAMP(3),
    "providerRequestId" TEXT,
    "providerTxId" TEXT,
    "providerStatus" TEXT,
    "providerCode" TEXT,
    "meterTokenEncrypted" TEXT,
    "units" TEXT,
    "providerRaw" JSONB,
    "requeryCount" INTEGER NOT NULL DEFAULT 0,
    "nextActionAt" TIMESTAMP(3),
    "receiptHash" TEXT,
    "txHashSettled" TEXT,
    "txHashRefund" TEXT,
    "refundedByOperator" BOOLEAN,
    "lastError" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Order_pkey" PRIMARY KEY ("orderId")
);

-- CreateTable
CREATE TABLE "OrderEvent" (
    "id" BIGSERIAL NOT NULL,
    "orderId" TEXT NOT NULL,
    "from" "OrderStatus",
    "to" "OrderStatus" NOT NULL,
    "reason" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "OrderEvent_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CashbackPayout" (
    "orderId" TEXT NOT NULL,
    "payer" TEXT NOT NULL,
    "units" INTEGER NOT NULL,
    "txHash" TEXT NOT NULL,
    "block" BIGINT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "CashbackPayout_pkey" PRIMARY KEY ("orderId")
);

-- CreateTable
CREATE TABLE "ChainLog" (
    "id" TEXT NOT NULL,
    "block" BIGINT NOT NULL,
    "event" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ChainLog_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ChainCursor" (
    "name" TEXT NOT NULL,
    "lastBlock" BIGINT NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ChainCursor_pkey" PRIMARY KEY ("name")
);

-- CreateTable
CREATE TABLE "Config" (
    "key" TEXT NOT NULL,
    "value" TEXT NOT NULL,
    "updatedBy" TEXT NOT NULL,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Config_pkey" PRIMARY KEY ("key")
);

-- CreateTable
CREATE TABLE "AdminAudit" (
    "id" BIGSERIAL NOT NULL,
    "actor" TEXT NOT NULL,
    "action" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AdminAudit_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "SiweNonce" (
    "nonce" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "usedAt" TIMESTAMP(3),

    CONSTRAINT "SiweNonce_pkey" PRIMARY KEY ("nonce")
);

-- CreateTable
CREATE TABLE "RateLimit" (
    "key" TEXT NOT NULL,
    "count" INTEGER NOT NULL,
    "windowEnd" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "RateLimit_pkey" PRIMARY KEY ("key")
);

-- CreateIndex
CREATE INDEX "Quote_payer_createdAt_idx" ON "Quote"("payer", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "Order_providerRequestId_key" ON "Order"("providerRequestId");

-- CreateIndex
CREATE INDEX "Order_status_nextActionAt_idx" ON "Order"("status", "nextActionAt");

-- CreateIndex
CREATE INDEX "Order_payer_createdAt_idx" ON "Order"("payer", "createdAt");

-- CreateIndex
CREATE INDEX "OrderEvent_orderId_createdAt_idx" ON "OrderEvent"("orderId", "createdAt");

-- CreateIndex
CREATE INDEX "ChainLog_block_idx" ON "ChainLog"("block");

-- AddForeignKey
ALTER TABLE "Order" ADD CONSTRAINT "Order_orderId_fkey" FOREIGN KEY ("orderId") REFERENCES "Quote"("orderId") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "OrderEvent" ADD CONSTRAINT "OrderEvent_orderId_fkey" FOREIGN KEY ("orderId") REFERENCES "Order"("orderId") ON DELETE RESTRICT ON UPDATE CASCADE;
