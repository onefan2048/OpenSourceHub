import { bad, json, withDb } from "@/lib/api";
import { getAllSettings } from "@/lib/settings";
import { sendEmailNotification, emailConfigured } from "@/lib/email";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

// 仅在用户点击按钮时，使用已保存配置发送一封测试邮件。
export async function POST() {
  return withDb(async () => {
    const settings = await getAllSettings();
    if (!emailConfigured(settings)) return bad("请先完整配置并保存邮件设置；Outlook 还需完成授权。");
    try {
      await sendEmailNotification(settings, "测试软件源", "邮件通知测试", null);
      return json({ ok: true });
    } catch (error) {
      return bad((error as Error).message || "邮件发送失败");
    }
  });
}
