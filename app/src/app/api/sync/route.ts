import { prisma } from "@/lib/db";
import { json, withDb } from "@/lib/api";
import { enqueueSync } from "@/lib/sync/queue";

export const dynamic = "force-dynamic";

/** 批量同步：{ ids?: number[] }，不传则同步全部未暂停的仓库 */
export async function POST(req: Request) {
  return withDb(async () => {
    const b = await req.json().catch(() => ({}));
    const ids: number[] = Array.isArray(b.ids) && b.ids.length ? b.ids.map(Number) : (await prisma.repository.findMany({ where: { paused: false }, select: { id: true } })).map((r) => r.id);
    for (const id of ids) await enqueueSync(id, { trigger: "batch", priority: 8 });
    return json({ queued: ids.length });
  });
}
