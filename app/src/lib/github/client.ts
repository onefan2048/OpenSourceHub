/**
 * GitHub REST API 客户端
 * - 可选 Personal Access Token；无 Token 时匿名访问公开仓库
 * - ETag / If-None-Match、Last-Modified / If-Modified-Since 条件请求，正确处理 304
 * - 处理主速率限制（X-RateLimit-Remaining / X-RateLimit-Reset）与次级限制（Retry-After）
 * - 5xx / 网络错误指数退避重试
 * - 请求队列：并发上限 + 最小请求间隔
 * 参考：https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api
 *       https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
 */

export type GitHubErrorKind = "not_found" | "rate_limited" | "forbidden" | "server" | "network" | "empty" | "unauthorized" | "other";

export class GitHubError extends Error {
  constructor(
    message: string,
    public kind: GitHubErrorKind,
    public status?: number,
    public retryAt?: Date,
  ) {
    super(message);
    this.name = "GitHubError";
  }
  /** 是否值得稍后重试 */
  get retryable() {
    return this.kind === "rate_limited" || this.kind === "server" || this.kind === "network";
  }
}

export interface CacheEntry {
  etag?: string | null;
  lastModified?: string | null;
  body: string;
  linkHeader?: string | null;
}

export interface CacheStore {
  get(key: string): Promise<CacheEntry | null>;
  set(key: string, entry: CacheEntry): Promise<void>;
}

export class MemoryCacheStore implements CacheStore {
  map = new Map<string, CacheEntry>();
  async get(k: string) {
    return this.map.get(k) ?? null;
  }
  async set(k: string, e: CacheEntry) {
    this.map.set(k, e);
  }
}

export interface RateLimitState {
  limit: number | null;
  remaining: number | null;
  reset: number | null; // epoch 秒
  updatedAt: number | null;
}

// 进程级共享：同一进程内所有客户端实例共享速率限制状态
export const rateLimitState: RateLimitState = { limit: null, remaining: null, reset: null, updatedAt: null };

export interface GhResponse<T> {
  status: number;
  data: T;
  notModified: boolean;
  link: Record<string, string>;
}

export interface RequestOptions {
  accept?: string;
  text?: boolean; // 返回文本（raw / sha 媒体类型）
  conditional?: boolean; // 默认 true
}

export interface ClientOptions {
  token?: string;
  baseUrl?: string;
  fetchImpl?: typeof fetch;
  cache?: CacheStore;
  maxConcurrency?: number;
  minIntervalMs?: number;
  maxRetries?: number;
  maxInlineWaitMs?: number; // Retry-After 小于该值时原地等待后重试，否则抛出 rate_limited 交给任务队列延后
  backoffBaseMs?: number;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  userAgent?: string;
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function parseLinkHeader(h: string | null | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!h) return out;
  for (const part of h.split(",")) {
    const m = part.match(/<([^>]+)>\s*;\s*rel="([^"]+)"/);
    if (m) out[m[2]] = m[1];
  }
  return out;
}

export class GitHubClient {
  readonly baseUrl: string;
  private token?: string;
  private fetchImpl: typeof fetch;
  private cache: CacheStore;
  private maxConcurrency: number;
  private minIntervalMs: number;
  private maxRetries: number;
  private maxInlineWaitMs: number;
  private backoffBaseMs: number;
  private sleep: (ms: number) => Promise<void>;
  private now: () => number;
  private userAgent: string;
  private active = 0;
  private waiters: (() => void)[] = [];
  private lastRequestAt = 0;
  stats = { requests: 0, notModified: 0, retries: 0 };

  constructor(opts: ClientOptions = {}) {
    this.token = opts.token;
    this.baseUrl = (opts.baseUrl ?? "https://api.github.com").replace(/\/$/, "");
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.cache = opts.cache ?? new MemoryCacheStore();
    this.maxConcurrency = opts.maxConcurrency ?? 4;
    this.minIntervalMs = opts.minIntervalMs ?? 100;
    this.maxRetries = opts.maxRetries ?? 3;
    this.maxInlineWaitMs = opts.maxInlineWaitMs ?? 30_000;
    this.backoffBaseMs = opts.backoffBaseMs ?? 1000;
    this.sleep = opts.sleep ?? defaultSleep;
    this.now = opts.now ?? Date.now;
    this.userAgent = opts.userAgent ?? "OpenSource-Hub/1.0";
  }

  get authenticated() {
    return !!this.token;
  }

