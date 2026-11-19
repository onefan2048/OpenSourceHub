import { bad, json, withDb } from "@/lib/api";
import { DEFAULT_SETTINGS, POLL_INTERVALS, SECRET_KEYS, getAllSettings, setSetting, type SettingKey } from "@/lib/settings";

export const dynamic = "force-dynamic";

export async function GET() {
  return withDb(async () => {
    const s = await getAllSettings();
    const masked: Record<string, string> = { ...s };
    for (const k of SECRET_KEYS) masked[k] = s[k] ? "••••••" + s[k].slice(-4) : "";
    return json({ settings: masked, envToken: !!process.env.GITHUB_TOKEN });
  });
}

export async function PUT(req: Request) {
  return withDb(async () => {
    const b = (await req.json().catch(() => ({}))) as Record<string, string>;
    for (const [k, v] of Object.entries(b)) {
      if (!(k in DEFAULT_SETTINGS)) continue;
      const val = String(v ?? "").trim();
      if (SECRET_KEYS.includes(k as SettingKey) && val.startsWith("••••••")) continue; // 未修改的掩码值
      if (k === "poll.defaultIntervalMinutes" && !(POLL_INTERVALS as readonly number[]).includes(Number(val))) return bad("不支持的轮询间隔");
      if (["sync.initialCommitCount", "sync.maxReleasePages", "sync.maxTagPages", "sync.tagDateBackfillPerSync", "worker.concurrency", "sync.staleDays", "community.intervalMinutes", "community.pagesPerRun"].includes(k) && !(Number(val) >= 0)) return bad(`${k} 必须为非负数字`);
      await setSetting(k, val);
    }
    return json({ ok: true });
  });
}
