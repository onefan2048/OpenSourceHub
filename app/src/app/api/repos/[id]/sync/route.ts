import { prisma } from "@/lib/db";
import { bad, json, withDb } from "@/lib/api";
import { enqueueSync } from "@/lib/sync/queue";

export const dynamic = "force-dynamic";

/** 立即手动同步：以最高优先级加入持久化队列，由后台 Worker 执行 */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const id = Number((await params).id);
  return withDb(async () => {
    const b = await req.json().catch(() => ({}));
    const repo = await prisma.repository.findUnique({ where: { id }, select: { id: true } });
    if (!repo) return bad("仓库不存在", 404);
    const task = await enqueueSync(id, { trigger: "manual", mode: b.mode === "full" ? "full" : "incremental" });
    for (const kind of ["issues", "discussions"]) {
      await prisma.communitySync.upsert({
        where: { repositoryId_kind: { repositoryId: id, kind } },
        create: { repositoryId: id, kind, nextSyncAt: new Date(0) },
        update: { nextSyncAt: new Date(0) },
      });
    }
    return json({ task });
  });
}
