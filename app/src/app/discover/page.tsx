import { prisma } from "@/lib/db";
import { RepoCard } from "@/components/RepoCard";
import { PageHeader } from "@/components/Shell";
import { AddRepoButton } from "@/components/Actions";
import { CategoryManager } from "@/components/Categories";
import { DiscoverMemory } from "@/components/DiscoverNav";
import { Empty } from "@/components/ui";
import { jsonArr } from "@/lib/format";
import { getDescendantIds, listCategories, type CategoryItem } from "@/lib/categories";
import { ChevronRight, Folder, FolderOpen } from "lucide-react";

export const dynamic = "force-dynamic";

const categories = [
  ["all", "全部"],
  ["recent", "最近更新"],
  ["release", "最新发布"],
  ["popular", "热门项目"],
  ["added", "最近添加"],
  ["assets", "有安装包"],
  ["source", "只有源码"],
  ["macos", "macOS"],
  ["windows", "Windows"],
  ["ios", "iOS"],
  ["android", "Android"],
  ["linux", "Linux"],
  ["dev", "开发工具"],
];

type SP = { q?: string; category?: string; platform?: string; type?: string; sort?: string; group?: string };

/** 生成保留其余筛选条件的链接 */
function link(p: SP, patch: Partial<SP>) {
  const m = { ...p, ...patch };
  const s = new URLSearchParams();
  for (const [k, v] of Object.entries(m)) if (v && !(k === "category" && v === "all")) s.set(k, v);
  const qs = s.toString();
  return `/discover${qs ? `?${qs}` : ""}`;
}

function selectLabel(c: CategoryItem) {
  return `${c.depth > 0 ? `${"　".repeat(c.depth)}└ ` : ""}${c.name}（${c.count}）`;
}

