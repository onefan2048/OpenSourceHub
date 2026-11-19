/**
 * Issues / Discussions 同步（独立于版本监控的“社区通道”）
 *
 * 面向 koreader/koreader 这类 Issues 8000+、Discussions 数千条的大仓库，采用：
 *   1. 增量水位：Issues 用 REST `since=水位&sort=updated&direction=asc`，按更新时间从旧到新处理，
 *      每处理一页就推进水位，预算用完也能从断点继续；无变化时 URL 不变，ETag 命中 304 不耗额度。
 *      Discussions 用 GraphQL 按 UPDATED_AT 倒序读取，遇到 ≤ 水位的条目即停止。
 *   2. 分批回填：历史数据按“每轮 N 页”的预算分批拉取，游标持久化到数据库，重启不丢失；
 *      Issues 先回填开放中的（最常用），再回填已关闭的；回填期间每 15 秒继续一批。
 *   3. 速率保护：剩余额度低于阈值时暂停回填，等到额度重置；限流时按 GitHub 给出的时间延后。
 *   4. 页面只读本地 SQLite（带索引的分页查询），因此浏览、筛选、翻页都不会请求 GitHub。
 */
import { prisma } from "../db";
import { GitHubClient, GitHubError, rateLimitState, type GhResponse } from "../github/client";
import { getNumberSetting } from "../settings";

export type CommunityKind = "issues" | "discussions";
export const COMMUNITY_KINDS: CommunityKind[] = ["issues", "discussions"];
export type CommunityScope = "off" | "open" | "all";
export const SCOPES: CommunityScope[] = ["off", "open", "all"];

const BACKFILL_CONTINUE_MS = 15_000; // 回填未完成时，下一批的间隔
const MIN_RATE_FOR_BACKFILL = 300; // REST 剩余额度低于此值时暂停回填
const MAX_INCREMENTAL_PAGES = 10;
const BODY_LIMIT = 60_000;

type Label = { name: string; color: string | null };
export const keysOf = (names: string[]) => (names.length ? `|${names.map((n) => n.toLowerCase()).join("|")}|` : "");
const iso = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

/** 从 GitHub emojiHTML（如 <g-emoji>💬</g-emoji>）中提取表情字符 */
export function emojiFromHtml(html: string | null | undefined) {
  const t = (html ?? "").replace(/<[^>]+>/g, "").trim();
  return t || null;
}

// ---------------- 映射 ----------------
interface GhIssue {
  number: number;
  title: string;
  state: string;
  state_reason?: string | null;
  user: { login: string; avatar_url: string } | null;
  labels: (string | { name: string; color?: string | null })[];
  assignees?: { login: string; avatar_url: string }[] | null;
  milestone?: { title: string } | null;
  type?: { name: string } | null;
  comments: number;
  reactions?: { total_count: number };
  locked: boolean;
  html_url: string;
  body?: string | null;
  created_at: string;
  updated_at: string;
  closed_at: string | null;
  pull_request?: unknown;
}

export function mapIssue(i: GhIssue) {
  const labels: Label[] = (i.labels ?? []).map((l) => (typeof l === "string" ? { name: l, color: null } : { name: l.name, color: l.color ?? null }));
  const assignees = (i.assignees ?? []).map((a) => ({ login: a.login, avatar: a.avatar_url }));
  return {
    number: i.number,
    title: i.title,
    state: i.state === "closed" ? "closed" : "open",
    stateReason: i.state_reason ?? null,
    authorLogin: i.user?.login ?? null,
    authorAvatar: i.user?.avatar_url ?? null,
    labels: JSON.stringify(labels),
    labelKeys: keysOf(labels.map((l) => l.name)),
    assignees: JSON.stringify(assignees),
    assigneeKeys: keysOf(assignees.map((a) => a.login)),
    milestone: i.milestone?.title ?? null,
    issueType: i.type?.name ?? null,
    comments: i.comments ?? 0,
    reactions: i.reactions?.total_count ?? 0,
    locked: !!i.locked,
    htmlUrl: i.html_url,
    body: i.body ? i.body.slice(0, BODY_LIMIT) : null,
    bodyFetchedAt: new Date(),
    createdAtRemote: new Date(i.created_at),
    updatedAtRemote: new Date(i.updated_at),
    closedAtRemote: i.closed_at ? new Date(i.closed_at) : null,
  };
}

