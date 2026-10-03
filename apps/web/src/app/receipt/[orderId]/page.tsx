import { Receipt } from "@/components/Receipt";

export default async function ReceiptPage({ params }: { params: Promise<{ orderId: string }> }) {
  const { orderId } = await params;
  return <Receipt orderId={orderId} />;
}
