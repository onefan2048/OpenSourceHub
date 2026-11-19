import { prisma } from "@/lib/db";
import { bad, json, withDb } from "@/lib/api";
import { POLL_INTERVALS } from "@/lib/settings";
import { scheduleNext } from "@/lib/sync/queue";
import { resolveCategoryFromBody } from "@/lib/categories";
import { SCOPES, scopeChange, type CommunityScope } from "@/lib/community/sync";

export const dynamic = "force-dynamic";
type P = { params: Promise<{ id: string }> };

export async function GET(_: Request, { params }: P) {
  const id = Number((await params).id);
  return withDb(async () => {
    const repo = await prisma.repository.findUnique({ where: { id }, include: { _count: { select: { releases: true, tags: true, commits: true, assets: true } }, syncTasks: { where: { status: { in: ["pending", "running"] } } } } });
    return repo ? json(repo) : bad("仓库不存在", 404);
  });
}

const BOOL_FIELDS = ["paused", "notifyEnabled", "notifyRelease", "notifyPrerelease", "notifyTag", "notifyCommit", "notifyChangelog"] as const;

export async function PATCH(req: Request, { params }: P) {
  const id = Number((await params).id);
  return withDb(async () => {
    const b = await req.json().catch(() => ({}));
    const data: Record<string, unknown> = {};
    for (const k of BOOL_FIELDS) if (typeof b[k] === "boolean") data[k] = b[k];
    if ("pollIntervalMinutes" in b) {
      const v = b.pollIntervalMinutes === null || b.pollIntervalMinutes === "" ? null : Number(b.pollIntervalMinutes);
      if (v !== null && !(POLL_INTERVALS as readonly number[]).includes(v)) return bad("不支持的轮询间隔");
      data.pollIntervalMinutes = v;
    }
    if ("initialCommitCount" in b) data.initialCommitCount = b.initialCommitCount === null ? null : Math.max(1, Math.min(100, Number(b.initialCommitCount)));
    if (Array.isArray(b.watchedFiles)) {
      const files = b.watchedFiles.map((x: unknown) => String(x).trim().replace(/^\/+/, "")).filter((x: string) => x && !x.includes("..")).slice(0, 20);
      data.watchedFiles = JSON.stringify(files);
    }
    try {
      const categoryId = await resolveCategoryFromBody(b);
      if (categoryId !== undefined) data.categoryId = categoryId;
    } catch (e) {
      return bad((e as Error).message);
    }
    const repo = await prisma.repository.update({ where: { id }, data }).catch(() => null);
    if (!repo) return bad("仓库不存在", 404);
    // Issues / Discussions 同步范围
    for (const [field, kind] of [["issuesScope", "issues"], ["discussionsScope", "discussions"]] as const) {
      const scope = b[field] as CommunityScope;
      if (!SCOPES.includes(scope)) continue;
      const cur = await prisma.communitySync.findUnique({ where: { repositoryId_kind: { repositoryId: id, kind } } });
      if (cur?.scope === scope) continue;
      await prisma.communitySync.upsert({ where: { repositoryId_kind: { repositoryId: id, kind } }, create: { repositoryId: id, kind, ...scopeChange(scope) }, update: scopeChange(scope) });
    }
    if ("pollIntervalMinutes" in data || data.paused === false) await scheduleNext(id);
    return json(repo);
  });
}

export async function DELETE(_: Request, { params }: P) {
  const id = Number((await params).id);
  return withDb(async () => {
    const r = await prisma.repository.delete({ where: { id } }).catch(() => null);
    return r ? json({ ok: true }) : bad("仓库不存在", 404);
  });
}