interface GqlDiscussion {
  number: number;
  title: string;
  url: string;
  body: string | null;
  createdAt: string;
  updatedAt: string;
  closed: boolean;
  locked: boolean;
  upvoteCount: number;
  isAnswered: boolean | null;
  author: { login: string; avatarUrl: string } | null;
  category: { name: string; emojiHTML: string | null; isAnswerable: boolean } | null;
  labels: { nodes: { name: string; color: string }[] } | null;
  comments: { totalCount: number };
}

export function mapDiscussion(n: GqlDiscussion) {
  const labels: Label[] = (n.labels?.nodes ?? []).map((l) => ({ name: l.name, color: l.color }));
  return {
    number: n.number,
    title: n.title,
    authorLogin: n.author?.login ?? null,
    authorAvatar: n.author?.avatarUrl ?? null,
    categoryName: n.category?.name ?? null,
    categoryEmoji: emojiFromHtml(n.category?.emojiHTML),
    isAnswerable: !!n.category?.isAnswerable,
    isAnswered: !!n.isAnswered,
    closed: !!n.closed,
    locked: !!n.locked,
    upvotes: n.upvoteCount ?? 0,
    comments: n.comments?.totalCount ?? 0,
    labels: JSON.stringify(labels),
    labelKeys: keysOf(labels.map((l) => l.name)),
    htmlUrl: n.url,
    body: n.body ? n.body.slice(0, BODY_LIMIT) : null,
    bodyFetchedAt: new Date(),
    createdAtRemote: new Date(n.createdAt),
    updatedAtRemote: new Date(n.updatedAt),
  };
}

async function upsertIssues(repositoryId: number, items: GhIssue[]) {
  const rows = items.filter((i) => !i.pull_request).map(mapIssue);
  if (!rows.length) return 0;
  await prisma.$transaction(rows.map((r) => prisma.issue.upsert({ where: { repositoryId_number: { repositoryId, number: r.number } }, create: { repositoryId, ...r }, update: r })));
  return rows.length;
}

async function upsertDiscussions(repositoryId: number, nodes: GqlDiscussion[]) {
  const rows = nodes.filter(Boolean).map(mapDiscussion);
  if (!rows.length) return 0;
  await prisma.$transaction(rows.map((r) => prisma.discussion.upsert({ where: { repositoryId_number: { repositoryId, number: r.number } }, create: { repositoryId, ...r }, update: r })));
  return rows.length;
}

// ---------------- 元信息：数量、标签、分类 ----------------
const META_QUERY = `query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
  hasIssuesEnabled hasDiscussionsEnabled
  openIssues:issues(states:OPEN){totalCount} closedIssues:issues(states:CLOSED){totalCount}
  discussions{totalCount}
  discussionCategories(first:50){nodes{name slug emojiHTML isAnswerable}}
}}`;
type Meta = {
  repository: {
    hasIssuesEnabled: boolean;
    hasDiscussionsEnabled: boolean;
    openIssues: { totalCount: number };
    closedIssues: { totalCount: number };
    discussions: { totalCount: number };
    discussionCategories: { nodes: { name: string; slug: string; emojiHTML: string | null; isAnswerable: boolean }[] };
  } | null;
};

async function fetchMeta(gh: GitHubClient, owner: string, name: string) {
  if (!gh.authenticated) return null; // 匿名无法使用 GraphQL：仅跳过数量统计
  const d = await gh.graphql<Meta>(META_QUERY, { owner, name });
  return d.repository;
}

async function syncLabels(gh: GitHubClient, repositoryId: number, base: string) {
  const MAX = 10;
  const all: { name: string; color: string | null; description: string | null }[] = [];
  let complete = false;
  await gh.paginate<{ name: string; color: string; description: string | null }>(`${base}/labels?per_page=100`, MAX, async (items, res) => {
    all.push(...items.map((l) => ({ name: l.name, color: l.color ?? null, description: l.description ?? null })));
    if (!res.link.next) complete = true;
  });
  await prisma.$transaction([
    ...all.map((l) => prisma.repoLabel.upsert({ where: { repositoryId_name: { repositoryId, name: l.name } }, create: { repositoryId, ...l }, update: l })),
    ...(complete ? [prisma.repoLabel.deleteMany({ where: { repositoryId, name: { notIn: all.map((l) => l.name) } } })] : []),
  ]);
}

// ---------------- Issues ----------------
type IssueCursor = { phase: "open" | "closed"; url: string };

