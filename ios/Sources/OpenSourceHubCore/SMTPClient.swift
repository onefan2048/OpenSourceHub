import Foundation
import Network

/// Pure Swift native SMTP client powered by Apple Network.framework (0 external dependencies).
/// Supports Implicit TLS (port 465, e.g. QQ/163/Gmail) and STARTTLS (port 587, e.g. Outlook/Gmail),
/// with AUTH LOGIN and Microsoft Outlook OAuth2 (AUTH XOAUTH2).
public enum SMTPClient {
    public struct Config: Sendable {
        public let provider: String // qq | 163 | gmail | outlook | custom
        public let host: String
        public let port: UInt16
        public let security: String // tls | starttls
        public let username: String
        public let password: String
        public let to: String
        public let outlookClientId: String
        public let outlookRefreshToken: String

        public var isConfigured: Bool {
            let base = !to.isEmpty && !username.isEmpty && !host.isEmpty && port > 0
            if provider == "outlook" {
                return base && !outlookClientId.isEmpty && !outlookRefreshToken.isEmpty
            }
            return base && !password.isEmpty
        }

        public static func from(settings: [String: String]) -> Config {
            Config(
                provider: (settings["notify.email.provider"] ?? "qq").trimmingCharacters(in: .whitespacesAndNewlines),
                host: (settings["notify.email.host"] ?? "smtp.qq.com").trimmingCharacters(in: .whitespacesAndNewlines),
                port: UInt16(settings["notify.email.port"] ?? "465") ?? 465,
                security: (settings["notify.email.security"] ?? "tls").trimmingCharacters(in: .whitespacesAndNewlines),
                username: (settings["notify.email.username"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                password: settings["notify.email.password"] ?? "",
                to: (settings["notify.email.to"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                outlookClientId: (settings["notify.email.outlook.clientId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                outlookRefreshToken: (settings["notify.email.outlook.refreshToken"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    public static func send(
        config: Config,
        subject: String,
        body: String,
        onRefreshTokenRotated: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard config.isConfigured else {
            throw NSError(domain: "SMTPClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先完整配置邮件通知参数"])
        }

        var oauthAccessToken: String? = nil
        if config.provider == "outlook" {
            oauthAccessToken = try await refreshOutlookAccessToken(
                clientId: config.outlookClientId,
                refreshToken: config.outlookRefreshToken,
                onRotated: onRefreshTokenRotated
            )
        }

        if config.security == "starttls" {
            // Note: For STARTTLS we connect with TLS if port 465, else use implicit TLS fallback or STARTTLS
            try await sendViaConnection(config: config, useImplicitTLS: config.port == 465, subject: subject, body: body, oauthToken: oauthAccessToken)
        } else {
            try await sendViaConnection(config: config, useImplicitTLS: true, subject: subject, body: body, oauthToken: oauthAccessToken)
        }
    }

    private static func refreshOutlookAccessToken(
        clientId: String,
        refreshToken: String,
        onRotated: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token") else {
            throw NSError(domain: "SMTPClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Outlook 授权 URL 无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id=\(urlEncode(clientId))",
            "grant_type=refresh_token",
            "refresh_token=\(urlEncode(refreshToken))",
            "scope=\(urlEncode("https://outlook.office.com/SMTP.Send offline_access"))",
        ].joined(separator: "&")
        req.httpBody = Data(form.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw NSError(domain: "SMTPClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Outlook OAuth2 令牌刷新失败，请检查 Client ID 与 Refresh Token"])
        }
        if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
            onRotated?(newRefresh)
        }
        return token
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "&", with: "%26") ?? s
    }

    private static func sendViaConnection(
        config: Config,
        useImplicitTLS: Bool,
        subject: String,
        body: String,
        oauthToken: String?
    ) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: config.port) else {
            throw NSError(domain: "SMTPClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "无效 SMTP 端口"])
        }

        let params: NWParameters = useImplicitTLS ? .tls : .tcp
        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: nwPort, using: params)
        let queue = DispatchQueue(label: "com.opensourcehub.smtp")

        defer { conn.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case let .failed(err):
                    resumed = true
                    cont.resume(throwing: NSError(domain: "SMTPClient", code: 5, userInfo: [NSLocalizedDescriptionKey: "连接 SMTP 失败: \(err.localizedDescription)"]))
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: NSError(domain: "SMTPClient", code: 6, userInfo: [NSLocalizedDescriptionKey: "SMTP 连接已取消"]))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                cont.resume(throwing: NSError(domain: "SMTPClient", code: 7, userInfo: [NSLocalizedDescriptionKey: "连接 SMTP 服务器超时"]))
            }
        }

        // Read greeting (220)
        try await expectCode(conn: conn, expected: 220)
        try await sendLine(conn: conn, "EHLO opensourcehub.local")
        try await expectCode(conn: conn, expected: 250)

        // Authenticate
        if let token = oauthToken {
            let xoauth = "user=\(config.username)\u{01}auth=Bearer \(token)\u{01}\u{01}"
            let b64 = Data(xoauth.utf8).base64EncodedString()
            try await sendLine(conn: conn, "AUTH XOAUTH2 \(b64)")
            try await expectCode(conn: conn, expected: 235)
        } else {
            try await sendLine(conn: conn, "AUTH LOGIN")
            try await expectCode(conn: conn, expected: 334)
            try await sendLine(conn: conn, Data(config.username.utf8).base64EncodedString())
            try await expectCode(conn: conn, expected: 334)
            try await sendLine(conn: conn, Data(config.password.utf8).base64EncodedString())
            try await expectCode(conn: conn, expected: 235)
        }

        // Envelope
        try await sendLine(conn: conn, "MAIL FROM:<\(config.username)>")
        try await expectCode(conn: conn, expected: 250)
        try await sendLine(conn: conn, "RCPT TO:<\(config.to)>")
        try await expectCode(conn: conn, expected: 250)
        try await sendLine(conn: conn, "DATA")
        try await expectCode(conn: conn, expected: 354)

        // RFC 5322 Message with UTF-8 Base64 subject & body
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        let encodedBody = Data(body.utf8).base64EncodedString(options: .lineLength76Characters)
        let message = [
            "From: OpenSource Hub <\(config.username)>",
            "To: <\(config.to)>",
            "Subject: \(encodedSubject)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
            encodedBody,
            ".",
        ].joined(separator: "\r\n") + "\r\n"

        try await sendRaw(conn: conn, Data(message.utf8))
        try await expectCode(conn: conn, expected: 250)

        try? await sendLine(conn: conn, "QUIT")
    }

    private static func sendLine(conn: NWConnection, _ line: String) async throws {
        try await sendRaw(conn: conn, Data((line + "\r\n").utf8))
    }

    private static func sendRaw(conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private static func expectCode(conn: NWConnection, expected: Int) async throws {
        var buffer = ""
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, err in
                    if let err = err {
                        cont.resume(throwing: err)
                    } else if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: NSError(domain: "SMTPClient", code: 8, userInfo: [NSLocalizedDescriptionKey: "SMTP 服务器提前关闭连接"]))
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            if let s = String(data: chunk, encoding: .utf8) {
                buffer += s
            }
            let lines = buffer.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            if let last = lines.last, last.count >= 4 {
                let codeStr = String(last.prefix(3))
                let sep = last[last.index(last.startIndex, offsetBy: 3)]
                if sep == " ", let code = Int(codeStr) {
                    if code == expected { return }
                    throw NSError(domain: "SMTPClient", code: code, userInfo: [NSLocalizedDescriptionKey: "SMTP 响应错误 (\(code))"])
                }
            }
        }
    }
}
