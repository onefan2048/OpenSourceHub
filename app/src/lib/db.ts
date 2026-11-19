import { PrismaClient } from "@prisma/client";

const g = globalThis as unknown as { __prisma?: PrismaClient };

export const prisma: PrismaClient = g.__prisma ?? new PrismaClient();
if (process.env.NODE_ENV !== "production") g.__prisma = prisma;

let pragmasApplied = false;
/** SQLite：开启 WAL 和 busy_timeout，允许 Web 与 Worker 两个进程并发访问同一数据库。 */
export async function ensureSqlitePragmas() {
  if (pragmasApplied) return;
  pragmasApplied = true;
  if (!(process.env.DATABASE_URL ?? "").startsWith("file:")) return;
  try {
    await prisma.$queryRawUnsafe("PRAGMA journal_mode = WAL;");
    await prisma.$queryRawUnsafe("PRAGMA busy_timeout = 10000;");
  } catch {
    /* ignore */
  }
}
