import Link from "next/link";
import { CircleDot, CircleCheck, CircleSlash, MessageSquare, ArrowUp, ExternalLink, Lock } from "lucide-react";
import { Empty } from "@/components/ui";
import { prisma } from "@/lib/db";
import { AutoRefresh } from "@/components/Actions";
import { AutoSubmitForm, BodyPreview, CommunitySyncActions, LabelPicker } from "@/components/CommunityClient";
import { relTime, fmtDate, fmtNum } from "@/lib/format";
import { COMMUNITY_PER_PAGE, DISCUSSION_FILTERS, DISCUSSION_SORTS, ISSUE_SORTS, discussionParams, getCommunitySync, issueParams, parseLabels, queryDiscussions, queryIssues, type RawParams } from "@/lib/community/query";

type Repo = { id: number; htmlUrl: string; defaultBranch: string | null };

/** 生成保留现有筛选条件的链接；patch 中值为 undefined / "" 表示删除 */
function makeHref(repoId: number, tab: string, cur: Record<string, string | string[]>, patch: Record<string, string | string[] | undefined>) {
  const q = new URLSearchParams({ tab });
  const merged: Record<string, string | string[] | undefined> = { ...cur, page: undefined, ...patch };
  for (const [k, v] of Object.entries(merged)) {
    if (k === "tab" || v === undefined || v === "") continue;
    for (const x of Array.isArray(v) ? v : [v]) if (x !== "") q.append(k, x);
  }
  return `/repos/${repoId}?${q.toString()}`;
}

/** GitHub 标签色块：根据背景亮度选择文字颜色 */
function LabelChip({ name, color, href }: { name: string; color: string | null; href?: string }) {
  const hex = /^[0-9a-f]{6}$/i.test(color ?? "") ? color! : "8b949e";
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const light = (r * 299 + g * 587 + b * 114) / 1000 > 150;
  const style = { backgroundColor: `#${hex}`, color: light ? "#1f2328" : "#ffffff" };
  const cls = "inline-flex max-w-full items-center truncate rounded-full px-2 py-0.5 text-xs font-medium leading-4";
  return href ? (
    <Link href={href} scroll={false} className={`${cls} hover:opacity-80`} style={style} title={`按标签「${name}」筛选`}>
      {name}
    </Link>
  ) : (
    <span className={cls} style={style}>
      {name}
    </span>
  );
}

function Avatar({ src, login, size = 20 }: { src?: string | null; login: string; size?: number }) {
  // eslint-disable-next-line @next/next/no-img-element
  return src ? <img src={`${src}${src.includes("?") ? "&" : "?"}s=${size * 2}`} alt={login} title={login} width={size} height={size} className="rounded-full" loading="lazy" /> : null;
}

/** GitHub 风格的数字分页：‹ 上一页 1 2 3 … 40 下一页 › */
function NumberPager({ total, page, href }: { total: number; page: number; href: (n: number) => string }) {
  const pages = Math.max(1, Math.ceil(total / COMMUNITY_PER_PAGE));
  if (pages <= 1) return null;
  const nums = new Set([1, 2, pages - 1, pages, page - 2, page - 1, page, page + 1, page + 2].filter((n) => n >= 1 && n <= pages));
  const list = [...nums].sort((a, b) => a - b);
  const items: (number | "…")[] = [];
  list.forEach((n, i) => {
    if (i && n - list[i - 1] > 1) items.push("…");
    items.push(n);
  });
  const btn = "inline-flex min-w-8 items-center justify-center rounded-lg px-2 py-1 text-sm";
  return (
    <nav aria-label="分页" className="mt-5 flex flex-wrap items-center justify-center gap-1">
      {page > 1 ? (
        <Link className={`${btn} text-brand-600 hover:bg-black/5 dark:hover:bg-white/10`} href={href(page - 1)}>
          ‹ 上一页
        </Link>
      ) : (
        <span className={`${btn} muted`}>‹ 上一页</span>
      )}
      {items.map((n, i) =>
        n === "…" ? (
          <span key={`e${i}`} className={`${btn} muted`}>
            …
          </span>
        ) : (
          <Link key={n} href={href(n)} aria-current={n === page ? "page" : undefined} className={`${btn} ${n === page ? "bg-brand-600 text-white" : "hover:bg-black/5 dark:hover:bg-white/10"}`}>
            {n}
          </Link>
        ),
      )}
      {page < pages ? (
        <Link className={`${btn} text-brand-600 hover:bg-black/5 dark:hover:bg-white/10`} href={href(page + 1)}>
          下一页 ›
        </Link>
      ) : (
        <span className={`${btn} muted`}>下一页 ›</span>
      )}
    </nav>
  );
}