async function syncIssues(gh: GitHubClient, s: { id: number; repositoryId: number; scope: string; watermark: Date | null; cursor: string | null; backfillDone: boolean }, base: string, budget: number) {
  let pages = 0,
    upserted = 0;
  let watermark = s.watermark;
  const notes: string[] = [];

  // 1) 增量：自水位起按更新时间升序，逐页推进水位
  if (watermark) {
    const first = `${base}/issues?state=all&sort=updated&direction=asc&since=${iso(watermark)}&per_page=100`;
    // 只保留当前水位对应的 ETag 缓存，避免 http_cache 随水位推进不断膨胀
    await prisma.httpCache.deleteMany({ where: { key: { contains: `${base}/issues?state=all&sort=updated` }, NOT: { key: { endsWith: first } } } });
    let url: string | undefined = first;
    while (url && pages < MAX_INCREMENTAL_PAGES) {
      const res: GhResponse<GhIssue[]> = await gh.request<GhIssue[]>(url);
      pages++;
      if (!res.notModified) upserted += await upsertIssues(s.repositoryId, res.data ?? []);
      const last = res.data?.[res.data.length - 1];
      if (last) {
        const t = new Date(last.updated_at);
        if (t > watermark) watermark = t;
      }
      await prisma.communitySync.update({ where: { id: s.id }, data: { watermark } });
      url = res.link.next;
    }
    if (url) notes.push("增量更新较多，下一轮继续");
  }

  // 2) 回填：先开放中，再已关闭（scope=all）
  let backfillDone = s.backfillDone;
  let cursor: IssueCursor | null = s.cursor ? JSON.parse(s.cursor) : null;
  if (!backfillDone && s.scope !== "off") {
    if (!watermark) {
      watermark = new Date(Date.now() - 60_000); // 回填开始前设定水位：回填期间的变更由增量补齐
      await prisma.communitySync.update({ where: { id: s.id }, data: { watermark } });
    }
    if (!cursor) cursor = { phase: "open", url: `${base}/issues?state=open&sort=created&direction=desc&per_page=100` };
    const lowRate = rateLimitState.remaining !== null && rateLimitState.remaining < MIN_RATE_FOR_BACKFILL;
    if (lowRate) notes.push(`API 剩余额度 ${rateLimitState.remaining}，暂停回填`);
    while (!lowRate && pages < budget && cursor) {
      const res: GhResponse<GhIssue[]> = await gh.request<GhIssue[]>(cursor.url, { conditional: false });
      pages++;
      upserted += await upsertIssues(s.repositoryId, res.data ?? []);
      if (res.link.next) cursor = { ...cursor, url: res.link.next };
      else if (cursor.phase === "open" && s.scope === "all") cursor = { phase: "closed", url: `${base}/issues?state=closed&sort=created&direction=desc&per_page=100` };
      else cursor = null;
      backfillDone = !cursor;
      await prisma.communitySync.update({ where: { id: s.id }, data: { cursor: cursor ? JSON.stringify(cursor) : null, backfillDone } });
    }
    if (cursor) notes.push(`回填中（${cursor.phase === "open" ? "开放中" : "已关闭"}，第 ${new URL(cursor.url, "https://api.github.com").searchParams.get("page") ?? 1} 页）`);
  }
  return { pages, upserted, backfillDone, notes };
}

// ---------------- Discussions ----------------
const DISCUSSION_FIELDS = `number title url body createdAt updatedAt closed locked upvoteCount isAnswered
  author{login avatarUrl} category{name emojiHTML isAnswerable} labels(first:20){nodes{name color}} comments{totalCount}`;
const DISCUSSIONS_QUERY = `query($owner:String!,$name:String!,$first:Int!,$after:String,$field:DiscussionOrderField!){repository(owner:$owner,name:$name){
  discussions(first:$first,after:$after,orderBy:{field:$field,direction:DESC}){totalCount pageInfo{hasNextPage endCursor} nodes{${DISCUSSION_FIELDS}}}
}}`;
type DiscPage = { repository: { discussions: { totalCount: number; pageInfo: { hasNextPage: boolean; endCursor: string | null }; nodes: GqlDiscussion[] } } | null };

