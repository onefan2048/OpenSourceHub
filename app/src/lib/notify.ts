import { createHmac } from "node:crypto";
import { prisma } from "./db";
import { getAllSettings } from "./settings";
import { sendEmailNotification, emailConfigured } from "./email";

/**
 * 通知分发。Web 站内通知始终写入数据库；Telegram / Discord / Webhook 在设置中配置后启用；
 * 邮件通过配置的 SMTP 服务发送。
 */
export interface NotifyItem {
  repositoryId: number;
  versionEventId: number;
  title: string;
  body?: string;
  url?: string | null;
}

type Channel = "web" | "telegram" | "discord" | "wecom" | "feishu" | "qq" | "webhook" | "email";

interface Sender {
  channel: Channel;
  enabled: (s: Record<string, string>) => boolean;
  send: (s: Record<string, string>, n: NotifyItem, repoName: string) => Promise<void>;
}

const post = async (url: string, payload: unknown) => {
  const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload), signal: AbortSignal.timeout(15000) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
};

// 企业微信有时会在 HTTP 200 的响应中返回业务错误，必须检查 errcode。
const postWeCom = async (url: string, text: string) => {
  let res: Response;
  try {
    res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ msgtype: "text", text: { content: text } }), signal: AbortSignal.timeout(15000) });
  } catch {
    // 不保存异常详情，避免密钥 URL 意外进入日志或数据库。
    throw new Error("企业微信请求失败，请检查 Worker 网络和连接超时");
  }
  if (!res.ok) throw new Error(`企业微信 HTTP ${res.status}`);
  let data: { errcode?: unknown };
  try {
    data = await res.json() as { errcode?: unknown };
  } catch {
    throw new Error("企业微信返回了无效响应");
  }
  if (!data || typeof data.errcode !== "number") throw new Error("企业微信响应缺少错误码");
  if (data.errcode !== 0) throw new Error(`企业微信错误码 ${data.errcode}`);
};

// 飞书群自定义机器人：可选签名校验，HTTP 200 时仍需检查业务 code。
const postFeishu = async (url: string, secret: string, text: string) => {
  const payload: { msg_type: string; content: { text: string }; timestamp?: string; sign?: string } = {
    msg_type: "text", content: { text },
  };
  if (secret) {
    const timestamp = String(Math.floor(Date.now() / 1000));
    payload.timestamp = timestamp;
    payload.sign = createHmac("sha256", `${timestamp}\n${secret}`).update("").digest("base64");
  }
  let res: Response;
  try {
    res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload), signal: AbortSignal.timeout(15000) });
  } catch {
    throw new Error("飞书请求失败，请检查 Worker 网络和连接超时");
  }
  if (!res.ok) throw new Error(`飞书 HTTP ${res.status}`);
  let data: { code?: unknown };
  try { data = await res.json() as { code?: unknown }; }
  catch { throw new Error("飞书返回了无效响应"); }
  if (!data || typeof data.code !== "number") throw new Error("飞书响应缺少错误码");
  if (data.code !== 0) throw new Error(`飞书错误码 ${data.code}`);
};

// QQ 官方群机器人：按 AppID/密钥缓存访问令牌，临近过期时刷新。
let qqTokenCache: { appId: string; secret: string; token: string; expiresAt: number } | undefined;
const qqFetch = async (url: string, init: RequestInit): Promise<Response> => {
  try { return await fetch(url, { ...init, signal: AbortSignal.timeout(15000) }); }
  catch { throw new Error("QQ 请求失败，请检查 Worker 网络和连接超时"); }
};
const qqJson = async (res: Response): Promise<Record<string, unknown>> => {
  let data: unknown;
  try { data = await res.json(); } catch { throw new Error(`QQ 返回无效响应（HTTP ${res.status}）`); }
  if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("QQ 返回无效响应");
  return data as Record<string, unknown>;
};
const getQQToken = async (appId: string, secret: string): Promise<string> => {
  if (qqTokenCache && qqTokenCache.appId === appId && qqTokenCache.secret === secret && qqTokenCache.expiresAt > Date.now()) return qqTokenCache.token;
  const res = await qqFetch("https://api.bot.qq.com/app/getAppAccessToken", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ appId, clientSecret: secret }) });
  const data = await qqJson(res);
  if (!res.ok || (typeof data.code === "number" && data.code !== 0)) throw new Error(`QQ 获取令牌失败（HTTP ${res.status}，错误码 ${typeof data.code === "number" ? data.code : "未知"}）`);
  if (typeof data.access_token !== "string" || !data.access_token || !Number.isFinite(Number(data.expires_in)) || Number(data.expires_in) <= 0) throw new Error("QQ 令牌响应无效");
  qqTokenCache = { appId, secret, token: data.access_token, expiresAt: Date.now() + Math.max(0, Number(data.expires_in) - 90) * 1000 };
  return data.access_token;
};
const postQQ = async (appId: string, secret: string, groupOpenId: string, text: string) => {
  const token = await getQQToken(appId, secret);
  const res = await qqFetch(`https://api.bot.qq.com/v2/groups/${encodeURIComponent(groupOpenId)}/messages`, {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `QQBot ${token}` },
    body: JSON.stringify({ msg_type: 0, content: text }),
  });
  const data = await qqJson(res);
  const errorCode = typeof data.code === "number" ? data.code : typeof data.err_code === "number" ? data.err_code : undefined;
  if (!res.ok || (errorCode !== undefined && errorCode !== 0) || typeof data.id !== "string" || !data.id) {
    if (res.status === 401) qqTokenCache = undefined;
    throw new Error(`QQ 群消息发送失败（HTTP ${res.status}，错误码 ${errorCode ?? "未知"}）`);
  }
};