/** 同步状态条：本地数量 / GitHub 数量 / 回填进度 */
async function SyncStatus({ repo, kind, local }: { repo: Repo; kind: "issues" | "discussions"; local: number }) {
  const s = await getCommunitySync(repo.id, kind);
  const scope = s?.scope ?? "all";
  const label = kind === "issues" ? "Issues" : "Discussions";
  const remote = s?.remoteTotal ?? null;
  const pct = remote ? Math.min(100, Math.round((local / Math.max(1, remote)) * 100)) : null;
  const statusText =
    scope === "off" ? "未开启同步" : s?.status === "running" ? "同步中…" : s?.status === "backfilling" ? "分批回填中" : s?.status === "ok" ? "已同步" : s?.status === "unavailable" ? s.lastSummary || "不可用" : s?.status === "failed" ? "同步失败" : "等待首次同步";
  const big = (remote ?? 0) > 2000;
  return (
    <div className="card mb-4 p-4 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="min-w-0">
          <p>
            <strong>{label}</strong> · {statusText} · 本地 {fmtNum(local)} 条
            {remote !== null && <> / GitHub {fmtNum(remote)} 条{kind === "issues" && s?.remoteOpen != null && <span className="muted">（开放 {fmtNum(s.remoteOpen)} · 已关闭 {fmtNum(s.remoteClosed)}）</span>}</>}
          </p>
          <p className="muted mt-1 text-xs">
            范围：{scope === "off" ? "关闭" : scope === "open" ? (kind === "issues" ? "仅开放中 + 新动态" : "最近一年 + 新动态") : "全部历史"}
            {s?.lastSyncedAt && <> · 上次 {relTime(s.lastSyncedAt)}</>}
            {s?.nextSyncAt && scope !== "off" && <> · 下次 {fmtDate(s.nextSyncAt, true)}</>}
            {s?.lastSummary && s.status !== "unavailable" && <> · {s.lastSummary}</>}
          </p>
          {s?.lastError && <p className="mt-1 text-xs text-red-600">{s.lastError}</p>}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <CommunitySyncActions repoId={repo.id} kind={kind} scope={scope} />
          <a className="btn-ghost" href={`${repo.htmlUrl}/${kind}`} target="_blank" rel="noreferrer noopener">
            GitHub <ExternalLink size={14} />
          </a>
        </div>
      </div>
      {pct !== null && s?.status === "backfilling" && (
        <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-black/10 dark:bg-white/10" title={`${pct}%`}>
          <div className="h-full bg-brand-600 transition-all" style={{ width: `${pct}%` }} />
        </div>
      )}
      {big && s?.status === "backfilling" && <p className="muted mt-2 text-xs">大型仓库：历史数据每 15 秒回填一批（{kind === "issues" ? "开放中优先" : "从新到旧"}），已回填的部分可立即浏览和筛选；所有筛选与翻页都只查询本地数据库，不会卡顿。</p>}
      {local === 0 && scope !== "off" && (s?.status === "backfilling" || s?.status === "running" || !s?.lastSyncedAt) && <AutoRefresh intervalMs={10000} />}
    </div>
  );
}

