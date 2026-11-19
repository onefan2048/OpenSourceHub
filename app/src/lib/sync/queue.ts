/**
 * SQLite 持久化任务队列：
 * - 每个仓库最多一个待执行任务（去重）
 * - 任务认领使用条件更新（status=pending → running），避免重复执行
 * - 失败指数退避重试；限流错误按 GitHub 返回的重置时间延后
 * - 服务重启后，处于 running 的任务自动恢复为 pending
 */
import { prisma } from "../db";
import { GitHubError } from "../github/client";
import { getNumberSetting } from "../settings";
import type { SyncMode } from "./engine";

export async function enqueueSync(repositoryId: number, opts: { trigger: string; mode?: SyncMode; priority?: number; runAt?: Date } = { trigger: "manual" }) {
  const priority = opts.priority ?? (opts.trigger === "manual" ? 10 : opts.trigger === "import" ? 5 : 0);
  const runAt = opts.runAt ?? new Date();
  const pending = await prisma.syncTask.findFirst({ where: { repositoryId, status: "pending" } });
  if (pending) {
    return prisma.syncTask.update({
      where: { id: pending.id },
      data: {
        priority: Math.max(pending.priority, priority),
        runAt: runAt < pending.runAt ? runAt : pending.runAt,
        mode: opts.mode === "full" ? "full" : pending.mode,
        ...(opts.trigger === "manual" ? { trigger: "manual", attempts: 0 } : {}),
      },
    });
  }
  return prisma.syncTask.create({ data: { repositoryId, trigger: opts.trigger, mode: opts.mode ?? "incremental", priority, runAt } });
}

export async function claimNextTask(workerId: string) {
  const now = new Date();
  const running = await prisma.syncTask.findMany({ where: { status: "running" }, select: { repositoryId: true } });
  const busy = running.map((r) => r.repositoryId);
  const candidates = await prisma.syncTask.findMany({
    where: { status: "pending", runAt: { lte: now }, repositoryId: { notIn: busy } },
    orderBy: [{ priority: "desc" }, { runAt: "asc" }],
    take: 5,
  });
  for (const c of candidates) {
    const r = await prisma.syncTask.updateMany({ where: { id: c.id, status: "pending" }, data: { status: "running", lockedAt: now, lockedBy: workerId, startedAt: now, attempts: { increment: 1 } } });
    if (r.count === 1) return prisma.syncTask.findUniqueOrThrow({ where: { id: c.id } });
  }
  return null;
}

export function retryDelayMs(attempts: number) {
  // 1, 2, 4, 8, 16 分钟…… 上限 1 小时
  return Math.min(60, 2 ** Math.max(0, attempts - 1)) * 60_000;
}

export async function completeTask(taskId: number) {
  await prisma.syncTask.update({ where: { id: taskId }, data: { status: "succeeded", finishedAt: new Date(), lockedAt: null, lockedBy: null, lastError: null } });
}

export async function failTask(taskId: number, err: unknown) {
  const t = await prisma.syncTask.findUniqueOrThrow({ where: { id: taskId } });
  const ge = err instanceof GitHubError ? err : null;
  const message = (err as Error)?.message ?? String(err);
  const permanent = ge && !ge.retryable;
  if (!permanent && t.attempts < t.maxAttempts) {
    const runAt = ge?.kind === "rate_limited" && ge.retryAt ? ge.retryAt : new Date(Date.now() + retryDelayMs(t.attempts));
    // 限流不计入失败次数
    await prisma.syncTask.update({
      where: { id: taskId },
      data: { status: "pending", runAt, lockedAt: null, lockedBy: null, lastError: message, trigger: t.trigger === "manual" ? "manual" : "retry", ...(ge?.kind === "rate_limited" ? { attempts: { decrement: 1 } } : {}) },
    });
    return { retried: true, runAt };
  }
  await prisma.syncTask.update({ where: { id: taskId }, data: { status: "failed", finishedAt: new Date(), lockedAt: null, lockedBy: null, lastError: message } });
  return { retried: false };
}

/** 启动时恢复：上次进程退出时仍为 running 的任务重新排队。也用于回收超时锁。 */
export async function recoverTasks(opts: { all?: boolean; staleMs?: number } = {}) {
  const where = opts.all ? { status: "running" } : { status: "running", lockedAt: { lt: new Date(Date.now() - (opts.staleMs ?? 15 * 60_000)) } };
  const r = await prisma.syncTask.updateMany({ where, data: { status: "pending", lockedAt: null, lockedBy: null, runAt: new Date() } });
  return r.count;
}

export async function intervalFor(repo: { pollIntervalMinutes: number | null }) {
  return repo.pollIntervalMinutes ?? (await getNumberSetting("poll.defaultIntervalMinutes"));
}

/** 调度：为到期且未暂停的仓库创建定时任务（错峰，每轮限量） */
export async function scheduleDueRepositories(limit = 25) {
  const now = new Date();
  const due = await prisma.repository.findMany({
    where: { paused: false, OR: [{ nextSyncAt: null }, { nextSyncAt: { lte: now } }], syncTasks: { none: { status: { in: ["pending", "running"] } } } },
    orderBy: { nextSyncAt: "asc" },
    take: limit,
    select: { id: true },
  });
  for (const r of due) await enqueueSync(r.id, { trigger: "schedule" });
  return due.length;
}

/** 同步结束后安排下一次时间；连续失败或不可访问时降低频率 */
export async function scheduleNext(repoId: number) {
  const repo = await prisma.repository.findUniqueOrThrow({ where: { id: repoId } });
  let minutes = await intervalFor(repo);
  if (!repo.accessible) minutes = Math.max(minutes, 360);
  else if (repo.consecutiveFailures > 0) minutes = Math.min(minutes * 2 ** Math.min(repo.consecutiveFailures, 4), 1440);
  const jitter = Math.floor(Math.random() * Math.min(60_000, minutes * 6000)); // 最多 10% / 60 秒抖动，避免同时请求
  await prisma.repository.update({ where: { id: repoId }, data: { nextSyncAt: new Date(Date.now() + minutes * 60_000 + jitter) } });
}
