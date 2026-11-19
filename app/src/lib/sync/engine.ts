/**
 * 仓库同步引擎：四种独立的版本发现机制
 *   A. GitHub Releases（含全部 Assets，分页）
 *   B. Git Tags（分页，Tag ≠ Release）
 *   C. 默认分支 Commits（HEAD 变化检测）
 *   D. Changelog / 版本文件 / 自定义监控文件
 * 所有记录使用唯一约束 + upsert 去重；首次同步只建立基线，不推送通知。
 */
import type { Prisma, Repository } from "@prisma/client";
import { prisma } from "../db";
import { classifyAsset, isSoftwareAsset, parseDigest } from "../assets";
import { CHANGELOG_RE, LOGO_RE, README_RE, VERSION_FILES, parseChangelog, parseVersionFile } from "../changelog";
import { GitHubClient, GitHubError, rateLimitState } from "../github/client";
import type { GhCommit, GhContentEntry, GhGitCommit, GhRelease, GhRepo, GhTag } from "../github/types";
import { getNumberSetting } from "../settings";
import { computeStatus } from "../status";
import { selectLatestTag } from "../version";
import { dispatchNotifications, type NotifyItem } from "../notify";

export type SyncMode = "full" | "incremental";

export interface SyncResult {
  ok: boolean;
  status: "success" | "failed" | "partial";
  newReleases: number;
  newTags: number;
  newCommits: number;
  newAssets: number;
  newChangelog: number;
  discovered: { type: string; version?: string | null; title: string; url?: string | null }[];
  errors: string[];
  requestCount: number;
  notModifiedCount: number;
  durationMs: number;
  fatal?: GitHubError;
  summary: string;
}

const d = (s: string | null | undefined) => (s ? new Date(s) : null);
const enc = (s: string) => s.split("/").map(encodeURIComponent).join("/");

interface Ctx {
  repo: Repository;
  gh: GitHubClient;
  mode: SyncMode;
  base: string; // /repos/owner/name
  baseline: boolean; // 本次是否为首次基线同步
  baselineAt: Date | null;
  result: SyncResult;
  newEvents: { id: number; sourceType: string; eventType: string; title: string; url: string | null; isBaseline: boolean }[];
  headChanged: boolean;
}

async function ensureEvent(
  ctx: Ctx,
  data: { sourceType: string; eventType: string; sourceKey: string; version?: string | null; title: string; url?: string | null; occurredAt?: Date | null; forceBaseline?: boolean },
) {
  const existing = await prisma.versionEvent.findUnique({
    where: { repositoryId_sourceType_sourceKey: { repositoryId: ctx.repo.id, sourceType: data.sourceType, sourceKey: data.sourceKey } },
    select: { id: true },
  });
  if (existing) return false;
  // 早于开始监控时间的历史内容（如后续分页补全的旧 Release）同样视为基线
  const isBaseline = ctx.baseline || !!data.forceBaseline || (!!data.occurredAt && !!ctx.baselineAt && data.occurredAt < new Date(ctx.baselineAt.getTime() - 86400_000));
  try {
    const ev = await prisma.versionEvent.create({
      data: { repositoryId: ctx.repo.id, sourceType: data.sourceType, eventType: data.eventType, sourceKey: data.sourceKey, version: data.version ?? null, title: data.title, url: data.url ?? null, occurredAt: data.occurredAt ?? null, isBaseline },
    });
    ctx.newEvents.push({ id: ev.id, sourceType: ev.sourceType, eventType: ev.eventType, title: ev.title, url: ev.url, isBaseline });
    if (!isBaseline) ctx.result.discovered.push({ type: data.eventType, version: data.version, title: data.title, url: data.url });
    return true;
  } catch (e) {
    if ((e as { code?: string }).code === "P2002") return false;
    throw e;
  }
}

