import { prisma } from "@/lib/db";
import { bad, json, withDb } from "@/lib/api";

export const dynamic = "force-dynamic";
type P = { params: Promise<{ id: string; kind: string; number: string }> };

/** 读取单条 Issue / Discussion 正文（同步时已缓存到本地，不请求 GitHub） */
export async function GET(_: Request, { params }: P) {
  const p = await params;
  const repositoryId = Number(p.id),
    number = Number(p.number);
  if (!Number.isInteger(repositoryId) || !Number.isInteger(number)) return bad("参数错误");
  return withDb(async () => {
    const where = { repositoryId_number: { repositoryId, number } };
    const row =
      p.kind === "issues"
        ? await prisma.issue.findUnique({ where, select: { body: true, htmlUrl: true } })
        : p.kind === "discussions"
          ? await prisma.discussion.findUnique({ where, select: { body: true, htmlUrl: true } })
          : null;
    return row ? json(row) : bad("未找到", 404);
  });
}
