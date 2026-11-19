/** Issues / Discussions 本地查询：所有筛选、计数、分页都只读 SQLite，不访问 GitHub */
import type { Prisma } from "@prisma/client";
import { prisma } from "../db";

export const COMMUNITY_PER_PAGE = 25;
export type Lbl = { name: string; color: string | null };
export const parseLabels = (s: string): Lbl[] => {
  try {
    return JSON.parse(s);
  } catch {
    return [];
  }
};

const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";
const many = (v: string | string[] | undefined) => (Array.isArray(v) ? v : v ? [v] : []).map((x) => x.slice(0, 100)).filter(Boolean).slice(0, 10);
export type RawParams = Record<string, string | string[] | undefined>;

/** 解析搜索词，支持 #123 / 123 直接定位编号 */
function textWhere(q: string) {
  const m = /^#?(\d+)$/.exec(q);
  return m ? [{ number: Number(m[1]) }, { title: { contains: q } }] : [{ title: { contains: q } }, { body: { contains: q } }];
}

// ---------------- Issues ----------------
export const ISSUE_SORTS = [
  ["created-desc", "最新创建"],
  ["created-asc", "最早创建"],
  ["updated-desc", "最近更新"],
  ["updated-asc", "最久未更新"],
  ["comments-desc", "评论最多"],
  ["reactions-desc", "表情回应最多"],
] as const;

export function issueParams(sp: RawParams) {
  return {
    state: one(sp.state) === "closed" ? "closed" : "open",
    q: one(sp.q).trim().slice(0, 150),
    author: one(sp.author).trim().slice(0, 100),
    labels: many(sp.label),
    milestone: one(sp.milestone).slice(0, 200),
    assignee: one(sp.assignee).slice(0, 100),
    type: one(sp.type).slice(0, 100),
    sort: ISSUE_SORTS.some(([k]) => k === one(sp.sort)) ? one(sp.sort) : "created-desc",
    page: Math.min(100000, Math.max(1, Number(one(sp.page)) || 1)),
  };
}
export type IssueParams = ReturnType<typeof issueParams>;

export async function queryIssues(repositoryId: number, p: IssueParams) {
  const AND: Prisma.IssueWhereInput[] = [];
  if (p.q) AND.push({ OR: textWhere(p.q) });
  if (p.author) AND.push({ authorLogin: p.author });
  for (const l of p.labels) AND.push({ labelKeys: { contains: `|${l.toLowerCase()}|` } });
  if (p.milestone) AND.push(p.milestone === "none" ? { milestone: null } : { milestone: p.milestone });
  if (p.assignee) AND.push(p.assignee === "none" ? { assigneeKeys: "" } : { assigneeKeys: { contains: `|${p.assignee.toLowerCase()}|` } });
  if (p.type) AND.push(p.type === "none" ? { issueType: null } : { issueType: p.type });
  const base: Prisma.IssueWhereInput = { repositoryId, AND };
  const where: Prisma.IssueWhereInput = { ...base, state: p.state };
  const [field, dir] = p.sort.split("-") as [string, "asc" | "desc"];
  const orderBy: Prisma.IssueOrderByWithRelationInput[] =
    field === "comments" ? [{ comments: dir }, { number: "desc" }] : field === "reactions" ? [{ reactions: dir }, { number: "desc" }] : field === "updated" ? [{ updatedAtRemote: dir }] : [{ createdAtRemote: dir }, { number: dir }];
  const [rows, openCount, closedCount, labels, authors, milestones, assigneeGroups, types] = await Promise.all([
    prisma.issue.findMany({ where, orderBy, skip: (p.page - 1) * COMMUNITY_PER_PAGE, take: COMMUNITY_PER_PAGE, omit: { body: true } }),
    prisma.issue.count({ where: { ...base, state: "open" } }),
    prisma.issue.count({ where: { ...base, state: "closed" } }),
    prisma.repoLabel.findMany({ where: { repositoryId }, orderBy: { name: "asc" } }),
    prisma.issue.groupBy({ by: ["authorLogin"], where: { repositoryId }, _count: { _all: true }, orderBy: { _count: { authorLogin: "desc" } }, take: 300 }),
    prisma.issue.groupBy({ by: ["milestone"], where: { repositoryId, milestone: { not: null } }, _count: { _all: true } }),
    prisma.issue.groupBy({ by: ["assignees"], where: { repositoryId, assigneeKeys: { not: "" } } }),
    prisma.issue.groupBy({ by: ["issueType"], where: { repositoryId, issueType: { not: null } }, _count: { _all: true } }),
  ]);
  const assignees = new Map<string, string>();
  for (const g of assigneeGroups) for (const a of JSON.parse(g.assignees) as { login: string; avatar: string }[]) assignees.set(a.login, a.avatar);
  return {
    rows,
    total: p.state === "open" ? openCount : closedCount,
    openCount,
    closedCount,
    facets: {
      labels: labels.map((l) => ({ name: l.name, color: l.color, description: l.description })),
      authors: authors.filter((a) => a.authorLogin).map((a) => ({ login: a.authorLogin!, count: a._count._all })),
      milestones: milestones.map((m) => m.milestone!).sort(),
      assignees: [...assignees.keys()].sort((a, b) => a.localeCompare(b)),
      types: types.map((t) => t.issueType!).sort(),
    },
  };
}