// ---------- 仓库基础信息 ----------
async function syncRepoInfo(ctx: Ctx) {
  const res = await ctx.gh.request<GhRepo>(ctx.base);
  const r = res.data;
  const key = r.full_name.toLowerCase();
  const data: Prisma.RepositoryUpdateInput = {
    providerRepoId: String(r.id),
    description: r.description,
    homepage: r.homepage || null,
    htmlUrl: r.html_url,
    avatarUrl: r.owner.avatar_url,
    stars: r.stargazers_count,
    forks: r.forks_count,
    watchers: r.subscribers_count ?? r.watchers_count,
    license: r.license ? (r.license.spdx_id && r.license.spdx_id !== "NOASSERTION" ? r.license.spdx_id : r.license.name) : null,
    language: r.language,
    topics: JSON.stringify(r.topics ?? []),
    defaultBranch: r.default_branch,
    isArchived: r.archived,
    isFork: r.fork,
    repoCreatedAt: d(r.created_at),
    repoUpdatedAt: d(r.updated_at),
    pushedAt: d(r.pushed_at),
    accessible: true,
  };
  // 仓库改名 / 转移：GitHub 会 301 重定向，更新为新名称
  if (key !== ctx.repo.fullNameKey) {
    const clash = await prisma.repository.findFirst({ where: { provider: "github", fullNameKey: key, NOT: { id: ctx.repo.id } } });
    if (!clash) Object.assign(data, { owner: r.owner.login, name: r.name, fullName: r.full_name, fullNameKey: key });
  }
  ctx.repo = await prisma.repository.update({ where: { id: ctx.repo.id }, data });
  ctx.base = `/repos/${ctx.repo.owner}/${ctx.repo.name}`;
}

// ---------- A. Releases ----------
async function upsertRelease(ctx: Ctx, rel: GhRelease): Promise<boolean> {
  const where = { repositoryId_providerId: { repositoryId: ctx.repo.id, providerId: String(rel.id) } };
  const existing = await prisma.release.findUnique({ where, select: { id: true } });
  const fields = {
    tagName: rel.tag_name,
    name: rel.name,
    body: rel.body,
    isPrerelease: rel.prerelease,
    isDraft: rel.draft,
    publishedAt: d(rel.published_at),
    createdAtRemote: d(rel.created_at),
    htmlUrl: rel.html_url,
    zipballUrl: rel.zipball_url,
    tarballUrl: rel.tarball_url,
    authorLogin: rel.author?.login ?? null,
    targetCommitish: rel.target_commitish,
    assetCount: rel.assets.length,
  };
  const row = existing
    ? await prisma.release.update({ where: { id: existing.id }, data: fields })
    : await prisma.release.create({ data: { repositoryId: ctx.repo.id, providerId: String(rel.id), ...fields } });
  if (!existing) ctx.result.newReleases++;

  for (const a of rel.assets) {
    const info = classifyAsset(a.name, a.content_type);
    const af = {
      name: a.name,
      label: a.label,
      contentType: a.content_type,
      size: a.size,
      downloadCount: a.download_count,
      downloadUrl: a.browser_download_url, // 仅使用 API 返回的真实地址
      sha256: parseDigest(a.digest),
      ...info,
      createdAtRemote: d(a.created_at),
      updatedAtRemote: d(a.updated_at),
    };
    const aw = { releaseId_providerId: { releaseId: row.id, providerId: String(a.id) } };
    const ex = await prisma.asset.findUnique({ where: aw, select: { id: true } });
    if (ex) await prisma.asset.update({ where: { id: ex.id }, data: af });
    else {
      await prisma.asset.create({ data: { repositoryId: ctx.repo.id, releaseId: row.id, providerId: String(a.id), ...af } });
      ctx.result.newAssets++;
    }
  }
  // 保留已从上游删除的历史附件；链接可能不再可用。

  if (!rel.draft) {
    await ensureEvent(ctx, {
      sourceType: "release",
      eventType: rel.prerelease ? "prerelease_published" : "release_published",
      sourceKey: String(rel.id),
      version: rel.tag_name,
      title: `${rel.prerelease ? "预发布" : "新版本"} ${rel.name || rel.tag_name}`,
      url: rel.html_url,
      occurredAt: d(rel.published_at),
    });
  }
  return !existing;
}

