import crypto from "node:crypto";
import { prisma } from "@/lib/db";
import { bad, json, withDb } from "@/lib/api";
import { enqueueSync } from "@/lib/sync/queue";

export const dynamic = "force-dynamic";

/**
 * GitHub Webhook 接收端（预留，用于有管理权限的仓库实现实时更新）。
 * 在仓库 Settings → Webhooks 配置：Payload URL = https://<host>/api/webhooks/github，Content type = application/json，
 * Secret = 环境变量 GITHUB_WEBHOOK_SECRET；事件选择 push / release / create。
 * 收到事件后仅将对应仓库加入同步队列，实际数据仍通过 API 拉取，保证数据来源一致。
 */
export async function POST(req: Request) {
  const secret = process.env.GITHUB_WEBHOOK_SECRET;
  if (!secret) return bad("未配置 GITHUB_WEBHOOK_SECRET，Webhook 未启用", 503);
  const raw = await req.text();
  const sig = req.headers.get("x-hub-signature-256") ?? "";
  const expected = "sha256=" + crypto.createHmac("sha256", secret).update(raw).digest("hex");
  if (sig.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return bad("签名校验失败", 401);
  const event = req.headers.get("x-github-event");
  if (event === "ping") return json({ ok: true });
  let payload: { repository?: { id: number; full_name: string } };
  try {
    payload = JSON.parse(raw);
  } catch {
    return bad("无效 JSON");
  }
  if (!payload.repository) return json({ ignored: true });
  return withDb(async () => {
    const repo = await prisma.repository.findFirst({ where: { provider: "github", OR: [{ providerRepoId: String(payload.repository!.id) }, { fullNameKey: payload.repository!.full_name.toLowerCase() }] } });
    if (!repo) return json({ ignored: true, reason: "仓库未添加" });
    if (["push", "release", "create", "delete", "repository"].includes(event ?? "")) await enqueueSync(repo.id, { trigger: "webhook", priority: 9 });
    return json({ queued: true });
  });
}
