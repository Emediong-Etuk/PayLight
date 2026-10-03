import { env } from "./env";
import { log, mask } from "./log";

/** Sends an alert to Greg's private Telegram chat (NEEDS_REVIEW, low float, low gas, failed settle, reconciler mismatch). */
export async function alert(text: string): Promise<void> {
  const { TELEGRAM_BOT_TOKEN: token, TELEGRAM_ALERT_CHAT_ID: chat } = env();
  log.warn("ALERT", { text });
  if (!token || !chat) return;
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text: `⚡ PayLight: ${mask(text)}`, disable_web_page_preview: true }),
    });
  } catch (e) {
    log.error("telegram alert failed", { err: (e as Error).message });
  }
}