async function syncReleases(ctx: Ctx) {
  const maxPages = await getNumberSetting("sync.maxReleasePages");
  let changed = false;
  await ctx.gh.paginate<GhRelease>(`${ctx.base}/releases?per_page=100`, ctx.mode === "full" ? maxPages : maxPages, async (items, res, page) => {
    if (ctx.mode === "incremental" && res.notModified && page === 1) return false; // 第一页未变化 → 没有新 Release
    changed = true;
    let newOnPage = 0;
    for (const rel of items) if (await upsertRelease(ctx, rel)) newOnPage++;
    if (items.length < 100) return false;
    // 增量模式：本页全部为新记录才继续翻页，否则已追上历史
    if (ctx.mode === "incremental" && newOnPage < items.length) return false;
    if (page >= maxPages && res.link.next) throw new GitHubError("Release 超出分页上限，请在设置中提高上限后重试", "other");
    return true;
  });
  if (changed || ctx.mode === "full") {
    try {
      const latest = await ctx.gh.request<GhRelease>(`${ctx.base}/releases/latest`);
      await prisma.release.updateMany({ where: { repositoryId: ctx.repo.id, isLatest: true, NOT: { providerId: String(latest.data.id) } }, data: { isLatest: false } });
      await prisma.release.updateMany({ where: { repositoryId: ctx.repo.id, providerId: String(latest.data.id) }, data: { isLatest: true } });
    } catch (e) {
      if (e instanceof GitHubError && e.kind === "not_found") await prisma.release.updateMany({ where: { repositoryId: ctx.repo.id }, data: { isLatest: false } });
      else throw e;
    }
  }
}

// ---------- B. Tags ----------
async function syncTags(ctx: Ctx) {
  const maxPages = await getNumberSetting("sync.maxTagPages");
  await ctx.gh.paginate<GhTag>(`${ctx.base}/tags?per_page=100`, maxPages, async (items, res, page) => {
    if (ctx.mode === "incremental" && res.notModified && page === 1) return false;
    let newOnPage = 0;
    for (const t of items) {
      const where = { repositoryId_name: { repositoryId: ctx.repo.id, name: t.name } };
      const ex = await prisma.tag.findUnique({ where });
      if (!ex) {
        await prisma.tag.create({ data: { repositoryId: ctx.repo.id, name: t.name, commitSha: t.commit.sha, zipballUrl: t.zipball_url, tarballUrl: t.tarball_url } });
        ctx.result.newTags++;
        newOnPage++;
      } else if (ex.commitSha !== t.commit.sha) {
        await prisma.tag.update({ where: { id: ex.id }, data: { commitSha: t.commit.sha, commitDate: null } }); // Tag 被移动
      }
      await ensureEvent(ctx, { sourceType: "tag", eventType: "tag_created", sourceKey: t.name, version: t.name, title: `新 Tag ${t.name}`, url: `${ctx.repo.htmlUrl}/tree/${encodeURIComponent(t.name)}` });
    }
    if (items.length < 100) return false;
    if (ctx.mode === "incremental" && newOnPage < items.length) return false;
    if (page >= maxPages && res.link.next) throw new GitHubError("Tag 超出分页上限，请在设置中提高上限后重试", "other");
    return true;
  });

  // 补全 Tag 对应提交时间（每次同步限量，避免大量请求）
  const budget = await getNumberSetting("sync.tagDateBackfillPerSync");
  if (budget > 0) {
    const missing = await prisma.tag.findMany({ where: { repositoryId: ctx.repo.id, commitDate: null }, orderBy: { id: "asc" }, take: budget });
    for (const t of missing) {
      try {
        const c = await ctx.gh.request<GhGitCommit>(`${ctx.base}/git/commits/${t.commitSha}`);
        const date = d(c.data.committer?.date ?? c.data.author?.date);
        await prisma.tag.update({ where: { id: t.id }, data: { commitDate: date } });
        await prisma.versionEvent.updateMany({ where: { repositoryId: ctx.repo.id, sourceType: "tag", sourceKey: t.name, occurredAt: null }, data: { occurredAt: date } });
      } catch (e) {
        if (e instanceof GitHubError && (e.kind === "not_found" || e.kind === "other")) {
          // 例如 Tag 指向非 commit 对象：写入 epoch 0 标记为不可解析，避免反复请求
          await prisma.tag.update({ where: { id: t.id }, data: { commitDate: new Date(0) } });
        } else throw e;
      }
    }
  }
}

