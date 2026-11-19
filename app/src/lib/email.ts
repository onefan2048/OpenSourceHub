import * as nodemailer from "nodemailer";
import { getSetting, setSetting } from "./settings";

const SCOPE = "https://outlook.office.com/SMTP.Send offline_access";
let outlookRefreshing: Promise<string> | undefined;

async function refreshOutlookToken(): Promise<string> {
  // 同一 Worker 内合并并发刷新，避免同时覆盖轮换后的 refresh token。
  if (outlookRefreshing) return outlookRefreshing;
  outlookRefreshing = (async () => {
    const [clientId, refreshToken] = await Promise.all([
      getSetting("notify.email.outlook.clientId"),
      getSetting("notify.email.outlook.refreshToken"),
    ]);
    if (!clientId || !refreshToken) throw new Error("Outlook 尚未完成 Microsoft 授权");
    let response: Response;
    try {
      response = await fetch("https://login.microsoftonline.com/consumers/oauth2/v2.0/token", {
        method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ client_id: clientId, grant_type: "refresh_token", refresh_token: refreshToken, scope: SCOPE }),
        signal: AbortSignal.timeout(15000),
      });
    } catch { throw new Error("Outlook 授权服务连接失败"); }
    let data: { access_token?: unknown; refresh_token?: unknown; error?: unknown };
    try { data = await response.json() as typeof data; }
    catch { throw new Error("Outlook 授权服务响应无效"); }
    if (!response.ok || !data || typeof data.access_token !== "string" || !data.access_token) {
      const code = typeof data?.error === "string" && /^[a-z_]+$/.test(data.error) ? data.error : "unknown";
      throw new Error(`Outlook 授权失败（${code}），请重新授权`);
    }
    if (typeof data.refresh_token === "string" && data.refresh_token) await setSetting("notify.email.outlook.refreshToken", data.refresh_token);
    return data.access_token;
  })();
  try { return await outlookRefreshing; } finally { outlookRefreshing = undefined; }
}

export function emailConfigured(s: Record<string, string>): boolean {
  const base = !!s["notify.email.to"] && !!s["notify.email.username"] && !!s["notify.email.host"] && !!s["notify.email.port"];
  return base && (s["notify.email.provider"] === "outlook"
    ? !!s["notify.email.outlook.clientId"] && !!s["notify.email.outlook.refreshToken"]
    : !!s["notify.email.password"]);
}

export async function sendEmailNotification(s: Record<string, string>, repo: string, title: string, url?: string | null): Promise<void> {
  if (!emailConfigured(s)) throw new Error("请先完整配置邮件通知");
  const port = Number(s["notify.email.port"]);
  const security = s["notify.email.security"];
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !["tls", "starttls"].includes(security)) throw new Error("SMTP 端口或加密方式无效");
  const user = s["notify.email.username"].trim();
  const auth = s["notify.email.provider"] === "outlook"
    ? { type: "OAuth2" as const, user, accessToken: await refreshOutlookToken() }
    : { user, pass: s["notify.email.password"] };
  const transport = nodemailer.createTransport({
    host: s["notify.email.host"].trim(), port, secure: security === "tls", requireTLS: security === "starttls",
    auth, connectionTimeout: 15000, greetingTimeout: 15000, socketTimeout: 30000,
  });
  try {
    const result = await transport.sendMail({
      from: user, to: s["notify.email.to"], subject: `[OpenSource Hub] ${repo} ${title}`,
      text: `软件源：${repo}\n更新：${title}${url ? `\n链接：${url}` : ""}`,
    });
    if (!result.accepted?.length) throw new Error("NO_RECIPIENT_ACCEPTED");
  } catch (error) {
    // 不保存服务端响应或凭证，避免泄露认证信息。
    const code = (error as { code?: unknown })?.code;
    const safeCode = typeof code === "string" && /^[A-Z0-9_]{1,30}$/.test(code) ? code : "SEND_FAILED";
    throw new Error(`邮件发送失败（${safeCode}）`);
  } finally { transport.close(); }
}