  private async acquire() {
    if (this.active >= this.maxConcurrency) await new Promise<void>((r) => this.waiters.push(r));
    this.active++;
    const wait = this.lastRequestAt + this.minIntervalMs - this.now();
    this.lastRequestAt = Math.max(this.now(), this.lastRequestAt + this.minIntervalMs);
    if (wait > 0) await this.sleep(wait);
  }
  private release() {
    this.active--;
    const next = this.waiters.shift();
    if (next) next();
  }

  private updateRate(h: Headers) {
    const rem = h.get("x-ratelimit-remaining");
    const reset = h.get("x-ratelimit-reset");
    const limit = h.get("x-ratelimit-limit");
    if (rem !== null) rateLimitState.remaining = Number(rem);
    if (reset !== null) rateLimitState.reset = Number(reset);
    if (limit !== null) rateLimitState.limit = Number(limit);
    if (rem !== null) rateLimitState.updatedAt = this.now();
  }

  private backoff(attempt: number) {
    const base = this.backoffBaseMs * 2 ** attempt;
    return base + Math.floor(Math.random() * base * 0.3);
  }

  async request<T = unknown>(pathOrUrl: string, opts: RequestOptions = {}): Promise<GhResponse<T>> {
    const url = pathOrUrl.startsWith("http") ? pathOrUrl : `${this.baseUrl}${pathOrUrl}`;
    const accept = opts.accept ?? "application/vnd.github+json";
    const conditional = opts.conditional !== false;
    const cacheKey = `${accept} ${url}`;

    // 主速率限制已耗尽：直接返回错误，等待重置时间，避免继续消耗/被封禁
    if (rateLimitState.remaining === 0 && rateLimitState.reset && rateLimitState.reset * 1000 > this.now()) {
      throw new GitHubError("GitHub API 速率限制已用尽", "rate_limited", 403, new Date(rateLimitState.reset * 1000 + 1000));
    }

    const cached = conditional ? await this.cache.get(cacheKey) : null;
    let attempt = 0;
    for (;;) {
      const headers: Record<string, string> = {
        Accept: accept,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": this.userAgent,
      };
      if (this.token) headers.Authorization = `Bearer ${this.token}`;
      if (cached?.etag) headers["If-None-Match"] = cached.etag;
      else if (cached?.lastModified) headers["If-Modified-Since"] = cached.lastModified;

      let res: Response;
      await this.acquire();
      try {
        this.stats.requests++;
        res = await this.fetchImpl(url, { headers, redirect: "follow", signal: AbortSignal.timeout(30_000) });
      } catch (e) {
        this.release();
        if (attempt < this.maxRetries) {
          this.stats.retries++;
          await this.sleep(this.backoff(attempt++));
          continue;
        }
        throw new GitHubError(`网络错误：${(e as Error).message}`, "network");
      }
      this.release();
      this.updateRate(res.headers);

      if (res.status === 304 && cached) {
        this.stats.notModified++;
        return { status: 304, notModified: true, data: (opts.text ? cached.body : JSON.parse(cached.body)) as T, link: parseLinkHeader(cached.linkHeader) };
      }

      if (res.ok) {
        const body = await res.text();
        const link = res.headers.get("link");
        const etag = res.headers.get("etag");
        const lastModified = res.headers.get("last-modified");
        if (conditional && (etag || lastModified)) await this.cache.set(cacheKey, { etag, lastModified, body, linkHeader: link });
        return { status: res.status, notModified: false, data: (opts.text ? body : body ? JSON.parse(body) : null) as T, link: parseLinkHeader(link) };
      }

      const text = await res.text().catch(() => "");
      let message = text;
      try {
        message = JSON.parse(text).message ?? text;
      } catch {
        /* not json */
      }

      // 速率限制：403 / 429
      if (res.status === 429 || res.status === 403) {
        const retryAfter = res.headers.get("retry-after");
        const remaining = res.headers.get("x-ratelimit-remaining");
        const reset = res.headers.get("x-ratelimit-reset");
        const isRate = res.status === 429 || retryAfter !== null || remaining === "0" || /rate limit/i.test(message);
        if (isRate) {
          let waitMs: number;
          if (retryAfter !== null) waitMs = Number(retryAfter) * 1000;
          else if (remaining === "0" && reset) waitMs = Math.max(0, Number(reset) * 1000 - this.now()) + 1000;
          else waitMs = 60_000 * 2 ** attempt; // 次级限制无头信息：至少等待 1 分钟并指数增加
          if (waitMs <= this.maxInlineWaitMs && attempt < this.maxRetries) {
            this.stats.retries++;
            attempt++;
            await this.sleep(waitMs);
            continue;
          }
          throw new GitHubError(`GitHub API 限流（HTTP ${res.status}）：${message}`, "rate_limited", res.status, new Date(this.now() + waitMs));
        }
        throw new GitHubError(`无权访问（HTTP 403）：${message}`, "forbidden", 403);
      }
      if (res.status === 401) throw new GitHubError("GitHub Token 无效或已过期（HTTP 401）", "unauthorized", 401);
      if (res.status === 404) throw new GitHubError("资源不存在或无权访问（HTTP 404）", "not_found", 404);
      if (res.status === 409) throw new GitHubError(`仓库为空（HTTP 409）：${message}`, "empty", 409);
      if (res.status === 451) throw new GitHubError("因法律原因不可访问（HTTP 451）", "forbidden", 451);
      if (res.status >= 500) {
        if (attempt < this.maxRetries) {
          this.stats.retries++;
          await this.sleep(this.backoff(attempt++));
          continue;
        }
        throw new GitHubError(`GitHub 服务器错误（HTTP ${res.status}）`, "server", res.status);
      }
      throw new GitHubError(`请求失败（HTTP ${res.status}）：${message}`, "other", res.status);
    }
  }

