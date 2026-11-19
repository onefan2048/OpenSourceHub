import { prisma } from "@/lib/db";
import { bad, json, withDb } from "@/lib/api";
import { MAX_CATEGORY_DEPTH, getDescendantIds, normalizeCategoryName, parseParentId } from "@/lib/categories";

export const dynamic = "force-dynamic";
type P = { params: Promise<{ id: string }> };

/** 重命名或移动分类：{ name?, parentId? } */
export async function PATCH(req: Request, { params }: P) {
  const id = Number((await params).id);
  return withDb(async () => {
    const b = await req.json().catch(() => ({}));
    const cur = await prisma.category.findUnique({ where: { id } });
    if (!cur) return bad("分类不存在", 404);

    const nextName = "name" in b ? normalizeCategoryName(b.name) : cur.name;
    if (!nextName) return bad("分类名称不能为空");

    let nextParentId = cur.parentId;
    if ("parentId" in b) {
      try {
        nextParentId = parseParentId(b.parentId);
      } catch (e) {
        return bad((e as Error).message);
      }
    }

    const all = await prisma.category.findMany({ select: { id: true, name: true, parentId: true } });
    if (nextParentId !== null) {
      if (!all.some((c) => c.id === nextParentId)) return bad("目标父分类不存在");
      const forbidden = getDescendantIds(all, id);
      if (forbidden.has(nextParentId)) return bad("不能将分类移动到自身或其子分类下");

      // 检查移动后的最大深度
      const map = new Map(all.map((c) => [c.id, c.parentId]));
      let parentDepth = 0;
      let p: number | null = nextParentId;
      while (p != null) {
        const up: number | null = map.get(p) ?? null;
        if (up == null) break;
        parentDepth++;
        p = up;
      }
      const subHeight = (nodeId: number): number => {
        let h = 0;
        for (const c of all) if (c.parentId === nodeId) h = Math.max(h, 1 + subHeight(c.id));
        return h;
      };
      if (parentDepth + 1 + subHeight(id) >= MAX_CATEGORY_DEPTH) {
        return bad(`移动后将超过最大层级（${MAX_CATEGORY_DEPTH} 级）`);
      }
    }

    // 同级重名检查（大小写不敏感）
    if (all.some((c) => c.id !== id && c.parentId === nextParentId && c.name.toLowerCase() === nextName.toLowerCase())) {
      return bad(`同级目录下已存在分类「${nextName}」`);
    }

    const updated = await prisma.category.update({
      where: { id },
      data: { name: nextName, parentId: nextParentId },
    });
    return json(updated);
  });
}

/** 删除分类：其中的软件源变为未分类，子分类自动上移到被删分类的父级（不会丢失子分类） */
export async function DELETE(_: Request, { params }: P) {
  const id = Number((await params).id);
  return withDb(async () => {
    const cur = await prisma.category.findUnique({ where: { id } });
    if (!cur) return bad("分类不存在", 404);
    await prisma.$transaction(async (tx) => {
      await tx.repository.updateMany({ where: { categoryId: id }, data: { categoryId: null } });
      await tx.category.updateMany({ where: { parentId: id }, data: { parentId: cur.parentId } });
      await tx.category.delete({ where: { id } });
    });
    return json({ ok: true });
  });
}