// ---------- C. Commits ----------
function toCommitRow(ctx: Ctx, c: GhCommit) {
  return {
    repositoryId: ctx.repo.id,
    sha: c.sha,
    shortSha: c.sha.slice(0, 7),
    message: c.commit.message.slice(0, 5000),
    authorName: c.commit.author?.name ?? null,
    authorLogin: c.author?.login ?? null,
    authorAvatar: c.author?.avatar_url ?? null,
    committedAt: d(c.commit.committer?.date ?? c.commit.author?.date),
    htmlUrl: c.html_url,
    branch: ctx.repo.defaultBranch,
  };
}

async function syncCommits(ctx: Ctx) {
  const branch = ctx.repo.defaultBranch;
  if (!branch) return;
  let head: string;
  try {
    const r = await ctx.gh.request<string>(`${ctx.base}/commits/${enc(branch)}`, { accept: "application/vnd.github.sha", text: true });
    head = r.data.trim();
  } catch (e) {
    if (e instanceof GitHubError && (e.kind === "empty" || e.kind === "not_found")) return; // 空仓库
    throw e;
  }
  ctx.headChanged = head !== ctx.repo.headSha;
  const hasAny = await prisma.commit.count({ where: { repositoryId: ctx.repo.id } });
  if (!ctx.headChanged && ctx.mode === "incremental" && hasAny > 0) return;

  const known = new Set((await prisma.commit.findMany({ where: { repositoryId: ctx.repo.id }, select: { sha: true }, orderBy: { committedAt: "desc" }, take: 2000 })).map((x) => x.sha));
  const fresh: GhCommit[] = [];
  if (ctx.baseline || hasAny === 0) {
    const n = Math.max(1, Math.min(100, ctx.repo.initialCommitCount ?? (await getNumberSetting("sync.initialCommitCount"))));
    const r = await ctx.gh.request<GhCommit[]>(`${ctx.base}/commits?sha=${encodeURIComponent(branch)}&per_page=${n}`);
    fresh.push(...r.data.filter((c) => !known.has(c.sha)));
  } else {
    // 增量：从 HEAD 向前翻页直到遇到已知提交（最多 3 页 / 300 条，防止强推后无限翻页）
    await ctx.gh.paginate<GhCommit>(`${ctx.base}/commits?sha=${encodeURIComponent(branch)}&per_page=100`, 3, async (items) => {
      for (const c of items) {
        if (known.has(c.sha)) return false;
        fresh.push(c);
      }
      return items.length === 100;
    });
  }
  for (const c of fresh) {
    try {
      await prisma.commit.create({ data: toCommitRow(ctx, c) });
      ctx.result.newCommits++;
    } catch (e) {
      if ((e as { code?: string }).code !== "P2002") throw e;
    }
  }
  // 版本事件：基线只记录 HEAD；之后每个新提交记录一条（通知时合并）
  const forEvents = ctx.baseline || hasAny === 0 ? fresh.filter((c) => c.sha === head) : fresh;
  for (const c of forEvents) {
    await ensureEvent(ctx, {
      sourceType: "commit",
      eventType: "commit_pushed",
      sourceKey: c.sha,
      version: c.sha.slice(0, 7),
      title: `提交 ${c.sha.slice(0, 7)}：${c.commit.message.split("\n")[0].slice(0, 120)}`,
      url: c.html_url,
      occurredAt: d(c.commit.committer?.date),
      forceBaseline: hasAny === 0,
    });
  }
  // 总提交数：per_page=1 时 Link 头 last 页码即为总数
  let total: number | null = null;
  try {
    const r = await ctx.gh.request<GhCommit[]>(`${ctx.base}/commits?sha=${encodeURIComponent(branch)}&per_page=1`);
    const last = r.link.last?.match(/[?&]page=(\d+)/);
    total = last ? Number(last[1]) : r.data.length;
  } catch {
    /* 非关键 */
  }
  ctx.repo = await prisma.repository.update({ where: { id: ctx.repo.id }, data: { headSha: head, ...(total !== null ? { totalCommits: total } : {}) } });
}

