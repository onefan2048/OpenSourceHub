/**
 * 版本号比较：不使用字符串排序。
 * 支持 v 前缀、包名前缀（pkg@1.2.3、app-v1.2）、任意段数、预发布标识（alpha < beta < rc < 正式）。
 */
export interface ParsedVersion {
  nums: number[];
  pre: (string | number)[] | null;
  raw: string;
}

export function parseVersion(input: string): ParsedVersion | null {
  const raw = input ?? "";
  // 取第一个数字开始的版本片段
  const m = raw.match(/(\d+(?:\.\d+)*)(?:[-_.+]?((?:alpha|beta|rc|pre|preview|dev|canary|nightly|a|b)[.\-_]?\d*(?:[.\-][0-9A-Za-z]+)*))?/i);
  if (!m) return null;
  const nums = m[1].split(".").map((x) => Number(x));
  let pre: (string | number)[] | null = null;
  if (m[2]) {
    pre = m[2]
      .toLowerCase()
      .split(/[.\-_]|(?<=[a-z])(?=\d)/)
      .filter(Boolean)
      .map((p) => (/^\d+$/.test(p) ? Number(p) : p));
  }
  return { nums, pre, raw };
}

const PRE_ORDER: Record<string, number> = { dev: 0, nightly: 0, canary: 0, a: 1, alpha: 1, b: 2, beta: 2, pre: 3, preview: 3, rc: 4 };

/** 返回 a > b 为正数，a < b 为负数，相等为 0。无法解析的版本排在最后（较小）。 */
export function compareVersions(a: string, b: string): number {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (!pa && !pb) return a.localeCompare(b);
  if (!pa) return -1;
  if (!pb) return 1;
  const len = Math.max(pa.nums.length, pb.nums.length);
  for (let i = 0; i < len; i++) {
    const d = (pa.nums[i] ?? 0) - (pb.nums[i] ?? 0);
    if (d !== 0) return d;
  }
  if (!pa.pre && pb.pre) return 1;
  if (pa.pre && !pb.pre) return -1;
  if (pa.pre && pb.pre) {
    const l = Math.max(pa.pre.length, pb.pre.length);
    for (let i = 0; i < l; i++) {
      const x = pa.pre[i];
      const y = pb.pre[i];
      if (x === undefined) return -1;
      if (y === undefined) return 1;
      if (typeof x === "number" && typeof y === "number") {
        if (x !== y) return x - y;
      } else {
        const ox = typeof x === "string" ? PRE_ORDER[x] ?? 5 : -1;
        const oy = typeof y === "string" ? PRE_ORDER[y] ?? 5 : -1;
        if (ox !== oy) return ox - oy;
        if (String(x) !== String(y)) return String(x).localeCompare(String(y));
      }
    }
  }
  return 0;
}

export function sortVersionsDesc<T>(items: T[], get: (t: T) => string): T[] {
  return [...items].sort((x, y) => compareVersions(get(y), get(x)));
}

export function isPrereleaseVersion(v: string) {
  return !!parseVersion(v)?.pre;
}

/** 不同命名体系之间无法可靠比较版本号；日期未补全时不猜测“最新 Tag”。 */
export function selectLatestTag<T extends { name: string; commitDate: Date | null }>(tags: T[]): T | null {
  if (!tags.length) return null;
  const withDates = tags.every(t => t.commitDate && t.commitDate.getTime() > 0);
  if (withDates) return [...tags].sort((a, b) => b.commitDate!.getTime() - a.commitDate!.getTime())[0];
  const family = (name: string) => {
    const m = name.match(/^(.*?)(?=\d)/);
    if (!m || !parseVersion(name) || /\d{4}[-/.]\d{1,2}[-/.]\d{1,2}/.test(name)) return null;
    const prefix = m[1].toLowerCase();
    return prefix === 'v' ? '' : prefix;
  };
  const groups = tags.map(t => family(t.name));
  if (groups.some(g => g === null) || new Set(groups).size !== 1) return null;
  return [...tags].sort((a, b) => compareVersions(b.name, a.name))[0];
}
