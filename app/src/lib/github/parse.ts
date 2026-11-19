export interface RepoRef {
  provider: "github";
  owner: string;
  name: string;
}

const NAME_RE = /^[A-Za-z0-9_.-]+$/;

/**
 * 解析用户输入的仓库地址。支持：
 *  - https://github.com/owner/repo(.git)(/tree/...)
 *  - github.com/owner/repo
 *  - git@github.com:owner/repo.git
 *  - owner/repo
 * GitLab / Codeberg 等平台在此处预留扩展。
 */
export function parseRepoInput(input: string): RepoRef | { error: string } {
  let s = (input ?? "").trim();
  if (!s) return { error: "输入为空" };
  s = s.replace(/^git\+/, "");
  const ssh = s.match(/^git@github\.com:([^/]+)\/([^/]+?)(?:\.git)?\/?$/i);
  if (ssh) return finalize(ssh[1], ssh[2]);

  if (/^(https?:\/\/)?(www\.)?[a-z0-9.-]+\.[a-z]{2,}\//i.test(s)) {
    let url: URL;
    try {
      url = new URL(/^https?:\/\//i.test(s) ? s : `https://${s}`);
    } catch {
      return { error: "无法识别的 URL" };
    }
    const host = url.hostname.toLowerCase().replace(/^www\./, "");
    if (host !== "github.com") {
      if (["gitlab.com", "codeberg.org", "gitee.com"].includes(host)) return { error: `暂不支持 ${host}（已预留扩展接口）` };
      return { error: "目前只支持 GitHub 仓库地址" };
    }
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.length < 2) return { error: "URL 中缺少 owner/repository" };
    return finalize(parts[0], parts[1]);
  }

  const parts = s.split("/").filter(Boolean);
  if (parts.length === 2) return finalize(parts[0], parts[1]);
  return { error: "请输入 GitHub 仓库 URL 或 owner/repository" };
}

function finalize(owner: string, name: string): RepoRef | { error: string } {
  name = name.replace(/\.git$/i, "");
  if (!NAME_RE.test(owner) || !NAME_RE.test(name) || name === "." || name === "..") return { error: "owner 或仓库名包含非法字符" };
  return { provider: "github", owner, name };
}

export function repoKey(owner: string, name: string) {
  return `${owner}/${name}`.toLowerCase();
}

/** 将批量导入文本拆分为条目（换行、逗号、空格分隔）。 */
export function splitBatchInput(text: string): string[] {
  return Array.from(new Set((text ?? "").split(/[\s,，;；]+/).map((x) => x.trim()).filter(Boolean)));
}