// ======================= Issues =======================
export async function IssuesTab({ repo, sp }: { repo: Repo; sp: RawParams }) {
  await warmCommunityIfEmpty(repo.id, "issues");
  const p = issueParams(sp);
  const data = await queryIssues(repo.id, p);
  const cur: Record<string, string | string[]> = { state: p.state, q: p.q, author: p.author, label: p.labels, milestone: p.milestone, assignee: p.assignee, type: p.type, sort: p.sort === "created-desc" ? "" : p.sort };
  const href = (patch: Record<string, string | string[] | undefined>) => makeHref(repo.id, "issues", cur, patch);
  const filtered = !!(p.q || p.author || p.labels.length || p.milestone || p.assignee || p.type);
  const base = `${repo.htmlUrl}/blob/${encodeURIComponent(repo.defaultBranch || "main")}`;
  return (
    <>
      <SyncStatus repo={repo} kind="issues" local={await localCount(repo.id, "issues")} />
      <AutoSubmitForm action={`/repos/${repo.id}`} className="card mb-3 grid gap-2 p-3 md:grid-cols-[2fr_1fr_1fr_1fr_1fr_1fr_1fr_auto]">
        <input type="hidden" name="tab" value="issues" />
        <input type="hidden" name="state" value={p.state} />
        <input className="input" name="q" defaultValue={p.q} placeholder="搜索标题、正文或 #编号" />
        <input className="input" name="author" defaultValue={p.author} placeholder="作者" list="issue-authors" />
        <datalist id="issue-authors">
          {data.facets.authors.map((a) => (
            <option key={a.login} value={a.login}>{`${a.count} 个`}</option>
          ))}
        </datalist>
        <LabelPicker labels={data.facets.labels} selected={p.labels} />
        <select className="input" name="milestone" defaultValue={p.milestone} aria-label="里程碑">
          <option value="">所有里程碑</option>
          <option value="none">无里程碑</option>
          {data.facets.milestones.map((m) => (
            <option key={m}>{m}</option>
          ))}
        </select>
        <select className="input" name="assignee" defaultValue={p.assignee} aria-label="指派人">
          <option value="">所有指派人</option>
          <option value="none">未指派</option>
          {data.facets.assignees.map((a) => (
            <option key={a}>{a}</option>
          ))}
        </select>
        <select className="input" name="type" defaultValue={p.type} aria-label="类型">
          <option value="">所有类型</option>
          {data.facets.types.length > 0 && <option value="none">无类型</option>}
          {data.facets.types.map((t) => (
            <option key={t}>{t}</option>
          ))}
        </select>
        <select className="input" name="sort" defaultValue={p.sort} aria-label="排序">
          {ISSUE_SORTS.map(([k, l]) => (
            <option key={k} value={k}>
              {l}
            </option>
          ))}
        </select>
        <button className="btn-primary">筛选</button>
      </AutoSubmitForm>
      {(filtered || p.labels.length > 0) && (
        <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
          <span className="muted">当前筛选：</span>
          {p.q && <span className="chip bg-black/5 dark:bg-white/10">“{p.q}”</span>}
          {p.author && <span className="chip bg-black/5 dark:bg-white/10">作者 {p.author}</span>}
          {p.labels.map((l) => (
            <Link key={l} href={href({ label: p.labels.filter((x) => x !== l) })} scroll={false} className="chip bg-black/5 hover:line-through dark:bg-white/10">
              标签 {l} ✕
            </Link>
          ))}
          {p.milestone && <span className="chip bg-black/5 dark:bg-white/10">里程碑 {p.milestone === "none" ? "无" : p.milestone}</span>}
          {p.assignee && <span className="chip bg-black/5 dark:bg-white/10">指派 {p.assignee === "none" ? "无" : p.assignee}</span>}
          {p.type && <span className="chip bg-black/5 dark:bg-white/10">类型 {p.type === "none" ? "无" : p.type}</span>}
          <Link className="text-brand-600 hover:underline" href={makeHref(repo.id, "issues", { state: p.state }, {})} scroll={false}>
            清除筛选
          </Link>
        </div>
      )}
      <div className="card overflow-hidden">
        <div className="flex items-center gap-4 border-b border-black/5 px-4 py-3 text-sm dark:border-white/10">
          <Link href={href({ state: "open" })} scroll={false} className={`inline-flex items-center gap-1.5 ${p.state === "open" ? "font-semibold" : "muted"}`}>
            <CircleDot size={16} /> 开放 <span className="chip bg-black/5 dark:bg-white/10">{fmtNum(data.openCount)}</span>
          </Link>
          <Link href={href({ state: "closed" })} scroll={false} className={`inline-flex items-center gap-1.5 ${p.state === "closed" ? "font-semibold" : "muted"}`}>
            <CircleCheck size={16} /> 已关闭 <span className="chip bg-black/5 dark:bg-white/10">{fmtNum(data.closedCount)}</span>
          </Link>
        </div>
        {data.rows.length ? (
          <ul className="divide-y divide-black/5 dark:divide-white/10">
            {data.rows.map((i) => {
              const labels = parseLabels(i.labels);
              const assignees = JSON.parse(i.assignees) as { login: string; avatar: string }[];
              const Icon = i.state === "open" ? CircleDot : i.stateReason === "not_planned" ? CircleSlash : CircleCheck;
              const color = i.state === "open" ? "text-emerald-600" : i.stateReason === "not_planned" ? "text-black/40 dark:text-white/40" : "text-violet-600";
              return (
                <li key={i.id} className="flex flex-wrap gap-3 px-4 py-3 hover:bg-black/[0.02] dark:hover:bg-white/[0.02]">
                  <Icon size={16} className={`mt-1 shrink-0 ${color}`} />
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-1.5">
                      <a href={i.htmlUrl} target="_blank" rel="noreferrer noopener" className="font-semibold hover:text-brand-600">
                        {i.title}
                      </a>
                      {i.locked && <Lock size={12} className="muted" />}
                      {labels.map((l) => (
                        <LabelChip key={l.name} name={l.name} color={l.color} href={p.labels.includes(l.name) ? undefined : href({ label: [...p.labels, l.name] })} />
                      ))}
                    </div>
                    <div className="muted mt-1 flex flex-wrap items-center gap-x-1.5 text-xs">
                      <span>#{i.number}</span>
                      <span>·</span>
                      {i.authorLogin && (
                        <Link href={href({ author: i.authorLogin })} scroll={false} className="hover:text-brand-600 hover:underline">
                          {i.authorLogin}
                        </Link>
                      )}
                      <span>{i.state === "open" ? `创建于 ${relTime(i.createdAtRemote)}` : `关闭于 ${relTime(i.closedAtRemote ?? i.updatedAtRemote)}`}</span>
                      {i.issueType && (
                        <>
                          <span>·</span>
                          <Link href={href({ type: i.issueType })} scroll={false} className="hover:underline">
                            {i.issueType}
                          </Link>
                        </>
                      )}
                      {i.milestone && (
                        <>
                          <span>·</span>
                          <Link href={href({ milestone: i.milestone })} scroll={false} className="hover:underline">
                            🏁 {i.milestone}
                          </Link>
                        </>
                      )}
                      <span>·</span>
                      <BodyPreview repoId={repo.id} kind="issues" number={i.number} baseUrl={base} />
                    </div>
                  </div>
                  <div className="flex shrink-0 items-start gap-3 pt-0.5">
                    <span className="flex -space-x-1.5">
                      {assignees.slice(0, 3).map((a) => (
                        <Link key={a.login} href={href({ assignee: a.login })} scroll={false}>
                          <Avatar src={a.avatar} login={a.login} />
                        </Link>
                      ))}
                    </span>
                    {i.comments > 0 && (
                      <span className="muted inline-flex items-center gap-1 text-xs">
                        <MessageSquare size={14} />
                        {i.comments}
                      </span>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        ) : (
          <div className="p-6">
            <Empty title={filtered ? "没有符合条件的 Issue" : "暂无 Issue"} desc={filtered ? "尝试调整筛选条件。若仍在回填中，稍后会出现更多结果。" : "开启同步后将在后台分批拉取。"} />
          </div>
        )}
      </div>
      <NumberPager total={data.total} page={p.page} href={(n) => href({ page: String(n) })} />
    </>
  );
}

async function localCount(repositoryId: number, kind: "issues" | "discussions") {
  return kind === "issues" ? prisma.issue.count({ where: { repositoryId } }) : prisma.discussion.count({ where: { repositoryId } });
}

/** 首次打开该仓库的 Issues / Discussions Tab 且尚无同步记录时，按需立即拉取第 1 页（无需在 100+ 仓库的后台队列里排队等待） */
async function warmCommunityIfEmpty(repositoryId: number, kind: "issues" | "discussions") {
  const cur = await prisma.communitySync.findUnique({ where: { repositoryId_kind: { repositoryId, kind } } });
  if (cur && (cur.lastSyncedAt || cur.status === "running" || cur.scope === "off")) return;
  const row =
    cur ??
    (await prisma.communitySync
      .create({ data: { repositoryId, kind, nextSyncAt: new Date(0) } })
      .catch(() => prisma.communitySync.findUnique({ where: { repositoryId_kind: { repositoryId, kind } } })));
  if (!row) return;
  const lock = await prisma.communitySync.updateMany({ where: { id: row.id, status: { not: "running" }, lastSyncedAt: null }, data: { status: "running" } });
  if (lock.count !== 1) return;
  const { createGitHubClient } = await import("@/lib/github/factory");
  const { runCommunitySync } = await import("@/lib/community/sync");
  await runCommunitySync(row.id, await createGitHubClient(), 2).catch(() => undefined);
}

// ======================= Discussions =======================
export async function DiscussionsTab({ repo, sp }: { repo: Repo; sp: RawParams }) {
  await warmCommunityIfEmpty(repo.id, "discussions");
  const p = discussionParams(sp);
  const data = await queryDiscussions(repo.id, p);
  const cur: Record<string, string | string[]> = { q: p.q, category: p.category, label: p.labels, author: p.author, filter: p.filter === "open" ? "" : p.filter, sort: p.sort === "updated" ? "" : p.sort };
  const href = (patch: Record<string, string | string[] | undefined>) => makeHref(repo.id, "discussions", cur, patch);
  const filtered = !!(p.q || p.author || p.labels.length || p.category || p.filter !== "open");
  const base = `${repo.htmlUrl}/blob/${encodeURIComponent(repo.defaultBranch || "main")}`;
  const catLink = "flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm";
  return (
    <>
      <SyncStatus repo={repo} kind="discussions" local={await localCount(repo.id, "discussions")} />
      <div className="grid gap-4 md:grid-cols-[220px_1fr]">
        <aside className="card h-fit p-3">
          <h3 className="mb-2 px-2 text-sm font-semibold">分类</h3>
          <nav className="space-y-0.5">
            <Link href={href({ category: undefined })} scroll={false} className={`${catLink} ${!p.category ? "bg-brand-600 text-white" : "hover:bg-black/5 dark:hover:bg-white/5"}`}>
              <span>💬</span>
              <span className="flex-1">查看全部</span>
              <span className="text-xs opacity-70">{fmtNum(data.allCount)}</span>
            </Link>
            {data.facets.categories.map((c) => (
              <Link key={c.name} href={href({ category: c.name })} scroll={false} className={`${catLink} ${p.category === c.name ? "bg-brand-600 text-white" : "hover:bg-black/5 dark:hover:bg-white/5"}`}>
                <span>{c.emoji || "💬"}</span>
                <span className="flex-1 truncate">{c.name}</span>
                <span className="text-xs opacity-70">{fmtNum(c.count)}</span>
              </Link>
            ))}
          </nav>
        </aside>
        <div className="min-w-0">
          <AutoSubmitForm action={`/repos/${repo.id}`} className="card mb-3 grid gap-2 p-3 lg:grid-cols-[2fr_1fr_1fr_1fr_1fr_auto]">
            <input type="hidden" name="tab" value="discussions" />
            {p.category && <input type="hidden" name="category" value={p.category} />}
            <input className="input" name="q" defaultValue={p.q} placeholder="搜索标题、正文或 #编号" />
            <input className="input" name="author" defaultValue={p.author} placeholder="作者" />
            <select className="input" name="sort" defaultValue={p.sort} aria-label="排序">
              {DISCUSSION_SORTS.map(([k, l]) => (
                <option key={k} value={k}>
                  排序：{l}
                </option>
              ))}
            </select>
            <LabelPicker labels={data.facets.labels} selected={p.labels} />
            <select className="input" name="filter" defaultValue={p.filter} aria-label="状态">
              {DISCUSSION_FILTERS.map(([k, l]) => (
                <option key={k} value={k}>
                  {l}
                </option>
              ))}
            </select>
            <button className="btn-primary">筛选</button>
          </AutoSubmitForm>
          {filtered && (
            <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
              <span className="muted">共 {fmtNum(data.total)} 条</span>
              {p.labels.map((l) => (
                <Link key={l} href={href({ label: p.labels.filter((x) => x !== l) })} scroll={false} className="chip bg-black/5 hover:line-through dark:bg-white/10">
                  标签 {l} ✕
                </Link>
              ))}
              <Link className="text-brand-600 hover:underline" href={makeHref(repo.id, "discussions", {}, {})} scroll={false}>
                清除筛选
              </Link>
            </div>
          )}
          {data.rows.length ? (
            <ul className="card divide-y divide-black/5 overflow-hidden dark:divide-white/10">
              {data.rows.map((d) => {
                const labels = parseLabels(d.labels);
                return (
                  <li key={d.id} className="flex flex-wrap gap-3 px-4 py-3 hover:bg-black/[0.02] dark:hover:bg-white/[0.02]">
                    <span className="muted flex h-9 w-10 shrink-0 flex-col items-center justify-center rounded-lg border border-black/10 text-xs dark:border-white/15" title="点赞数">
                      <ArrowUp size={12} />
                      {d.upvotes}
                    </span>
                    <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-black/5 text-lg dark:bg-white/10">{d.categoryEmoji || "💬"}</span>
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-1.5">
                        <a href={d.htmlUrl} target="_blank" rel="noreferrer noopener" className="font-semibold hover:text-brand-600">
                          {d.title}
                        </a>
                        {d.closed && <span className="chip bg-violet-100 text-violet-800 dark:bg-violet-500/15 dark:text-violet-300">已关闭</span>}
                        {d.locked && <Lock size={12} className="muted" />}
                      </div>
                      {labels.length > 0 && (
                        <div className="mt-1 flex flex-wrap gap-1">
                          {labels.map((l) => (
                            <LabelChip key={l.name} name={l.name} color={l.color} href={p.labels.includes(l.name) ? undefined : href({ label: [...p.labels, l.name] })} />
                          ))}
                        </div>
                      )}
                      <div className="muted mt-1 flex flex-wrap items-center gap-x-1.5 text-xs">
                        {d.authorLogin && (
                          <Link href={href({ author: d.authorLogin })} scroll={false} className="hover:text-brand-600 hover:underline">
                            {d.authorLogin}
                          </Link>
                        )}
                        <span>
                          {d.isAnswerable ? "提问于" : "发起于"} {relTime(d.createdAtRemote)}
                        </span>
                        {d.categoryName && (
                          <>
                            <span>· 分类</span>
                            <Link href={href({ category: d.categoryName })} scroll={false} className="hover:underline">
                              {d.categoryName}
                            </Link>
                          </>
                        )}
                        {d.isAnswerable && <span className={d.isAnswered ? "text-emerald-600" : ""}>· {d.isAnswered ? "已解答" : "未解答"}</span>}
                        <span>· 活动 {relTime(d.updatedAtRemote)}</span>
                        <span>·</span>
                        <BodyPreview repoId={repo.id} kind="discussions" number={d.number} baseUrl={base} />
                      </div>
                    </div>
                    <div className="flex shrink-0 items-start gap-2 pt-0.5">
                      <Avatar src={d.authorAvatar} login={d.authorLogin ?? ""} />
                      <span className={`inline-flex items-center gap-1 text-xs ${d.isAnswered ? "text-emerald-600" : "muted"}`}>
                        {d.isAnswered ? <CircleCheck size={14} /> : <MessageSquare size={14} />}
                        {d.comments}
                      </span>
                    </div>
                  </li>
                );
              })}
            </ul>
          ) : (
            <div className="card p-6">
              <Empty title={filtered ? "没有符合条件的 Discussion" : "暂无 Discussion"} desc={filtered ? "尝试调整筛选条件。若仍在回填中，稍后会出现更多结果。" : "该仓库可能未启用 Discussions，或正在等待首次同步。"} />
            </div>
          )}
          <NumberPager total={data.total} page={p.page} href={(n) => href({ page: String(n) })} />
        </div>
      </div>
    </>
  );
}
