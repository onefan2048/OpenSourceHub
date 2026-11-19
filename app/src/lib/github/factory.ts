import { GitHubClient } from "./client";
import { PrismaCacheStore } from "./prismaCache";
import { getGitHubToken } from "../settings";

export async function createGitHubClient(overrides: Partial<ConstructorParameters<typeof GitHubClient>[0]> = {}) {
  const token = await getGitHubToken();
  return new GitHubClient({
    token,
    cache: new PrismaCacheStore(),
    maxConcurrency: 4,
    minIntervalMs: token ? 100 : 250, // 匿名访问额度低（60 次/小时），请求间隔更大
    ...overrides,
  });
}