// ---------------- Discussions ----------------
export const DISCUSSION_SORTS = [
  ["updated", "最近活动"],
  ["created", "创建时间"],
  ["top", "点赞最多"],
  ["comments", "评论最多"],
] as const;
export const DISCUSSION_FILTERS = [
  ["open", "开放中"],
  ["closed", "已关闭"],
  ["answered", "已解答"],
  ["unanswered", "未解答"],
  ["all", "全部"],
] as const;

export function discussionParams(sp: RawParams) {
  return {
    q: one(sp.q).trim().slice(0, 150),
    category: one(sp.category).slice(0, 100),
    labels: many(sp.label),
    author: one(sp.author).trim().slice(0, 100),
    filter: DISCUSSION_FILTERS.some(([k]) => k === one(sp.filter)) ? one(sp.filter) : "open",
    sort: DISCUSSION_SORTS.some(([k]) => k === one(sp.sort)) ? one(sp.sort) : "updated",
    page: Math.min(100000, Math.max(1, Number(one(sp.page)) || 1)),
  };
}
export type DiscussionParams = ReturnType<typeof discussionParams>;

export async function queryDiscussions(repositoryId: number, p: DiscussionParams) {
  const AND: Prisma.DiscussionWhereInput[] = [];
  if (p.q) AND.push({ OR: textWhere(p.q) });
  if (p.author) AND.push({ authorLogin: p.author });
  for (const l of p.labels) AND.push({ labelKeys: { contains: `|${l.toLowerCase()}|` } });
  if (p.filter === "open") AND.push({ closed: false });
  else if (p.filter === "closed") AND.push({ closed: true });
  else if (p.filter === "answered") AND.push({ isAnswerable: true, isAnswered: true });
  else if (p.filter === "unanswered") AND.push({ isAnswerable: true, isAnswered: false });
  const noCat: Prisma.DiscussionWhereInput = { repositoryId, AND };
  const where: Prisma.DiscussionWhereInput = p.category ? { ...noCat, categoryName: p.category } : noCat;
  const orderBy: Prisma.DiscussionOrderByWithRelationInput[] =
    p.sort === "created" ? [{ createdAtRemote: "desc" }] : p.sort === "top" ? [{ upvotes: "desc" }, { updatedAtRemote: "desc" }] : p.sort === "comments" ? [{ comments: "desc" }, { updatedAtRemote: "desc" }] : [{ updatedAtRemote: "desc" }];
  const [rows, total, allCount, categories, catCounts, labels, labelGroups] = await Promise.all([
    prisma.discussion.findMany({ where, orderBy, skip: (p.page - 1) * COMMUNITY_PER_PAGE, take: COMMUNITY_PER_PAGE, omit: { body: true } }),
    prisma.discussion.count({ where }),
    prisma.discussion.count({ where: noCat }),
    prisma.discussionCategory.findMany({ where: { repositoryId }, orderBy: { position: "asc" } }),
    prisma.discussion.groupBy({ by: ["categoryName", "categoryEmoji"], where: noCat, _count: { _all: true } }),
    prisma.repoLabel.findMany({ where: { repositoryId }, orderBy: { name: "asc" } }),
    prisma.discussion.groupBy({ by: ["labels"], where: { repositoryId, labelKeys: { not: "" } } }),
  ]);
  // 分类：以 GitHub 返回的分类为准，并补上本地数据中出现但已被删除的分类
  const counts = new Map(catCounts.map((c) => [c.categoryName ?? "", c._count._all]));
  const cats = categories.map((c) => ({ name: c.name, emoji: c.emoji, count: counts.get(c.name) ?? 0 }));
  for (const c of catCounts) if (c.categoryName && !cats.some((x) => x.name === c.categoryName)) cats.push({ name: c.categoryName, emoji: c.categoryEmoji, count: c._count._all });
  // 标签：Discussions 中实际使用过的标签（颜色取仓库标签）
  const used = new Map<string, string | null>();
  for (const g of labelGroups) for (const l of parseLabels(g.labels)) used.set(l.name, l.color);
  const labelColor = new Map(labels.map((l) => [l.name, l.color]));
  return {
    rows,
    total,
    allCount,
    facets: {
      categories: cats,
      labels: [...used.keys()].sort((a, b) => a.localeCompare(b)).map((name) => ({ name, color: labelColor.get(name) ?? used.get(name) ?? null })),
    },
  };
}

/** 读取同步状态 */
export function getCommunitySync(repositoryId: number, kind: string) {
  return prisma.communitySync.findUnique({ where: { repositoryId_kind: { repositoryId, kind } } });
}