// ---------- D. Changelog / 版本文件 ----------
async function fetchRaw(ctx: Ctx, path: string) {
  const r = await ctx.gh.request<string>(`${ctx.base}/contents/${enc(path)}`, { accept: "application/vnd.github.raw+json", text: true });
  return r.data;
}

async function syncFiles(ctx: Ctx) {
  const shouldCheck = ctx.headChanged || ctx.mode === "full" || ctx.baseline || !ctx.repo.rootTree;
  if (!shouldCheck) return;
  let root: GhContentEntry[];
  try {
    root = (await ctx.gh.request<GhContentEntry[]>(`${ctx.base}/contents`)).data;
  } catch (e) {
    if (e instanceof GitHubError && (e.kind === "not_found" || e.kind === "empty")) return;
    throw e;
  }
  if (!Array.isArray(root)) return;
  const tree = root.map((x) => ({ name: x.name, path: x.path, type: x.type, size: x.size, sha: x.sha, url: x.html_url }));
  const logo = root.find((x) => x.type === "file" && LOGO_RE.test(x.name) && x.download_url);
  const upd: Prisma.RepositoryUpdateInput = { rootTree: JSON.stringify(tree), logoUrl: logo?.download_url ?? null };

  const readme = root.find((x) => x.type === "file" && README_RE.test(x.name));
  if (readme && readme.sha !== ctx.repo.readmeSha) {
    try {
      const text = await fetchRaw(ctx, readme.path);
      Object.assign(upd, { readme: text.slice(0, 300_000), readmeSha: readme.sha });
    } catch {
      /* README 获取失败不影响同步 */
    }
  }
  ctx.repo = await prisma.repository.update({ where: { id: ctx.repo.id }, data: upd });

  // 候选文件：根目录 Changelog / 版本文件 + 用户自定义监控文件（README 永不视为版本）
  const candidates: { path: string; sha: string | null; kind: "changelog" | "version_file" | "custom" }[] = [];
  for (const f of root) {
    if (f.type !== "file") continue;
    if (CHANGELOG_RE.test(f.name)) candidates.push({ path: f.path, sha: f.sha, kind: "changelog" });
    else if (VERSION_FILES.includes(f.name)) candidates.push({ path: f.path, sha: f.sha, kind: "version_file" });
  }
  let watched: string[] = [];
  try {
    watched = JSON.parse(ctx.repo.watchedFiles);
  } catch {
    /* ignore */
  }
  for (const p of watched.slice(0, 20)) {
    if (candidates.some((c) => c.path === p) || README_RE.test(p.split("/").pop() ?? "")) continue;
    try {
      const meta = await ctx.gh.request<GhContentEntry>(`${ctx.base}/contents/${enc(p)}`);
      if (!Array.isArray(meta.data)) candidates.push({ path: p, sha: meta.data.sha, kind: CHANGELOG_RE.test(meta.data.name) ? "changelog" : VERSION_FILES.includes(meta.data.name) ? "version_file" : "custom" });
    } catch (e) {
      if (!(e instanceof GitHubError && e.kind === "not_found")) throw e;
    }
  }

  for (const c of candidates) {
    const tf = await prisma.trackedFile.findUnique({ where: { repositoryId_path: { repositoryId: ctx.repo.id, path: c.path } } });
    const firstTime = !tf;
    if (tf && tf.lastSha === c.sha) {
      await prisma.trackedFile.update({ where: { id: tf.id }, data: { lastCheckedAt: new Date() } });
      continue;
    }
    let text = "";
    try {
      text = await fetchRaw(ctx, c.path);
    } catch {
      continue;
    }
    let version: string | null = null;
    if (c.kind === "changelog") {
      const entries = parseChangelog(text, 100);
      version = entries[0]?.version ?? null;
      for (const e of entries) {
        const ex = await prisma.changelogEntry.findUnique({ where: { repositoryId_filePath_version: { repositoryId: ctx.repo.id, filePath: c.path, version: e.version } } });
        if (ex) {
          if (ex.body !== e.body) await prisma.changelogEntry.update({ where: { id: ex.id }, data: { body: e.body, title: e.title, entryDate: e.date } });
          continue;
        }
        await prisma.changelogEntry.create({ data: { repositoryId: ctx.repo.id, filePath: c.path, version: e.version, title: e.title, body: e.body, entryDate: e.date } });
        ctx.result.newChangelog++;
        await ensureEvent(ctx, {
          sourceType: "changelog",
          eventType: "changelog_entry",
          sourceKey: `${c.path}@${e.version}`,
          version: e.version,
          title: `Changelog 新增 ${e.version}`,
          url: `${ctx.repo.htmlUrl}/blob/${ctx.repo.defaultBranch}/${c.path}`,
          forceBaseline: firstTime,
        });
      }
    } else if (c.kind === "version_file") {
      version = parseVersionFile(c.path, text);
      if (version && version !== tf?.lastVersion) {
        await ensureEvent(ctx, {
          sourceType: "changelog",
          eventType: "version_file_changed",
          sourceKey: `${c.path}@${version}`,
          version,
          title: `${c.path} 版本 ${tf?.lastVersion ? `${tf.lastVersion} → ` : ""}${version}`,
          url: `${ctx.repo.htmlUrl}/blob/${ctx.repo.defaultBranch}/${c.path}`,
          forceBaseline: firstTime,
        });
      }
    } else if (!firstTime) {
      await ensureEvent(ctx, { sourceType: "changelog", eventType: "file_changed", sourceKey: `${c.path}@${c.sha}`, title: `监控文件 ${c.path} 已变化`, url: `${ctx.repo.htmlUrl}/blob/${ctx.repo.defaultBranch}/${c.path}` });
    }
    const now = new Date();
    await prisma.trackedFile.upsert({
      where: { repositoryId_path: { repositoryId: ctx.repo.id, path: c.path } },
      create: { repositoryId: ctx.repo.id, path: c.path, kind: c.kind, lastSha: c.sha, lastVersion: version, lastCheckedAt: now, lastChangedAt: now },
      update: { kind: c.kind, lastSha: c.sha, lastVersion: version ?? tf?.lastVersion, lastCheckedAt: now, lastChangedAt: now },
    });
  }
}

