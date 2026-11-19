import { prisma } from "./db";

export const POLL_INTERVALS = [5, 15, 30, 60, 360, 720, 1440] as const;

export const DEFAULT_SETTINGS = {
  "poll.defaultIntervalMinutes": "5",
  "sync.initialCommitCount": "30",
  "sync.maxReleasePages": "20",
  "sync.maxTagPages": "10",
  "sync.tagDateBackfillPerSync": "5",
  "sync.staleDays": "365",
  "worker.concurrency": "2",
  "community.intervalMinutes": "30",
  "community.pagesPerRun": "5",
  "github.token": "",
  "notify.web.enabled": "true",
  "notify.telegram.botToken": "",
  "notify.telegram.chatId": "",
  "notify.discord.webhookUrl": "",
  "notify.wecom.webhookUrl": "",
  "notify.feishu.webhookUrl": "",
  "notify.feishu.secret": "",
  "notify.qq.appId": "",
  "notify.qq.clientSecret": "",
  "notify.qq.groupOpenId": "",
  "notify.webhook.url": "",
  "notify.email.to": "",
  "notify.email.provider": "qq",
  "notify.email.host": "smtp.qq.com",
  "notify.email.port": "465",
  "notify.email.security": "tls",
  "notify.email.username": "",
  "notify.email.password": "",
  "notify.email.outlook.clientId": "",
  "notify.email.outlook.refreshToken": "",
} as const;

export type SettingKey = keyof typeof DEFAULT_SETTINGS;
export const SECRET_KEYS: SettingKey[] = ["github.token", "notify.telegram.botToken", "notify.discord.webhookUrl", "notify.wecom.webhookUrl", "notify.feishu.webhookUrl", "notify.feishu.secret", "notify.qq.clientSecret", "notify.email.password", "notify.email.outlook.refreshToken", "notify.webhook.url"];

export async function getAllSettings(): Promise<Record<SettingKey, string>> {
  const rows = await prisma.setting.findMany();
  const out = { ...DEFAULT_SETTINGS } as Record<SettingKey, string>;
  for (const r of rows) if (r.key in out) out[r.key as SettingKey] = r.value;
  return out;
}

export async function getSetting(key: SettingKey): Promise<string> {
  const row = await prisma.setting.findUnique({ where: { key } });
  return row?.value ?? DEFAULT_SETTINGS[key];
}

export async function getNumberSetting(key: SettingKey): Promise<number> {
  const n = Number(await getSetting(key));
  return Number.isFinite(n) ? n : Number(DEFAULT_SETTINGS[key]);
}

export async function setSetting(key: string, value: string) {
  await prisma.setting.upsert({ where: { key }, create: { key, value }, update: { value } });
}

/** 环境变量 GITHUB_TOKEN 优先，其次是设置页填写的 Token；均为空时匿名访问公开仓库。 */
export async function getGitHubToken(): Promise<string | undefined> {
  const env = process.env.GITHUB_TOKEN?.trim();
  if (env) return env;
  const s = (await getSetting("github.token")).trim();
  return s || undefined;
}