async function syncDiscussions(gh: GitHubClient, s: { id: number; repositoryId: number; scope: string; watermark: Date | null; cursor: string | null; backfillDone: boolean }, owner: string, name: string, budget: number) {
  let pages = 0,
    upserted = 0;
  let watermark = s.watermark;
  const notes: string[] = [];
  const page = async (field: "UPDATED_AT" | "CREATED_AT", after: string | null) => {
    pages++;
    const d = await gh.graphql<DiscPage>(DISCUSSIONS_QUERY, { owner, name, first: 50, after, field });
    if (!d.repository) throw new GitHubError("仓库不存在或无权访问", "not_found", 404);
    return d.repository.discussions;
  };

  // 1) 增量：按更新时间倒序，读到水位为止；未读完则不推进水位（下一轮从头再读，保证不漏）
  if (watermark) {
    let after: string | null = null,
      maxSeen = watermark,
      reached = false;
    while (pages < MAX_INCREMENTAL_PAGES) {
      const p = await page("UPDATED_AT", after);
      const fresh = p.nodes.filter((n) => new Date(n.updatedAt) > watermark!);
      upserted += await upsertDiscussions(s.repositoryId, fresh);
      for (const n of fresh) if (new Date(n.updatedAt) > maxSeen) maxSeen = new Date(n.updatedAt);
      if (fresh.length < p.nodes.length || !p.pageInfo.hasNextPage) {
        reached = true;
        break;
      }
      after = p.pageInfo.endCursor;
    }
    if (reached) watermark = maxSeen;
    else notes.push("增量更新较多，下一轮继续");
    await prisma.communitySync.update({ where: { id: s.id }, data: { watermark } });
  }

  // 2) 回填：按创建时间倒序 + 游标；scope=open 时只回填最近一年
  let backfillDone = s.backfillDone;
  if (!backfillDone && s.scope !== "off") {
    if (!watermark) {
      watermark = new Date(Date.now() - 60_000);
      await prisma.communitySync.update({ where: { id: s.id }, data: { watermark } });
    }
    let after: string | null = s.cursor ? (JSON.parse(s.cursor) as { after: string | null }).after : null;
    const cutoff = s.scope === "open" ? Date.now() - 365 * 86400_000 : 0;
    while (pages < budget && !backfillDone) {
      const p = await page("CREATED_AT", after);
      upserted += await upsertDiscussions(s.repositoryId, p.nodes);
      const oldest = p.nodes[p.nodes.length - 1];
      after = p.pageInfo.endCursor;
      backfillDone = !p.pageInfo.hasNextPage || (!!cutoff && !!oldest && new Date(oldest.createdAt).getTime() < cutoff);
      await prisma.communitySync.update({ where: { id: s.id }, data: { cursor: backfillDone ? null : JSON.stringify({ after }), backfillDone } });
    }
    if (!backfillDone) notes.push("回填中");
  }
  return { pages, upserted, backfillDone, notes };
}

/** 修改范围：扩大范围需重新回填（open → all 时补齐已关闭/更早的数据），已存数据保留 */
export function scopeChange(scope: CommunityScope) {
  return scope === "off" ? { scope } : { scope, backfillDone: false, cursor: null, nextSyncAt: new Date(), status: "idle" };
}

// ---------------- 调度 ----------------
/** 为每个仓库补齐 Issues / Discussions 同步记录 */
export async function ensureCommunityRows() {
  const repos = await prisma.repository.findMany({ select: { id: true, communitySyncs: { select: { kind: true } } } });
  for (const r of repos)
    for (const kind of COMMUNITY_KINDS)
      if (!r.communitySyncs.some((x) => x.kind === kind))
        await prisma.communitySync.create({ data: { repositoryId: r.id, kind } }).catch(() => undefined);
}

export async function recoverCommunity() {
  await prisma.communitySync.updateMany({ where: { status: "running" }, data: { status: "idle", nextSyncAt: new Date() } });
}

/** 认领一个到期的社区同步任务（从未同步过的仓库优先，避免被大仓库的多批回填饥饿阻塞） */
export async function claimCommunity() {
  const now = new Date();
  const due = await prisma.communitySync.findMany({
    where: { scope: { not: "off" }, status: { not: "running" }, OR: [{ nextSyncAt: null }, { nextSyncAt: { lte: now } }], repository: { paused: false, accessible: true } },
    orderBy: [{ lastSyncedAt: "asc" }, { nextSyncAt: "asc" }],
    take: 3,
  });
  for (const s of due) {
    const r = await prisma.communitySync.updateMany({ where: { id: s.id, status: s.status }, data: { status: "running" } });
    if (r.count === 1) return s;
  }
  return null;
}