// ---------- 派生字段 ----------
export async function recomputeDerived(repoId: number) {
  const repo = await prisma.repository.findUniqueOrThrow({ where: { id: repoId } });
  const [releases, assets, tags, commitCount, trackedCount, headCommit] = await Promise.all([
    prisma.release.findMany({ where: { repositoryId: repoId, isDraft: false }, select: { tagName: true, isPrerelease: true, isLatest: true, publishedAt: true } }),
    prisma.asset.findMany({ where: { repositoryId: repoId }, select: { kind: true, platform: true, fileType: true } }),
    prisma.tag.findMany({ where: { repositoryId: repoId }, select: { name: true, commitDate: true } }),
    prisma.commit.count({ where: { repositoryId: repoId } }),
    prisma.trackedFile.count({ where: { repositoryId: repoId } }),
    repo.headSha ? prisma.commit.findUnique({ where: { repositoryId_sha: { repositoryId: repoId, sha: repo.headSha } } }) : null,
  ]);
  const sw = assets.filter(isSoftwareAsset);
  const platforms = [...new Set(sw.map((a) => a.platform).filter((p) => p !== "unknown"))];
  const fileTypes = [...new Set(sw.map((a) => a.fileType))];

  let latestVersion: string | null = null;
  let latestVersionSource: string | null = null;
  let latestVersionAt: Date | null = null;
  const stable = releases.filter((r) => !r.isPrerelease);
  const pick = stable.find((r) => r.isLatest) ?? [...stable].sort((a, b) => (b.publishedAt?.getTime() ?? 0) - (a.publishedAt?.getTime() ?? 0))[0] ?? [...releases].sort((a, b) => (b.publishedAt?.getTime() ?? 0) - (a.publishedAt?.getTime() ?? 0))[0];
  if (pick) {
    latestVersion = pick.tagName;
    latestVersionSource = "release";
    latestVersionAt = pick.publishedAt;
  } else if (tags.length) {
    // 混合命名体系且日期未补全时不猜测；日期齐全则按对应提交时间判断。
    const t = selectLatestTag(tags);
    latestVersion = t?.name ?? null;
    latestVersionSource = "tag";
    latestVersionAt = t?.commitDate && t.commitDate.getTime() > 0 ? t.commitDate : null;
  } else if (headCommit) {
    latestVersion = headCommit.shortSha;
    latestVersionSource = "commit";
    latestVersionAt = headCommit.committedAt;
  } else {
    const cl = await prisma.trackedFile.findFirst({ where: { repositoryId: repoId, lastVersion: { not: null } }, orderBy: { lastChangedAt: "desc" } });
    if (cl) {
      latestVersion = cl.lastVersion;
      latestVersionSource = "changelog";
      latestVersionAt = cl.lastChangedAt;
    }
  }
  const dates = [repo.pushedAt, latestVersionAt, headCommit?.committedAt ?? null].filter(Boolean) as Date[];
  const latestActivityAt = dates.length ? new Date(Math.max(...dates.map((x) => x.getTime()))) : null;
  const staleDays = await getNumberSetting("sync.staleDays");
  const status = computeStatus({
    accessible: repo.accessible,
    isArchived: repo.isArchived,
    synced: !!repo.lastSyncedAt || repo.baselineEstablished,
    releaseCount: releases.length,
    softwareAssetCount: sw.length,
    tagCount: tags.length,
    commitCount,
    trackedFileCount: trackedCount,
    lastActivityAt: latestActivityAt,
    staleDays,
  });
  return prisma.repository.update({
    where: { id: repoId },
    data: {
      hasReleases: releases.length > 0,
      hasTags: tags.length > 0,
      hasAssets: sw.length > 0,
      platforms: JSON.stringify(platforms),
      fileTypes: JSON.stringify(fileTypes),
      latestVersion,
      latestVersionSource,
      latestVersionAt,
      latestActivityAt,
      status,
    },
  });
}

