// 仅声明本项目用到的 GitHub REST API 字段（参见 docs.github.com/en/rest）
export interface GhRepo {
  id: number;
  name: string;
  full_name: string;
  owner: { login: string; avatar_url: string };
  description: string | null;
  homepage: string | null;
  html_url: string;
  stargazers_count: number;
  forks_count: number;
  subscribers_count?: number;
  watchers_count: number;
  license: { spdx_id: string | null; name: string } | null;
  language: string | null;
  topics?: string[];
  default_branch: string;
  archived: boolean;
  disabled?: boolean;
  fork: boolean;
  created_at: string;
  updated_at: string;
  pushed_at: string | null;
  private: boolean;
}

export interface GhAsset {
  id: number;
  name: string;
  label: string | null;
  content_type: string;
  size: number;
  download_count: number;
  browser_download_url: string;
  digest?: string | null;
  created_at: string;
  updated_at: string;
}

export interface GhRelease {
  id: number;
  tag_name: string;
  name: string | null;
  body: string | null;
  draft: boolean;
  prerelease: boolean;
  created_at: string;
  published_at: string | null;
  html_url: string;
  zipball_url: string | null;
  tarball_url: string | null;
  target_commitish: string;
  author: { login: string } | null;
  assets: GhAsset[];
}

export interface GhTag {
  name: string;
  commit: { sha: string; url: string };
  zipball_url: string;
  tarball_url: string;
}

export interface GhCommit {
  sha: string;
  html_url: string;
  commit: { message: string; author: { name: string; date: string } | null; committer: { name: string; date: string } | null };
  author: { login: string; avatar_url: string } | null;
}

export interface GhGitCommit {
  sha: string;
  committer: { date: string };
  author: { date: string };
}

export interface GhContentEntry {
  name: string;
  path: string;
  sha: string;
  size: number;
  type: "file" | "dir" | "symlink" | "submodule";
  download_url: string | null;
  html_url: string;
}
