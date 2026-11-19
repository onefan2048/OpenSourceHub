import { prisma } from "../db";
import type { CacheEntry, CacheStore } from "./client";

/** 将 ETag / Last-Modified 与响应体持久化到 SQLite，重启后仍可使用条件请求。 */
export class PrismaCacheStore implements CacheStore {
  async get(key: string): Promise<CacheEntry | null> {
    const row = await prisma.httpCache.findUnique({ where: { key } });
    return row ? { etag: row.etag, lastModified: row.lastModified, body: row.body, linkHeader: row.linkHeader } : null;
  }
  async set(key: string, e: CacheEntry) {
    const data = { etag: e.etag ?? null, lastModified: e.lastModified ?? null, body: e.body, linkHeader: e.linkHeader ?? null };
    await prisma.httpCache.upsert({ where: { key }, create: { key, ...data }, update: data });
  }
}