// ---------- 通知 ----------
async function buildNotifications(ctx: Ctx): Promise<NotifyItem[]> {
  const r = ctx.repo;
  if (!r.notifyEnabled) return [];
  const evs = ctx.newEvents.filter((e) => !e.isBaseline);
  const out: NotifyItem[] = [];
  const commits: typeof evs = [];
  for (const e of evs) {
    const allow =
      (e.eventType === "release_published" && r.notifyRelease) ||
      (e.eventType === "prerelease_published" && r.notifyPrerelease) ||
      (e.eventType === "tag_created" && r.notifyTag) ||
      (e.eventType === "commit_pushed" && r.notifyCommit) ||
      (e.sourceType === "changelog" && r.notifyChangelog);
    if (!allow) continue;
    if (e.eventType === "commit_pushed") commits.push(e);
    else out.push({ repositoryId: r.id, versionEventId: e.id, title: e.title, url: e.url });
  }
  if (commits.length === 1) out.push({ repositoryId: r.id, versionEventId: commits[0].id, title: commits[0].title, url: commits[0].url });
  else if (commits.length > 1) out.push({ repositoryId: r.id, versionEventId: commits[0].id, title: `${commits.length} 个新提交`, body: commits.map((c) => c.title).join("\n"), url: `${r.htmlUrl}/commits/${r.defaultBranch}` });
  return out;
}

