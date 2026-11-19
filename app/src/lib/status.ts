export type RepoStatus =
  | "pending"
  | "release_with_assets"
  | "release_no_assets"
  | "tags_only"
  | "commits_only"
  | "source_only"
  | "stale"
  | "archived"
  | "inaccessible"
  | "empty";

export const STATUS_META: Record<RepoStatus, { label: string; tone: "green" | "blue" | "amber" | "gray" | "red" | "purple" }> = {
  pending: { label: "等待首次同步", tone: "gray" },
  release_with_assets: { label: "有正式 Release 和安装包", tone: "green" },
  release_no_assets: { label: "有 Release，无独立安装包", tone: "blue" },
  tags_only: { label: "只有 Git Tags", tone: "purple" },
  commits_only: { label: "只有 Commit 更新", tone: "amber" },
  source_only: { label: "只有源码文件变化", tone: "amber" },
  stale: { label: "长期没有更新", tone: "gray" },
  archived: { label: "仓库已归档", tone: "gray" },
  inaccessible: { label: "仓库不可访问", tone: "red" },
  empty: { label: "空仓库", tone: "gray" },
};

export interface StatusInput {
  accessible: boolean;
  isArchived: boolean;
  synced: boolean;
  releaseCount: number;
  softwareAssetCount: number;
  tagCount: number;
  commitCount: number;
  trackedFileCount: number;
  lastActivityAt: Date | null;
  staleDays: number;
  now?: Date;
}

/** 根据真实同步数据推导仓库状态。没有安装包 / Release 从不视为失败。 */
export function computeStatus(i: StatusInput): RepoStatus {
  if (!i.accessible) return "inaccessible";
  if (!i.synced) return "pending";
  if (i.isArchived) return "archived";
  const now = i.now ?? new Date();
  if (i.lastActivityAt && now.getTime() - i.lastActivityAt.getTime() > i.staleDays * 86400_000) return "stale";
  if (i.releaseCount > 0) return i.softwareAssetCount > 0 ? "release_with_assets" : "release_no_assets";
  if (i.tagCount > 0) return "tags_only";
  if (i.commitCount > 0) return "commits_only";
  if (i.trackedFileCount > 0) return "source_only";
  return "empty";
}
