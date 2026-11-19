export function relTime(input: Date | string | null | undefined): string {
  if (!input) return "—";
  const t = new Date(input).getTime();
  if (!t) return "—";
  const diff = Date.now() - t;
  const abs = Math.abs(diff);
  const suffix = diff >= 0 ? "前" : "后";
  if (abs < 60_000) return diff >= 0 ? "刚刚" : "即将";
  if (abs < 3600_000) return `${Math.round(abs / 60_000)} 分钟${suffix}`;
  if (abs < 86400_000) return `${Math.round(abs / 3600_000)} 小时${suffix}`;
  if (abs < 30 * 86400_000) return `${Math.round(abs / 86400_000)} 天${suffix}`;
  if (abs < 365 * 86400_000) return `${Math.round(abs / (30 * 86400_000))} 个月${suffix}`;
  return `${(abs / (365 * 86400_000)).toFixed(1)} 年${suffix}`;
}

export function fmtDate(input: Date | string | null | undefined, withTime = false): string {
  if (!input) return "—";
  const d = new Date(input);
  if (!d.getTime()) return "—";
  return d.toLocaleString("zh-CN", { timeZone: process.env.TZ || "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit", ...(withTime ? { hour: "2-digit", minute: "2-digit" } : {}) });
}

export function fmtNum(n: number | null | undefined) {
  if (n == null) return "—";
  if (n >= 10000) return `${(n / 1000).toFixed(1)}k`;
  return n.toLocaleString("zh-CN");
}

export function jsonArr(s: string | null | undefined): string[] {
  try {
    const v = JSON.parse(s ?? "[]");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

export const INTERVAL_LABELS: Record<number, string> = { 5: "5 分钟", 15: "15 分钟", 30: "30 分钟", 60: "1 小时", 360: "6 小时", 720: "12 小时", 1440: "24 小时" };