// ---------- 主流程 ----------
export async function syncRepository(repoId: number, gh: GitHubClient, opts: { mode?: SyncMode; trigger?: string; taskId?: number } = {}): Promise<SyncResult> {
  const started = new Date();
  const req0 = gh.stats.requests;
  const nm0 = gh.stats.notModified;
  let repo = await prisma.repository.findUniqueOrThrow({ where: { id: repoId } });
  const baseline = !repo.baselineEstablished;
  const result: SyncResult = { ok: true, status: "success", newReleases: 0, newTags: 0, newCommits: 0, newAssets: 0, newChangelog: 0, discovered: [], errors: [], requestCount: 0, notModifiedCount: 0, durationMs: 0, summary: "" };
  const ctx: Ctx = { repo, gh, mode: baseline ? "full" : opts.mode ?? "incremental", base: `/repos/${repo.owner}/${repo.name}`, baseline, baselineAt: repo.baselineAt, result, newEvents: [], headChanged: false };

  try {
    await syncRepoInfo(ctx);
  } catch (e) {
    const err = e as GitHubError;
    result.ok = false;
    result.status = "failed";
    result.fatal = err instanceof GitHubError ? err : new GitHubError(String(err), "other");
    result.errors.push(`仓库信息：${err.message}`);
    if (err instanceof GitHubError && (err.kind === "not_found" || err.kind === "forbidden")) {
      // 仓库删除 / 私有化 / 被封禁：标记不可访问，保留全部历史数据
      await prisma.repository.update({ where: { id: repoId }, data: { accessible: false, status: "inaccessible", lastError: err.message } });
    }
  }

  if (result.ok) {
    // 四种机制相互独立：一种失败不影响其他；限流错误则立刻中止，交由队列延后重试
    const steps: [string, (c: Ctx) => Promise<void>][] = [
      ["Releases", syncReleases],
      ["Tags", syncTags],
      ["Commits", syncCommits],
      ["文件", syncFiles],
    ];
    for (const [label, fn] of steps) {
      try {
        await fn(ctx);
      } catch (e) {
        const err = e instanceof GitHubError ? e : new GitHubError((e as Error).message, "other");
        result.errors.push(`${label}：${err.message}`);
        if (err.kind === "rate_limited") {
          result.fatal = err;
          break;
        }
      }
    }
    result.status = result.errors.length === 0 ? "success" : result.fatal ? "failed" : "partial";
    result.ok = result.status !== "failed";
  }

  const finished = new Date();
  result.durationMs = finished.getTime() - started.getTime();
  result.requestCount = gh.stats.requests - req0;
  result.notModifiedCount = gh.stats.notModified - nm0;
  const parts = [
    result.newReleases && `${result.newReleases} 个 Release`,
    result.newTags && `${result.newTags} 个 Tag`,
    result.newCommits && `${result.newCommits} 个 Commit`,
    result.newAssets && `${result.newAssets} 个附件`,
    result.newChangelog && `${result.newChangelog} 条 Changelog`,
  ].filter(Boolean);
  result.summary = result.status === "failed" ? `同步失败：${result.errors[0]}` : `${baseline ? "首次同步建立基线" : "检查完成"}${parts.length ? `，新增 ${parts.join("、")}` : "，无变化"}${result.status === "partial" ? "（部分步骤失败）" : ""}`;

  const fullySynced = result.status !== "failed";
  await prisma.repository.update({
    where: { id: repoId },
    data: {
      lastSyncedAt: finished,
      lastSyncStatus: result.status,
      lastSyncDurationMs: result.durationMs,
      lastError: result.errors.length ? result.errors.join("；").slice(0, 2000) : null,
      consecutiveFailures: result.status === "failed" ? { increment: 1 } : 0,
      ...(result.status === "success" && baseline ? { baselineEstablished: true, baselineAt: started } : {}),
    },
  });
  if (fullySynced || ctx.repo.accessible === false) await recomputeDerived(repoId).catch(() => undefined);

  await prisma.syncLog.create({
    data: {
      repositoryId: repoId,
      taskId: opts.taskId,
      trigger: opts.trigger,
      mode: ctx.mode,
      status: result.status,
      startedAt: started,
      finishedAt: finished,
      durationMs: result.durationMs,
      requestCount: result.requestCount,
      notModifiedCount: result.notModifiedCount,
      newReleases: result.newReleases,
      newTags: result.newTags,
      newCommits: result.newCommits,
      newAssets: result.newAssets,
      newChangelog: result.newChangelog,
      summary: result.summary,
      error: result.errors.length ? result.errors.join("\n") : null,
      details: JSON.stringify({ discovered: result.discovered.slice(0, 50), baseline }),
      rateLimitRemaining: rateLimitState.remaining,
    },
  });

  if (!baseline) {
    const items = await buildNotifications(ctx);
    await dispatchNotifications(items).catch(() => undefined);
  }
  repo = ctx.repo;
  return result;
}
