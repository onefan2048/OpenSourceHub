/**
 * 独立后台调度服务（Scheduler + Worker）
 * 运行：npm run worker
 */
import os from "node:os";
import { ensureSqlitePragmas, prisma } from "../lib/db";
import { createGitHubClient } from "../lib/github/factory";
import { rateLimitState } from "../lib/github/client";
import { getNumberSetting, setSetting } from "../lib/settings";
import { claimNextTask, recoverTasks, scheduleDueRepositories } from "../lib/sync/queue";
import { runTask } from "../lib/sync/runner";
import { claimCommunity, ensureCommunityRows, recoverCommunity, runCommunitySync } from "../lib/community/sync";

const workerId = `${os.hostname()}-${process.pid}`;
const TICK_MS = Number(process.env.WORKER_TICK_MS ?? 3000);
let stopping = false;
const active = new Set<Promise<unknown>>();

const log = (...a: unknown[]) => console.log(new Date().toISOString(), "[worker]", ...a);

async function heartbeat() {
  await setSetting(
    "worker.heartbeat",
    JSON.stringify({ workerId, at: new Date().toISOString(), active: active.size, rate: rateLimitState }),
  );
}

// Issues / Discussions 独立通道：串行执行（同一时刻最多 1 个），不占用版本监控的并发
let communityBusy = false;
let lastEnsure = 0;
async function communityTick() {
  if (Date.now() - lastEnsure > 60_000) {
    lastEnsure = Date.now();
    await ensureCommunityRows();
  }
  if (communityBusy || stopping) return;
  const s = await claimCommunity();
  if (!s) return;
  communityBusy = true;
  const gh = await createGitHubClient();
  const repo = await prisma.repository.findUnique({ where: { id: s.repositoryId }, select: { fullName: true } });
  // 不计入版本监控的并发槽位；进度按页持久化，进程退出后由 recoverCommunity 恢复
  void runCommunitySync(s.id, gh)
    .then((r) => log(`社区同步 ${repo?.fullName} ${s.kind}: ${r.summary}`))
    .catch((e) => log("社区同步异常", e))
    .finally(() => {
      communityBusy = false;
    });
}

async function tick() {
  await scheduleDueRepositories();
  await recoverTasks({ staleMs: 15 * 60_000 });
  const concurrency = Math.max(1, Math.min(8, await getNumberSetting("worker.concurrency")));
  while (!stopping && active.size < concurrency) {
    const task = await claimNextTask(workerId);
    if (!task) break;
    const gh = await createGitHubClient(); // 每个任务读取最新 Token 设置
    const repo = await prisma.repository.findUnique({ where: { id: task.repositoryId }, select: { fullName: true } });
    log(`开始同步 #${task.id} ${repo?.fullName} (${task.trigger}/${task.mode}, 第 ${task.attempts} 次)`);
    const p = runTask(task, gh)
      .then((r) => log(`完成 #${task.id} ${repo?.fullName}: ${r?.summary ?? "失败，已安排重试"} [请求 ${r?.requestCount ?? "?"}，304 ${r?.notModifiedCount ?? "?"}]`))
      .catch((e) => log("任务异常", e))
      .finally(() => active.delete(p));
    active.add(p);
  }
  await communityTick().catch((e) => log("社区同步调度错误", (e as Error).message));
  await heartbeat();
}

async function main() {
  await ensureSqlitePragmas();
  const recovered = await recoverTasks({ all: true });
  await recoverCommunity();
  log(`启动 ${workerId}，恢复未完成任务 ${recovered} 个`);
  const loop = async () => {
    if (stopping) return;
    try {
      await tick();
    } catch (e) {
      log("调度循环错误（将继续运行）", (e as Error).message); // 网络 / 数据库故障不终止服务
    }
    setTimeout(loop, TICK_MS);
  };
  loop();
}

async function shutdown(sig: string) {
  if (stopping) return;
  stopping = true;
  log(`收到 ${sig}，等待 ${active.size} 个任务完成…`);
  await Promise.race([Promise.allSettled([...active]), new Promise((r) => setTimeout(r, 20_000))]);
  await prisma.$disconnect();
  process.exit(0);
}
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

main();
