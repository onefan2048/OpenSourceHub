import Foundation
import CryptoKit

public struct NotifyPayload: Sendable {
    public let repositoryId: Int64
    public let versionEventId: Int64?
    public let repoFullName: String
    public let title: String
    public let body: String?
    public let url: String?

    public init(repositoryId: Int64, versionEventId: Int64? = nil, repoFullName: String, title: String, body: String? = nil, url: String? = nil) {
        self.repositoryId = repositoryId
        self.versionEventId = versionEventId
        self.repoFullName = repoFullName
        self.title = title
        self.body = body
        self.url = url
    }
}

public enum NotificationDispatcher {
    public typealias LocalNotifyHandler = @Sendable (String, String, String?) -> Void

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        return URLSession(configuration: cfg)
    }()

    public static func dispatch(
        store: SQLiteStore,
        items: [NotifyPayload],
        onLocalNotify: LocalNotifyHandler? = nil
    ) async {
        guard !items.isEmpty else { return }
        let settings = store.getAllSettings()

        for item in items {
            // 1. Always record in-app notification
            if settings["notify.local.enabled"] != "false" {
                let inserted = store.insertNotification(
                    repositoryId: item.repositoryId,
                    versionEventId: item.versionEventId,
                    channel: "web",
                    title: item.title,
                    body: item.body,
                    url: item.url,
                    status: "sent",
                    error: nil
                )
                if inserted {
                    onLocalNotify?(item.title, item.body ?? item.repoFullName, item.url)
                }
            }

            let summaryText = [item.title, item.body, item.url].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")

            // 2. Telegram
            let tgToken = (settings["notify.telegram.botToken"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tgChat = (settings["notify.telegram.chatId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !tgToken.isEmpty && !tgChat.isEmpty {
                await sendChannel(store: store, item: item, channel: "telegram") {
                    try await postJSON(
                        url: "https://api.telegram.org/bot\(tgToken)/sendMessage",
                        body: ["chat_id": tgChat, "text": summaryText, "disable_web_page_preview": false]
                    )
                }
            }

            // 3. Discord
            let discordUrl = (settings["notify.discord.webhookUrl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !discordUrl.isEmpty {
                await sendChannel(store: store, item: item, channel: "discord") {
                    try await postJSON(url: discordUrl, body: ["content": summaryText])
                }
            }

            // 4. WeCom (企业微信)
            let wecomUrl = (settings["notify.wecom.webhookUrl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !wecomUrl.isEmpty {
                await sendChannel(store: store, item: item, channel: "wecom") {
                    try await sendWeCom(url: wecomUrl, text: summaryText)
                }
            }

            // 5. Feishu (飞书)
            let feishuUrl = (settings["notify.feishu.webhookUrl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !feishuUrl.isEmpty {
                let secret = (settings["notify.feishu.secret"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                await sendChannel(store: store, item: item, channel: "feishu") {
                    try await sendFeishu(url: feishuUrl, secret: secret, text: summaryText)
                }
            }

            // 6. QQ Bot
            let qqAppId = (settings["notify.qq.appId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let qqSecret = (settings["notify.qq.clientSecret"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let qqGroup = (settings["notify.qq.groupOpenId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !qqAppId.isEmpty && !qqSecret.isEmpty && !qqGroup.isEmpty {
                await sendChannel(store: store, item: item, channel: "qq") {
                    try await sendQQ(appId: qqAppId, secret: qqSecret, groupOpenId: qqGroup, text: summaryText)
                }
            }

            // 7. Generic Webhook
            let webhookUrl = (settings["notify.webhook.url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !webhookUrl.isEmpty {
                await sendChannel(store: store, item: item, channel: "webhook") {
                    try await postJSON(url: webhookUrl, body: [
                        "source": "OpenSourceHub-iOS",
                        "repository": item.repoFullName,
                        "title": item.title,
                        "body": item.body ?? "",
                        "url": item.url ?? "",
                    ])
                }
            }

            // 8. Email (SMTP TLS / STARTTLS / Outlook OAuth2)
            let smtpConfig = SMTPClient.Config.from(settings: settings)
            if smtpConfig.isConfigured {
                await sendChannel(store: store, item: item, channel: "email") {
                    let bodyText = "软件源：\(item.repoFullName)\n更新：\(item.title)\(item.body.map { "\n\($0)" } ?? "")\(item.url.map { "\n链接：\($0)" } ?? "")"
                    try await SMTPClient.send(
                        config: smtpConfig,
                        subject: "[OpenSource Hub] \(item.repoFullName) \(item.title)",
                        body: bodyText,
                        onRefreshTokenRotated: { newToken in
                            store.setSetting("notify.email.outlook.refreshToken", value: newToken)
                        }
                    )
                }
            }
        }
    }

    public static func sendTest(channel: String, settings: [String: String], store: SQLiteStore? = nil) async throws {
        let text = "OpenSource Hub iOS 测试通知（\(ISO8601DateFormatter().string(from: Date()))）"
        switch channel {
        case "email":
            let cfg = SMTPClient.Config.from(settings: settings)
            try await SMTPClient.send(
                config: cfg,
                subject: "[OpenSource Hub] 测试邮件通知",
                body: text,
                onRefreshTokenRotated: { newToken in
                    store?.setSetting("notify.email.outlook.refreshToken", value: newToken)
                }
            )
        case "telegram":
            let token = settings["notify.telegram.botToken"] ?? ""
            let chat = settings["notify.telegram.chatId"] ?? ""
            guard !token.isEmpty, !chat.isEmpty else { throw NSError(domain: "Notify", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先填写 Bot Token 与 Chat ID"]) }
            try await postJSON(url: "https://api.telegram.org/bot\(token)/sendMessage", body: ["chat_id": chat, "text": text])
        case "discord":
            let url = settings["notify.discord.webhookUrl"] ?? ""
            guard !url.isEmpty else { throw NSError(domain: "Notify", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先填写 Discord Webhook URL"]) }
            try await postJSON(url: url, body: ["content": text])
        case "wecom":
            let url = settings["notify.wecom.webhookUrl"] ?? ""
            guard !url.isEmpty else { throw NSError(domain: "Notify", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先填写企业微信 Webhook URL"]) }
            try await sendWeCom(url: url, text: text)
        case "feishu":
            let url = settings["notify.feishu.webhookUrl"] ?? ""
            guard !url.isEmpty else { throw NSError(domain: "Notify", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先填写飞书 Webhook URL"]) }
            try await sendFeishu(url: url, secret: settings["notify.feishu.secret"] ?? "", text: text)
        case "qq":
            let appId = settings["notify.qq.appId"] ?? ""
            let secret = settings["notify.qq.clientSecret"] ?? ""
            let group = settings["notify.qq.groupOpenId"] ?? ""
            guard !appId.isEmpty, !secret.isEmpty, !group.isEmpty else { throw NSError(domain: "Notify", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先填写 QQ 机器人完整凭据"]) }
            try await sendQQ(appId: appId, secret: secret, groupOpenId: group, text: text)
        case "webhook":
            let url = settings["notify.webhook.url"] ?? ""
            guard !url.isEmpty else { throw NSError(domain: "Notify", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先填写自定义 Webhook URL"]) }
            try await postJSON(url: url, body: ["source": "OpenSourceHub-iOS", "title": text])
        default:
            break
        }
    }

    private static func sendChannel(store: SQLiteStore, item: NotifyPayload, channel: String, action: () async throws -> Void) async {
        do {
            try await action()
            _ = store.insertNotification(
                repositoryId: item.repositoryId,
                versionEventId: item.versionEventId,
                channel: channel,
                title: item.title,
                body: item.body,
                url: item.url,
                status: "sent",
                error: nil
            )
        } catch {
            _ = store.insertNotification(
                repositoryId: item.repositoryId,
                versionEventId: item.versionEventId,
                channel: channel,
                title: item.title,
                body: item.body,
                url: item.url,
                status: "failed",
                error: error.localizedDescription
            )
        }
    }

    private static func postJSON(url urlString: String, body: [String: Any], headers: [String: String] = [:]) async throws {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Notify", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效的 URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Notify", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
    }

    private static func sendWeCom(url urlString: String, text: String) async throws {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Notify", code: 2, userInfo: [NSLocalizedDescriptionKey: "企业微信 URL 无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["msgtype": "text", "text": ["content": text]])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Notify", code: 3, userInfo: [NSLocalizedDescriptionKey: "企业微信 HTTP 错误"])
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["errcode"] as? Int, code != 0 {
            throw NSError(domain: "Notify", code: code, userInfo: [NSLocalizedDescriptionKey: "企业微信错误码 \(code)"])
        }
    }

    private static func sendFeishu(url urlString: String, secret: String, text: String) async throws {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Notify", code: 2, userInfo: [NSLocalizedDescriptionKey: "飞书 URL 无效"])
        }
        var payload: [String: Any] = ["msg_type": "text", "content": ["text": text]]
        if !secret.isEmpty {
            let ts = String(Int(Date().timeIntervalSince1970))
            let key = SymmetricKey(data: Data("\(ts)\n\(secret)".utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: Data(), using: key)
            payload["timestamp"] = ts
            payload["sign"] = Data(mac).base64EncodedString()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Notify", code: 3, userInfo: [NSLocalizedDescriptionKey: "飞书 HTTP 错误"])
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? Int, code != 0 {
            throw NSError(domain: "Notify", code: code, userInfo: [NSLocalizedDescriptionKey: "飞书错误码 \(code)"])
        }
    }

    private static func sendQQ(appId: String, secret: String, groupOpenId: String, text: String) async throws {
        guard let tokenURL = URL(string: "https://api.bot.qq.com/app/getAppAccessToken") else { return }
        var tReq = URLRequest(url: tokenURL)
        tReq.httpMethod = "POST"
        tReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tReq.httpBody = try JSONSerialization.data(withJSONObject: ["appId": appId, "clientSecret": secret])
        let (tData, _) = try await session.data(for: tReq)
        guard let tJson = try? JSONSerialization.jsonObject(with: tData) as? [String: Any],
              let token = tJson["access_token"] as? String, !token.isEmpty else {
            throw NSError(domain: "Notify", code: 4, userInfo: [NSLocalizedDescriptionKey: "QQ 获取访问令牌失败"])
        }
        let encodedGroup = groupOpenId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupOpenId
        try await postJSON(
            url: "https://api.bot.qq.com/v2/groups/\(encodedGroup)/messages",
            body: ["msg_type": 0, "content": text],
            headers: ["Authorization": "QQBot \(token)"]
        )
    }
}