const SENDERS: Sender[] = [
  {
    channel: "telegram",
    enabled: (s) => !!s["notify.telegram.botToken"] && !!s["notify.telegram.chatId"],
    send: (s, n, repo) =>
      post(`https://api.telegram.org/bot${s["notify.telegram.botToken"]}/sendMessage`, {
        chat_id: s["notify.telegram.chatId"],
        text: `[${repo}] ${n.title}${n.url ? `\n${n.url}` : ""}`,
        disable_web_page_preview: true,
      }),
  },
  {
    channel: "discord",
    enabled: (s) => !!s["notify.discord.webhookUrl"],
    send: (s, n, repo) => post(s["notify.discord.webhookUrl"], { content: `**[${repo}]** ${n.title}${n.url ? `\n${n.url}` : ""}` }),
  },
  {
    channel: "wecom",
    enabled: (s) => !!s["notify.wecom.webhookUrl"],
    send: (s, n, repo) => postWeCom(s["notify.wecom.webhookUrl"], `[${repo}] ${n.title}${n.url ? `\n${n.url}` : ""}`),
  },
  {
    channel: "feishu",
    enabled: (s) => !!s["notify.feishu.webhookUrl"],
    send: (s, n, repo) => postFeishu(s["notify.feishu.webhookUrl"], s["notify.feishu.secret"] || "", `OpenSource Hub [${repo}] ${n.title}${n.url ? `\n${n.url}` : ""}`),
  },
  {
    channel: "qq",
    enabled: (s) => !!s["notify.qq.appId"] && !!s["notify.qq.clientSecret"] && !!s["notify.qq.groupOpenId"],
    send: (s, n, repo) => postQQ(s["notify.qq.appId"], s["notify.qq.clientSecret"], s["notify.qq.groupOpenId"], `OpenSource Hub [${repo}] ${n.title}${n.url ? `\n${n.url}` : ""}`),
  },
  {
    channel: "webhook",
    enabled: (s) => !!s["notify.webhook.url"],
    send: (s, n, repo) => post(s["notify.webhook.url"], { repository: repo, title: n.title, body: n.body, url: n.url, versionEventId: n.versionEventId }),
  },
  {
    channel: "email",
    enabled: (s) => emailConfigured(s),
    send: (s, n, repo) => sendEmailNotification(s, repo, n.title, n.url),
  },
];

export async function dispatchNotifications(items: NotifyItem[]) {
  if (!items.length) return 0;
  const settings = await getAllSettings();
  let created = 0;
  for (const n of items) {
    const repo = await prisma.repository.findUnique({ where: { id: n.repositoryId }, select: { fullName: true } });
    const repoName = repo?.fullName ?? String(n.repositoryId);
    if (settings["notify.web.enabled"] !== "false") {
      try {
        await prisma.notification.create({ data: { repositoryId: n.repositoryId, versionEventId: n.versionEventId, channel: "web", title: n.title, body: n.body, url: n.url ?? undefined, status: "sent" } });
        created++;
      } catch {
        /* 唯一约束：已通知过 */
      }
    }
    for (const s of SENDERS) {
      if (!s.enabled(settings)) continue;
      let rowId: number;
      try {
        rowId = (await prisma.notification.create({ data: { repositoryId: n.repositoryId, versionEventId: n.versionEventId, channel: s.channel, title: n.title, body: n.body, url: n.url ?? undefined, readAt: new Date() } })).id;
      } catch {
        continue;
      }
      try {
        await s.send(settings, n, repoName);
        await prisma.notification.update({ where: { id: rowId }, data: { status: "sent" } });
      } catch (e) {
        await prisma.notification.update({ where: { id: rowId }, data: { status: "failed", error: (e as Error).message } });
      }
    }
  }
  return created;
}