  /**
   * GraphQL v4（Discussions 只能通过 GraphQL 获取，需要 Token）。
   * 共享并发队列 / 退避；GraphQL 限流（RATE_LIMITED 或 403/429）转换为 rate_limited 交由队列延后。
   */
  async graphql<T = unknown>(query: string, variables: Record<string, unknown> = {}): Promise<T> {
    if (!this.token) throw new GitHubError("Discussions 需要 GitHub Token（GraphQL API 不支持匿名访问），请在设置中配置", "unauthorized", 401);
    let attempt = 0;
    for (;;) {
      let res: Response;
      await this.acquire();
      try {
        this.stats.requests++;
        res = await this.fetchImpl(`${this.baseUrl}/graphql`, {
          method: "POST",
          headers: { Authorization: `Bearer ${this.token}`, "Content-Type": "application/json", "User-Agent": this.userAgent },
          body: JSON.stringify({ query, variables }),
          signal: AbortSignal.timeout(30_000),
        });
      } catch (e) {
        this.release();
        if (attempt < this.maxRetries) {
          this.stats.retries++;
          await this.sleep(this.backoff(attempt++));
          continue;
        }
        throw new GitHubError(`网络错误：${(e as Error).message}`, "network");
      }
      this.release();
      const text = await res.text().catch(() => "");
      let body: { data?: T; errors?: { type?: string; message: string }[]; message?: string } = {};
      try {
        body = JSON.parse(text);
      } catch {
        /* not json */
      }
      const rateErr = body.errors?.find((e) => e.type === "RATE_LIMITED");
      if (res.status === 429 || res.status === 403 || rateErr) {
        const retryAfter = res.headers.get("retry-after");
        const reset = res.headers.get("x-ratelimit-reset");
        const waitMs = retryAfter ? Number(retryAfter) * 1000 : reset ? Math.max(0, Number(reset) * 1000 - this.now()) + 1000 : 60_000 * 2 ** attempt;
        if (waitMs <= this.maxInlineWaitMs && attempt < this.maxRetries) {
          this.stats.retries++;
          attempt++;
          await this.sleep(waitMs);
          continue;
        }
        throw new GitHubError(`GitHub GraphQL 限流：${rateErr?.message ?? body.message ?? res.status}`, "rate_limited", res.status, new Date(this.now() + waitMs));
      }
      if (res.status === 401) throw new GitHubError("GitHub Token 无效或已过期（HTTP 401）", "unauthorized", 401);
      if (res.status >= 500) {
        if (attempt < this.maxRetries) {
          this.stats.retries++;
          await this.sleep(this.backoff(attempt++));
          continue;
        }
        throw new GitHubError(`GitHub 服务器错误（HTTP ${res.status}）`, "server", res.status);
      }
      if (body.errors?.length) {
        const nf = body.errors.find((e) => e.type === "NOT_FOUND");
        throw new GitHubError(`GraphQL 错误：${body.errors.map((e) => e.message).join("；")}`, nf ? "not_found" : "other", res.status);
      }
      if (!res.ok) throw new GitHubError(`请求失败（HTTP ${res.status}）：${body.message ?? text.slice(0, 200)}`, "other", res.status);
      return body.data as T;
    }
  }

  /** 按 Link 头分页。onPage 返回 false 时停止。 */
  async paginate<T>(path: string, maxPages: number, onPage: (items: T[], res: GhResponse<T[]>, page: number) => Promise<boolean | void>) {
    let url: string | undefined = path;
    let page = 1;
    while (url && page <= maxPages) {
      const res: GhResponse<T[]> = await this.request<T[]>(url);
      const cont = await onPage(res.data ?? [], res, page);
      if (cont === false) break;
      url = res.link.next;
      page++;
    }
    return page - 1;
  }
}
