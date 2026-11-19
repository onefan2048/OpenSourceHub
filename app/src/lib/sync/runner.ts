import { prisma } from "../db";
import type { GitHubClient } from "../github/client";
import { syncRepository } from "./engine";
import { completeTask, failTask, scheduleNext } from "./queue";

/** 执行一个已认领的任务。任何异常都被捕获，不会中断队列。 */
export async function runTask(task: { id: number; repositoryId: number; mode: string; trigger: string }, gh: GitHubClient) {
  try {
    const exists = await prisma.repository.findUnique({ where: { id: task.repositoryId }, select: { id: true } });
    if (!exists) return completeTask(task.id);
    const res = await syncRepository(task.repositoryId, gh, { mode: task.mode === "full" ? "full" : "incremental", trigger: task.trigger, taskId: task.id });
    if (res.status === "failed" && res.fatal) await failTask(task.id, res.fatal);
    else await completeTask(task.id);
    await scheduleNext(task.repositoryId);
    return res;
  } catch (e) {
    await failTask(task.id, e).catch(() => undefined);
    await scheduleNext(task.repositoryId).catch(() => undefined);
  }
}
