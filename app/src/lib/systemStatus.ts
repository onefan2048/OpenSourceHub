import { prisma } from "./db";
import { getGitHubToken } from "./settings";

export async function getSystemStatus() {
  const [hb, pending, running, failed, token] = await Promise.all([
    prisma.setting.findUnique({ where: { key: "worker.heartbeat" } }),
    prisma.syncTask.count({ where: { status: "pending" } }),
    prisma.syncTask.count({ where: { status: "running" } }),
    prisma.syncTask.count({ where: { status: "failed", finishedAt: { gt: new Date(Date.now() - 86400_000) } } }),
    getGitHubToken(),
  ]);
  let worker: { workerId: string; at: string; active: number; rate: { limit: number | null; remaining: number | null; reset: number | null } } | null = null;
  try {
    worker = hb ? JSON.parse(hb.value) : null;
  } catch {
    /* ignore */
  }
  const online = !!worker && Date.now() - new Date(worker.at).getTime() < 60_000;
  return { online, worker, queue: { pending, running, failed24h: failed }, authenticated: !!token };
}