/** 执行一次 Issues 或 Discussions 同步（一批）。所有异常被捕获并转换为下一次调度时间。 */
export async function runCommunitySync(syncId: number, gh: GitHubClient, maxPagesOverride?: number) {
  const s = await prisma.communitySync.findUniqueOrThrow({ where: { id: syncId }, include: { repository: { select: { owner: true, name: true } } } });
  const { owner, name } = s.repository;
  const base = `/repos/${owner}/${name}`;
  const budget = maxPagesOverride ?? Math.max(1, Math.min(50, await getNumberSetting("community.pagesPerRun")));
  const interval = Math.max(5, await getNumberSetting("community.intervalMinutes"));
  const started = Date.now();
  try {
    const meta = await fetchMeta(gh, owner, name).catch((e) => {
      if (e instanceof GitHubError && e.kind === "rate_limited") throw e;
      return null; // 统计失败不影响列表同步
    });
    const enabled = meta ? (s.kind === "issues" ? meta.hasIssuesEnabled : meta.hasDiscussionsEnabled) : true;
    if (meta && !enabled) {
      await prisma.communitySync.update({ where: { id: s.id }, data: { status: "unavailable", lastSyncedAt: new Date(), lastError: null, lastSummary: s.kind === "issues" ? "该仓库未启用 Issues" : "该仓库未启用 Discussions", nextSyncAt: new Date(Date.now() + 24 * 3600_000) } });
      return { summary: "未启用" };
    }
    let r: { pages: number; upserted: number; backfillDone: boolean; notes: string[] };
    if (s.kind === "issues") {
      await syncLabels(gh, s.repositoryId, base).catch((e) => {
        if (e instanceof GitHubError && e.kind === "rate_limited") throw e;
      });
      r = await syncIssues(gh, s, base, budget);
      if (meta) await prisma.communitySync.update({ where: { id: s.id }, data: { remoteOpen: meta.openIssues.totalCount, remoteClosed: meta.closedIssues.totalCount, remoteTotal: meta.openIssues.totalCount + meta.closedIssues.totalCount } });
    } else {
      if (!gh.authenticated) throw new GitHubError("Discussions 需要 GitHub Token（GraphQL API 不支持匿名访问），请在设置中配置", "unauthorized", 401);
      if (meta) {
        const cats = meta.discussionCategories.nodes;
        await prisma.$transaction([
          ...cats.map((c, i) => {
            const data = { slug: c.slug, emoji: emojiFromHtml(c.emojiHTML), isAnswerable: c.isAnswerable, position: i };
            return prisma.discussionCategory.upsert({ where: { repositoryId_name: { repositoryId: s.repositoryId, name: c.name } }, create: { repositoryId: s.repositoryId, name: c.name, ...data }, update: data });
          }),
          prisma.discussionCategory.deleteMany({ where: { repositoryId: s.repositoryId, name: { notIn: cats.map((c) => c.name) } } }),
        ]);
        await prisma.communitySync.update({ where: { id: s.id }, data: { remoteTotal: meta.discussions.totalCount } });
      }
      r = await syncDiscussions(gh, s, owner, name, budget);
    }
    const lowRate = rateLimitState.remaining !== null && rateLimitState.remaining < MIN_RATE_FOR_BACKFILL && rateLimitState.reset;
    const next = !r.backfillDone ? (lowRate ? new Date(rateLimitState.reset! * 1000 + 5000) : new Date(Date.now() + BACKFILL_CONTINUE_MS)) : new Date(Date.now() + interval * 60_000 + Math.floor(Math.random() * 60_000));
    const summary = `${r.upserted ? `更新 ${r.upserted} 条` : "无变化"} · 请求 ${r.pages} 页 · ${Date.now() - started} ms${r.notes.length ? ` · ${r.notes.join("；")}` : ""}`;
    await prisma.communitySync.update({ where: { id: s.id }, data: { status: r.backfillDone ? "ok" : "backfilling", lastSyncedAt: new Date(), lastError: null, lastSummary: summary, nextSyncAt: next } });
    return { summary };
  } catch (e) {
    const ge = e instanceof GitHubError ? e : null;
    const msg = (e as Error).message ?? String(e);
    const next = ge?.kind === "rate_limited" && ge.retryAt ? ge.retryAt : new Date(Date.now() + (ge?.kind === "unauthorized" ? 6 * 3600_000 : ge?.status === 410 ? 24 * 3600_000 : 30 * 60_000));
    const status = ge?.status === 410 ? "unavailable" : "failed";
    await prisma.communitySync.update({ where: { id: s.id }, data: { status, lastError: msg.slice(0, 1000), lastSummary: ge?.status === 410 ? "该仓库已关闭 Issues" : null, nextSyncAt: next } }).catch(() => undefined);
    return { summary: `失败：${msg}` };
  }
}
