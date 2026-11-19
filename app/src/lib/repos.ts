import { prisma } from "./db";
import { GitHubClient, GitHubError } from "./github/client";
import { parseRepoInput, repoKey } from "./github/parse";
import type { GhRepo } from "./github/types";
import { enqueueSync } from "./sync/queue";

export type AddResult =
  | { input: string; ok: true; repository: { id: number; fullName: string }; message: string }
  | { input: string; ok: false; code: "invalid" | "duplicate" | "not_found" | "rate_limited" | "error"; message: string; repository?: { id: number; fullName: string } };

/** 添加仓库：解析输入 → 去重 → 调用 GitHub 获取基础信息 → 入库 → 排队首次完整同步 */
export async function addRepository(input: string, gh: GitHubClient, opts: { pollIntervalMinutes?: number | null; categoryId?: number | null } = {}): Promise<AddResult> {
  const ref = parseRepoInput(input);
  if ("error" in ref) return { input, ok: false, code: "invalid", message: ref.error };
  const key = repoKey(ref.owner, ref.name);
  const dup = await prisma.repository.findUnique({ where: { provider_fullNameKey: { provider: "github", fullNameKey: key } } });
  if (dup) return { input, ok: false, code: "duplicate", message: `仓库 ${dup.fullName} 已存在`, repository: { id: dup.id, fullName: dup.fullName } };

  let r: GhRepo;
  try {
    r = (await gh.request<GhRepo>(`/repos/${ref.owner}/${ref.name}`)).data;
  } catch (e) {
    if (e instanceof GitHubError) {
      if (e.kind === "not_found") return { input, ok: false, code: "not_found", message: `仓库 ${ref.owner}/${ref.name} 不存在或无权访问` };
      if (e.kind === "rate_limited") return { input, ok: false, code: "rate_limited", message: `GitHub API 限流，请在 ${e.retryAt?.toLocaleTimeString("zh-CN") ?? "稍后"} 后重试，或在设置中配置 Token` };
    }
    return { input, ok: false, code: "error", message: (e as Error).message };
  }
  // 重定向（改名）后再次按真实名称 / 仓库 ID 去重
  const realKey = r.full_name.toLowerCase();
  const dup2 = await prisma.repository.findFirst({ where: { provider: "github", OR: [{ fullNameKey: realKey }, { providerRepoId: String(r.id) }] } });
  if (dup2) return { input, ok: false, code: "duplicate", message: `仓库 ${dup2.fullName} 已存在`, repository: { id: dup2.id, fullName: dup2.fullName } };

  const repo = await prisma.repository.create({
    data: {
      provider: "github",
      providerRepoId: String(r.id),
      owner: r.owner.login,
      name: r.name,
      fullName: r.full_name,
      fullNameKey: realKey,
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
      repoCreatedAt: new Date(r.created_at),
      repoUpdatedAt: new Date(r.updated_at),
      pushedAt: r.pushed_at ? new Date(r.pushed_at) : null,
      pollIntervalMinutes: opts.pollIntervalMinutes ?? null,
      categoryId: opts.categoryId ?? null,
      nextSyncAt: null,
    },
  });
  await enqueueSync(repo.id, { trigger: "import", mode: "full" });
  for (const kind of ["issues", "discussions"]) {
    await prisma.communitySync.create({ data: { repositoryId: repo.id, kind, nextSyncAt: new Date() } }).catch(() => undefined);
  }
  return { input, ok: true, repository: { id: repo.id, fullName: repo.fullName }, message: `已添加 ${repo.fullName}，正在后台同步` };
}
