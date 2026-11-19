import { prisma } from "./db";

export const MAX_CATEGORY_NAME = 30;
export const MAX_CATEGORY_DEPTH = 6;

/** 规范化单个分类名：去首尾空白、压缩空白、限制长度 */
export function normalizeCategoryName(input: unknown): string {
  return String(input ?? "").replace(/\s+/g, " ").trim().slice(0, MAX_CATEGORY_NAME);
}

/** 支持用 `/` 或 `／` 一次输入多级路径，如 `工具 / macOS` */
export function parseCategoryPath(input: unknown): string[] {
  return String(input ?? "")
    .split(/[/／]+/)
    .map((s) => normalizeCategoryName(s))
    .filter(Boolean);
}

/** 计算给定父节点的层级深度（根节点深度 0，parentId=null 返回 -1） */
async function depthOf(parentId: number | null): Promise<number> {
  if (parentId === null) return -1;
  const all = await prisma.category.findMany({ select: { id: true, parentId: true } });
  const map = new Map(all.map((c) => [c.id, c.parentId]));
  if (!map.has(parentId)) throw new Error("父分类不存在");
  let depth = 0;
  let cur: number | null = parentId;
  const seen = new Set<number>();
  while (cur != null && !seen.has(cur)) {
    seen.add(cur);
    const next: number | null = map.get(cur) ?? null;
    if (next == null) break;
    depth++;
    cur = next;
  }
  return depth;
}

/** 按名称（支持 `/` 路径）和可选父分类查找或新建分类（同级大小写不敏感去重），返回末级分类 ID */
export async function ensureCategory(rawName: unknown, parentId: number | null = null): Promise<number> {
  const segments = parseCategoryPath(rawName);
  if (!segments.length) throw new Error("分类名称不能为空");
  let curParent = parentId;
  const baseDepth = await depthOf(curParent);
  if (baseDepth + segments.length >= MAX_CATEGORY_DEPTH) {
    throw new Error(`分类层级最多支持 ${MAX_CATEGORY_DEPTH} 级`);
  }
  for (const name of segments) {
    const siblings = await prisma.category.findMany({
      where: { parentId: curParent },
      select: { id: true, name: true },
    });
    const hit = siblings.find((c) => c.name.toLowerCase() === name.toLowerCase());
    if (hit) {
      curParent = hit.id;
    } else {
      const max = await prisma.category.aggregate({
        where: { parentId: curParent },
        _max: { sortOrder: true },
      });
      const created = await prisma.category.create({
        data: { name, parentId: curParent, sortOrder: (max._max.sortOrder ?? 0) + 1 },
      });
      curParent = created.id;
    }
  }
  return curParent!;
}

/** 解析可选的父分类 ID */
export function parseParentId(v: unknown): number | null {
  if (v === null || v === "" || v === undefined) return null;
  const id = Number(v);
  if (!Number.isInteger(id) || id <= 0) throw new Error("无效的父分类");
  return id;
}

/**
 * 从请求体中解析分类：
 * - newCategory (+ 可选 newCategoryParentId): 新建（或复用同名）分类，支持在已有分类下建子分类或用 `/` 建多级
 * - categoryId: 选择已有分类；null / "" 表示未分类
 * 返回 undefined 表示请求未涉及分类字段。
 */
export async function resolveCategoryFromBody(b: Record<string, unknown>): Promise<number | null | undefined> {
  if (typeof b.newCategory === "string" && parseCategoryPath(b.newCategory).length > 0) {
    const parentId = parseParentId(b.newCategoryParentId);
    return ensureCategory(b.newCategory, parentId);
  }
  if (!("categoryId" in b)) return undefined;
  if (b.categoryId === null || b.categoryId === "" || b.categoryId === undefined) return null;
  const id = Number(b.categoryId);
  if (!Number.isInteger(id)) throw new Error("无效的分类");
  const c = await prisma.category.findUnique({ where: { id } });
  if (!c) throw new Error("分类不存在");
  return id;
}

export type CategoryItem = {
  id: number;
  name: string;
  parentId: number | null;
  sortOrder: number;
  depth: number;
  path: string;
  ancestorIds: number[];
  directCount: number;
  count: number;
  childrenCount: number;
};

/** 列出全部分类（按树形先序 DFS 排列，含完整路径、层级深度、自身及子树软件源总数） */
export async function listCategories(): Promise<CategoryItem[]> {
  const rows = await prisma.category.findMany({
    orderBy: [{ sortOrder: "asc" }, { id: "asc" }],
    include: { _count: { select: { repositories: true } } },
  });
  const byId = new Map(rows.map((r) => [r.id, r]));
  const childrenMap = new Map<number | null, typeof rows>();
  for (const r of rows) {
    const pid = r.parentId !== null && byId.has(r.parentId) && r.parentId !== r.id ? r.parentId : null;
    const arr = childrenMap.get(pid) ?? [];
    arr.push(r);
    childrenMap.set(pid, arr);
  }

  const totalCache = new Map<number, number>();
  const visiting = new Set<number>();
  const calcTotal = (id: number): number => {
    if (totalCache.has(id)) return totalCache.get(id)!;
    if (visiting.has(id)) return 0;
    visiting.add(id);
    const row = byId.get(id)!;
    let sum = row._count.repositories;
    for (const ch of childrenMap.get(id) ?? []) sum += calcTotal(ch.id);
    visiting.delete(id);
    totalCache.set(id, sum);
    return sum;
  };

  const out: CategoryItem[] = [];
  const emitted = new Set<number>();
  const walk = (pid: number | null, depth: number, pathParts: string[], ancestorIds: number[]) => {
    for (const r of childrenMap.get(pid) ?? []) {
      if (emitted.has(r.id)) continue;
      emitted.add(r.id);
      const nextParts = [...pathParts, r.name];
      const kids = childrenMap.get(r.id) ?? [];
      out.push({
        id: r.id,
        name: r.name,
        parentId: pid,
        sortOrder: r.sortOrder,
        depth,
        path: nextParts.join(" / "),
        ancestorIds,
        directCount: r._count.repositories,
        count: calcTotal(r.id),
        childrenCount: kids.length,
      });
      walk(r.id, depth + 1, nextParts, [...ancestorIds, r.id]);
    }
  };
  walk(null, 0, [], []);
  return out;
}

/** 返回分类本身及其所有后代分类 ID 集合（用于按父分类筛选包含全部子分类） */
export function getDescendantIds(categories: Pick<CategoryItem, "id" | "parentId">[], id: number): Set<number> {
  const result = new Set<number>([id]);
  let added = true;
  while (added) {
    added = false;
    for (const c of categories) {
      if (c.parentId !== null && result.has(c.parentId) && !result.has(c.id)) {
        result.add(c.id);
        added = true;
      }
    }
  }
  return result;
}
