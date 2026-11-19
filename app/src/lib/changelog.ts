/** Changelog 与版本文件解析 */

export const CHANGELOG_RE = /^(changelog|changes|history|releases|news)(\.(md|markdown|rst|txt))?$/i;
export const VERSION_FILES = ["package.json", "Cargo.toml", "pubspec.yaml", "pyproject.toml", "composer.json", "setup.cfg", "VERSION", "version.txt"];
export const README_RE = /^readme(\.(md|markdown|rst|txt))?$/i;
export const LOGO_RE = /^(logo|icon|app[-_]?icon)\.(png|jpe?g|svg|webp)$/i;

export interface ChangelogParsed {
  version: string;
  title: string;
  date: string | null;
  body: string;
}

// 匹配：## [1.2.3] - 2024-01-01 / ## v1.2.3 (2024-01-01) / # 1.2.3 / ### Version 1.2.3 / 1.2.3 (rst 风格下一行 ====)
const HEADING_RE = /^(#{1,4})\s+(.*)$/;
const VERSION_IN_HEADING = /\[?\b(?:v(?:ersion)?\s*)?(\d+\.\d+(?:\.\d+)*(?:[-+.]?[0-9A-Za-z.-]*)?)\]?/i;
const DATE_RE = /(\d{4}-\d{2}-\d{2}|\d{4}\/\d{2}\/\d{2})/;

export function parseChangelog(text: string, limit = 100): ChangelogParsed[] {
  const lines = (text ?? "").replace(/\r\n/g, "\n").split("\n");
  const heads: { idx: number; title: string; version: string; date: string | null }[] = [];
  for (let i = 0; i < lines.length; i++) {
    let title: string | null = null;
    const h = lines[i].match(HEADING_RE);
    if (h) title = h[2].trim();
    else if (i + 1 < lines.length && /^[=\-~]{3,}\s*$/.test(lines[i + 1]) && lines[i].trim()) title = lines[i].trim();
    if (!title) continue;
    if (/unreleased/i.test(title)) continue;
    const vm = title.match(VERSION_IN_HEADING);
    if (!vm) continue;
    const version = vm[1].replace(/[.\-]+$/, "");
    if (heads.some((x) => x.version === version)) continue;
    const dm = title.match(DATE_RE);
    heads.push({ idx: i, title: title.replace(/[#\[\]]/g, "").trim(), version, date: dm ? dm[1] : null });
    if (heads.length >= limit) break;
  }
  return heads.map((h, k) => {
    const end = k + 1 < heads.length ? heads[k + 1].idx : Math.min(lines.length, h.idx + 400);
    const body = lines
      .slice(h.idx + 1, end)
      .filter((l) => !/^[=\-~]{3,}\s*$/.test(l))
      .join("\n")
      .trim()
      .slice(0, 20000);
    return { version: h.version, title: h.title, date: h.date, body };
  });
}

/** 从常见版本文件中提取版本号 */
export function parseVersionFile(path: string, text: string): string | null {
  const name = path.split("/").pop()!.toLowerCase();
  const t = text ?? "";
  try {
    if (name === "package.json" || name === "composer.json") {
      const j = JSON.parse(t);
      return typeof j.version === "string" ? j.version : null;
    }
  } catch {
    return null;
  }
  if (name === "cargo.toml" || name === "pyproject.toml") {
    // 优先 [package] / [project] / [tool.poetry] 段落下的 version
    const sec = t.match(/^\[(package|project|tool\.poetry|workspace\.package)\]\s*$([\s\S]*?)(?=^\[|$(?![\s\S]))/m);
    const scope = sec ? sec[2] : t;
    const m = scope.match(/^\s*version\s*=\s*["']([^"']+)["']/m);
    return m ? m[1] : null;
  }
  if (name === "pubspec.yaml") {
    const m = t.match(/^version:\s*["']?([^\s"'#]+)/m);
    return m ? m[1] : null;
  }
  if (name === "setup.cfg") {
    const m = t.match(/^version\s*=\s*([^\s#]+)/m);
    return m ? m[1] : null;
  }
  if (name === "version" || name === "version.txt") {
    const v = t.trim().split("\n")[0].trim();
    return /^v?\d+(\.\d+)*/.test(v) ? v.slice(0, 64) : null;
  }
  return null;
}
