import { prisma } from "@/lib/db";
import { bad, json, withDb } from "@/lib/api";
import { ensureCategory, listCategories, parseCategoryPath, parseParentId } from "@/lib/categories";

export const dynamic = "force-dynamic";

/** 分类列表（树形先序排列，含层级、完整路径与子树软件源总数）及未分类数量 */
export async function GET() {
  return withDb(async () => {
    const [categories, uncategorized] = await Promise.all([listCategories(), prisma.repository.count({ where: { categoryId: null } })]);
    return json({ categories, uncategorized });
  });
}

/** 新建分类：{ name, parentId? }；name 支持用 `/` 一次创建多级分类 */
export async function POST(req: Request) {
  return withDb(async () => {
    const b = await req.json().catch(() => ({}));
    if (!parseCategoryPath(b.name).length) return bad("分类名称不能为空");
    try {
      const parentId = parseParentId(b.parentId);
      const id = await ensureCategory(b.name, parentId);
      return json(await prisma.category.findUnique({ where: { id } }));
    } catch (e) {
      return bad((e as Error).message);
    }
  });
}
