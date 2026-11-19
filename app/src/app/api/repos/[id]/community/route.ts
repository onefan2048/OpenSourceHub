import { prisma } from "@/lib/db";
import { bad, json, withDb } from "@/lib/api";
import { COMMUNITY_KINDS, SCOPES, runCommunitySync, scopeChange, type CommunityKind } from "@/lib/community/sync";
import { createGitHubClient } from "@/lib/github/factory";

export const dynamic = "force-dynamic";
type P = { params: Promise<{ id: string }> };

/** 同步状态 */
export async function GET(_: Request, { params }: P) {
  const id = Number((await params).id);
  return withDb(async () => json(await prisma.communitySync.findMany({ where: { repositoryId: id } })));
}

/**
 * 操作：{ kind, action: "sync" | "resync" | "scope", scope? }
 * - sync：立即在当前请求内执行一次增量 + 一批回填（不等 Worker 队列）
 * - resync：清空游标与水位，立即执行第一批从头回填
 * - scope：修改同步范围 off | open | all
 */
export async function POST(req: Request, { params }: P) {
  const id = Number((await params).id);
  return withDb(async () => {
    const b = await req.json().catch(() => ({}));
    const kind = b.kind as CommunityKind;
    if (!COMMUNITY_KINDS.includes(kind)) return bad("kind 必须为 issues 或 discussions");
    const repo = await prisma.repository.findUnique({ where: { id }, select: { id: true } });
    if (!repo) return bad("仓库不存在", 404);
    const data: Record<string, unknown> = {};
    if (b.action === "sync") Object.assign(data, { nextSyncAt: new Date(0) });
    else if (b.action === "resync") Object.assign(data, { nextSyncAt: new Date(0), watermark: null, cursor: null, backfillDone: false });
    else if (b.action === "scope") {
      if (!SCOPES.includes(b.scope)) return bad("不支持的同步范围");
      Object.assign(data, scopeChange(b.scope));
    } else return bad("未知操作");
    const row = await prisma.communitySync.upsert({
      where: { repositoryId_kind: { repositoryId: id, kind } },
      create: { repositoryId: id, kind, ...data },
      update: { ...data, ...(data.nextSyncAt ? { status: "idle" } : {}) },
    });
    if (b.action === "sync" || b.action === "resync" || (b.action === "scope" && b.scope !== "off")) {
      const lock = await prisma.communitySync.updateMany({ where: { id: row.id, status: { not: "running" } }, data: { status: "running" } });
      if (lock.count === 1) {
        const gh = await createGitHubClient();
        await runCommunitySync(row.id, gh);
      }
      return json(await prisma.communitySync.findUnique({ where: { id: row.id } }));
    }
    return json(row);
  });
}

