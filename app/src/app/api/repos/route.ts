import { prisma } from "@/lib/db";
import { bad, json, withDb } from "@/lib/api";
import { createGitHubClient } from "@/lib/github/factory";
import { splitBatchInput } from "@/lib/github/parse";
import { addRepository, type AddResult } from "@/lib/repos";
import { resolveCategoryFromBody } from "@/lib/categories";
import { POLL_INTERVALS } from "@/lib/settings";

export const dynamic = "force-dynamic";

export async function GET() {
  return withDb(async () => json(await prisma.repository.findMany({ orderBy: { addedAt: "desc" }, omit: { readme: true, rootTree: true } })));
}

/** 添加单个或批量仓库：{ input: "owner/repo" } 或 { inputs: [...] } 或 { text: "多行文本" } */
export async function POST(req: Request) {
  return withDb(async () => {
    const body = await req.json().catch(() => ({}));
    const list: string[] = body.inputs ?? (body.text ? splitBatchInput(body.text) : body.input ? [body.input] : []);
    if (!list.length) return bad("请输入至少一个仓库");
    if (list.length > 100) return bad("一次最多导入 100 个仓库");
    const interval = body.pollIntervalMinutes ? Number(body.pollIntervalMinutes) : null;
    if (interval && !(POLL_INTERVALS as readonly number[]).includes(interval)) return bad("不支持的轮询间隔");
    const gh = await createGitHubClient();
    let categoryId: number | null | undefined;
    try {
      categoryId = await resolveCategoryFromBody(body);
    } catch (e) {
      return bad((e as Error).message);
    }
    const results: AddResult[] = [];
    for (const input of list) {
      const res = await addRepository(input, gh, { pollIntervalMinutes: interval, categoryId });
      // 已存在的仓库：若指定了分类，则像移动书签一样把它移入该分类
      if (!res.ok && res.code === "duplicate" && res.repository && categoryId) {
        const moved = await prisma.repository.update({ where: { id: res.repository.id }, data: { categoryId }, include: { category: true } });
        res.message += `，已移入分类「${moved.category?.name}」`;
      }
      results.push(res);
    }
    return json({ results, added: results.filter((r) => r.ok).length, categoryId: categoryId ?? null });
  });
}