export default async function Discover({ searchParams }: { searchParams: Promise<SP> }) {
  const p = await searchParams;
  const [all, groups, uncategorized] = await Promise.all([
    prisma.repository.findMany({ include: { category: true } }),
    listCategories(),
    prisma.repository.count({ where: { categoryId: null } }),
  ]);

  const byId = new Map(groups.map((x) => [x.id, x]));
  const c = p.category || "all";
  const q = (p.q || "").trim().toLowerCase();
  const g = p.group || "";
  const groupId = g && g !== "none" ? Number(g) : null;
  const activeGroup = groupId ? byId.get(groupId) : undefined;
  const activeGroupIds = activeGroup ? getDescendantIds(groups, activeGroup.id) : null;

  let rows = all.filter((r) => {
    const catPath = r.categoryId ? byId.get(r.categoryId)?.path ?? r.category?.name ?? "" : "";
    return (
      (!q || [r.name, r.owner, r.description || "", catPath].some((x) => x.toLowerCase().includes(q))) &&
      (!g || (g === "none" ? r.categoryId === null : activeGroupIds ? r.categoryId !== null && activeGroupIds.has(r.categoryId) : false)) &&
      (!p.platform || jsonArr(r.platforms).includes(p.platform)) &&
      (!p.type || jsonArr(r.fileTypes).includes(p.type)) &&
      (!["macos", "windows", "ios", "android", "linux"].includes(c) || jsonArr(r.platforms).includes(c)) &&
      (c !== "assets" || r.hasAssets) &&
      (c !== "source" || !r.hasAssets) &&
      (c !== "release" || r.hasReleases) &&
      (c !== "dev" || /developer|development|tool|编程|开发/i.test(`${r.description} ${r.topics}`))
    );
  });

  const sort = p.sort || ({ popular: "stars", added: "added", release: "release" }[c] || "updated");
  rows.sort((a, b) =>
    sort === "stars"
      ? b.stars - a.stars
      : sort === "added"
        ? +b.addedAt - +a.addedAt
        : sort === "release"
          ? +(b.latestVersionAt || 0) - +(a.latestVersionAt || 0)
          : +(b.latestActivityAt || b.pushedAt || 0) - +(a.latestActivityAt || a.pushedAt || 0),
  );

  const types = [...new Set(all.flatMap((x) => jsonArr(x.fileTypes)))].sort();
  const chip = (active: boolean) => `btn ${active ? "bg-brand-600 text-white" : "bg-black/5 dark:bg-white/10"}`;
  const currentUrl = link(p, {});

  // 顶层分类行 & 当前路径面包屑 & 下一级/同级子分类栏
  const rootGroups = groups.filter((x) => x.parentId === null);
  const activeChain = activeGroup ? [...activeGroup.ancestorIds.map((id) => byId.get(id)!).filter(Boolean), activeGroup] : [];
  const activeRootId = activeChain[0]?.id ?? null;

  // 若当前分类有子分类，展示它的直接子分类；若当前分类是叶子且有上级，展示其上级的直接子分类（便于在同级子分类间快速切换）
  const subParent = activeGroup
    ? activeGroup.childrenCount > 0
      ? activeGroup
      : activeGroup.parentId !== null
        ? byId.get(activeGroup.parentId) ?? null
        : null
    : null;
  const subGroups = subParent ? groups.filter((x) => x.parentId === subParent.id) : [];

  return (
    <>
      <DiscoverMemory url={currentUrl} />
      <PageHeader
        title="发现软件源"
        desc="搜索并浏览已订阅的开源项目。"
        actions={
          <div className="flex flex-wrap gap-2">
            <CategoryManager />
            <AddRepoButton defaultCategoryId={activeGroup?.id ?? null} />
          </div>
        }
      />

      <form className="card grid gap-2 p-4 sm:grid-cols-[2fr_1fr_1fr_1fr_1fr_auto]">
        <input className="input" name="q" defaultValue={p.q} placeholder="搜索名称、作者、描述或分类" />
        <input type="hidden" name="category" value={c} />
        <select className="input" name="group" defaultValue={g} aria-label="分类">
          <option value="">所有分类</option>
          {groups.map((x) => (
            <option key={x.id} value={String(x.id)}>
              {selectLabel(x)}
            </option>
          ))}
          <option value="none">未分类（{uncategorized}）</option>
        </select>
        <select className="input" name="platform" defaultValue={p.platform || ""}>
          <option value="">所有平台</option>
          {["macos", "windows", "linux", "ios", "android", "cross", "unknown"].map((x) => (
            <option key={x}>{x}</option>
          ))}
        </select>
        <select className="input" name="type" defaultValue={p.type || ""}>
          <option value="">所有格式</option>
          {types.map((x) => (
            <option key={x}>{x}</option>
          ))}
        </select>
        <select className="input" name="sort" defaultValue={sort}>
          <option value="updated">更新时间</option>
          <option value="stars">Star 数</option>
          <option value="release">版本时间</option>
          <option value="added">最近添加</option>
        </select>
        <button className="btn-primary">搜索</button>
      </form>

      {/* 一级分类栏 */}
      <div className="mt-5 flex flex-wrap items-center gap-2">
        <span className="muted flex items-center gap-1 text-sm">
          <Folder size={15} />
          分类
        </span>
        <a href={link(p, { group: undefined })} className={chip(!g)}>
          全部（{all.length}）
        </a>
        {rootGroups.map((x) => (
          <a key={x.id} href={link(p, { group: String(x.id) })} className={chip(activeRootId === x.id)}>
            {x.childrenCount > 0 ? "📂" : "📁"} {x.name}（{x.count}）{x.childrenCount > 0 && <span className="opacity-70">▸</span>}
          </a>
        ))}
        {uncategorized > 0 && (
          <a href={link(p, { group: "none" })} className={chip(g === "none")}>
            未分类（{uncategorized}）
          </a>
        )}
        {groups.length === 0 && <span className="muted text-xs">还没有分类，可在“添加软件源”或“管理分类”中新建。</span>}
      </div>

      {/* 多级分类面包屑与子分类栏 */}
      {activeGroup && (activeChain.length > 1 || subGroups.length > 0) && (
        <div className="card mt-3 space-y-2.5 p-3">
          <nav aria-label="分类路径" className="flex flex-wrap items-center gap-1 text-xs">
            <a href={link(p, { group: undefined })} className="muted hover:text-brand-600">
              全部分类
            </a>
            {activeChain.map((node, idx) => (
              <span key={node.id} className="inline-flex items-center gap-1">
                <ChevronRight size={13} className="muted" />
                {idx === activeChain.length - 1 ? (
                  <span className="font-semibold">
                    {node.name}（{node.count}）
                  </span>
                ) : (
                  <a href={link(p, { group: String(node.id) })} className="muted hover:text-brand-600">
                    {node.name}
                  </a>
                )}
              </span>
            ))}
          </nav>
          {subParent && subGroups.length > 0 && (
            <div className="flex flex-wrap items-center gap-2">
              <span className="muted flex items-center gap-1 text-xs">
                <FolderOpen size={14} />
                子分类
              </span>
              <a href={link(p, { group: String(subParent.id) })} className={chip(activeGroup.id === subParent.id)}>
                全部「{subParent.name}」（{subParent.count}）
              </a>
              {subGroups.map((ch) => (
                <a key={ch.id} href={link(p, { group: String(ch.id) })} className={chip(activeGroup.id === ch.id)}>
                  {ch.childrenCount > 0 ? "📂" : "📁"} {ch.name}（{ch.count}）{ch.childrenCount > 0 && <span className="opacity-70">▸</span>}
                </a>
              ))}
            </div>
          )}
        </div>
      )}

      <div className="my-4 flex flex-wrap gap-2">
        {categories.map(([v, label]) => (
          <a key={v} href={link(p, { category: v, sort: undefined })} className={chip(v === c)}>
            {label}
          </a>
        ))}
      </div>

      <p className="muted mb-3 text-sm">
        {activeGroup ? `分类「${activeGroup.path}」中` : g === "none" ? "未分类中" : ""}共 {rows.length} 个软件源
      </p>

      {rows.length ? (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {rows.map((r) => (
            <RepoCard key={r.id} repo={r} from={currentUrl} categoryPath={r.categoryId ? byId.get(r.categoryId)?.path : undefined} />
          ))}
        </div>
      ) : (
        <Empty
          title="没有符合条件的软件源"
          desc={activeGroup ? `分类「${activeGroup.path}」中暂无匹配项，可点击“添加软件源”直接添加到该分类。` : "尝试更换筛选条件，或添加一个 GitHub 仓库。"}
        />
      )}
    </>
  );
}
