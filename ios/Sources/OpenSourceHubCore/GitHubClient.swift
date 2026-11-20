import Foundation

public struct GitHubAPIError: Error, LocalizedError, Sendable {
    public let statusCode: Int
    public let message: String
    public let isRateLimit: Bool
    public let isNotFound: Bool

    public var errorDescription: String? { message }
}

public struct GitHubResponse<T: Decodable>: Sendable where T: Sendable {
    public let data: T
    public let notModified: Bool
    public let nextLink: String?
}

public final class GitHubClient: @unchecked Sendable {
    private let store: SQLiteStore
    private let token: String?
    private let session: URLSession
    private let lock = NSLock()
    private var _rateLimit = RateLimitInfo()
    private var _requestCount = 0
    private var _notModifiedCount = 0

    public var rateLimit: RateLimitInfo { lock.withLock { _rateLimit } }
    public var requestCount: Int { lock.withLock { _requestCount } }
    public var notModifiedCount: Int { lock.withLock { _notModifiedCount } }

    public init(store: SQLiteStore, token: String? = nil) {
        self.store = store
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (trimmed?.isEmpty == false) ? trimmed : nil
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: cfg)
    }

    public func resetCounters() {
        lock.withLock {
            _requestCount = 0
            _notModifiedCount = 0
        }
    }

    public func request<T: Decodable & Sendable>(
        path: String,
        useCache: Bool = true
    ) async throws -> GitHubResponse<T> {
        let fullURLString = path.hasPrefix("http") ? path : "https://api.github.com\(path)"
        guard let url = URL(string: fullURLString) else {
            throw GitHubAPIError(statusCode: 0, message: "无效请求地址: \(path)", isRateLimit: false, isNotFound: false)
        }

        let cacheKey = fullURLString
        let cached = useCache ? store.getHttpCache(key: cacheKey) : nil

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("OpenSourceHub-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let token = token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let etag = cached?.etag {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        } else if let lm = cached?.lastModified {
            req.setValue(lm, forHTTPHeaderField: "If-Modified-Since")
        }

        lock.withLock { _requestCount += 1 }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubAPIError(statusCode: 0, message: "无 HTTP 响应", isRateLimit: false, isNotFound: false)
        }

        updateRateLimit(from: http)

        if http.statusCode == 304, let cached = cached, let cachedData = cached.body.data(using: .utf8) {
            lock.withLock { _notModifiedCount += 1 }
            let decoded = try JSONDecoder().decode(T.self, from: cachedData)
            return GitHubResponse(data: decoded, notModified: true, nextLink: parseNextLink(cached.linkHeader))
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = extractErrorMessage(data: data, status: http.statusCode)
            let isRL = http.statusCode == 429 || (http.statusCode == 403 && (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || msg.localizedCaseInsensitiveContains("rate limit")))
            throw GitHubAPIError(statusCode: http.statusCode, message: msg, isRateLimit: isRL, isNotFound: http.statusCode == 404)
        }

        let linkHeader = http.value(forHTTPHeaderField: "Link")
        if useCache, let bodyStr = String(data: data, encoding: .utf8) {
            let etag = http.value(forHTTPHeaderField: "ETag")
            let lm = http.value(forHTTPHeaderField: "Last-Modified")
            if etag != nil || lm != nil {
                store.setHttpCache(HttpCacheEntry(key: cacheKey, etag: etag, lastModified: lm, body: bodyStr, linkHeader: linkHeader, updatedAt: Date()))
            }
        }

        let decoded = try JSONDecoder().decode(T.self, from: data)
        return GitHubResponse(data: decoded, notModified: false, nextLink: parseNextLink(linkHeader))
    }

    public func requestRawText(path: String, accept: String = "application/vnd.github.raw+json") async throws -> String {
        let fullURLString = path.hasPrefix("http") ? path : "https://api.github.com\(path)"
        guard let url = URL(string: fullURLString) else {
            throw GitHubAPIError(statusCode: 0, message: "无效请求地址", isRateLimit: false, isNotFound: false)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("OpenSourceHub-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let token = token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        lock.withLock { _requestCount += 1 }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubAPIError(statusCode: 0, message: "无 HTTP 响应", isRateLimit: false, isNotFound: false)
        }
        updateRateLimit(from: http)
        guard (200...299).contains(http.statusCode) else {
            throw GitHubAPIError(statusCode: http.statusCode, message: extractErrorMessage(data: data, status: http.statusCode), isRateLimit: http.statusCode == 429, isNotFound: http.statusCode == 404)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func graphql(query: String, variables: [String: Any]) async throws -> [String: Any] {
        guard let token = token else {
            throw GitHubAPIError(statusCode: 401, message: "读取 Discussions 需要配置 GitHub Token", isRateLimit: false, isNotFound: false)
        }
        guard let url = URL(string: "https://api.github.com/graphql") else {
            throw GitHubAPIError(statusCode: 0, message: "GraphQL URL 无效", isRateLimit: false, isNotFound: false)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("OpenSourceHub-iOS/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        lock.withLock { _requestCount += 1 }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubAPIError(statusCode: 0, message: "无 HTTP 响应", isRateLimit: false, isNotFound: false)
        }
        updateRateLimit(from: http)
        guard (200...299).contains(http.statusCode) else {
            throw GitHubAPIError(statusCode: http.statusCode, message: extractErrorMessage(data: data, status: http.statusCode), isRateLimit: http.statusCode == 429, isNotFound: false)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubAPIError(statusCode: 500, message: "GraphQL 响应解析失败", isRateLimit: false, isNotFound: false)
        }
        return obj
    }

    private func updateRateLimit(from http: HTTPURLResponse) {
        let limit = http.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init)
        let rem = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        if limit != nil || rem != nil || reset != nil {
            lock.withLock {
                if let l = limit { _rateLimit.limit = l }
                if let r = rem { _rateLimit.remaining = r }
                if let rs = reset { _rateLimit.resetAt = rs }
            }
        }
    }

    private func parseNextLink(_ linkHeader: String?) -> String? {
        guard let header = linkHeader else { return nil }
        for part in header.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(#"rel="next""#),
               let start = trimmed.firstIndex(of: "<"),
               let end = trimmed.firstIndex(of: ">"), start < end {
                return String(trimmed[trimmed.index(after: start)..<end])
            }
        }
        return nil
    }

    private func extractErrorMessage(data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["message"] as? String, !msg.isEmpty {
            return "GitHub HTTP \(status): \(msg)"
        }
        return "GitHub HTTP \(status)"
    }
}

// MARK: - GitHub REST Decodable DTOs

struct GhRepoDTO: Decodable, Sendable {
    let id: Int64
    let name: String
    let full_name: String
    let description: String?
    let homepage: String?
    let html_url: String
    let owner: GhUserDTO
    let stargazers_count: Int
    let forks_count: Int
    let watchers_count: Int
    let subscribers_count: Int?
    let license: GhLicenseDTO?
    let language: String?
    let topics: [String]?
    let default_branch: String?
    let archived: Bool
    let fork: Bool
    let pushed_at: String?
}

struct GhUserDTO: Decodable, Sendable {
    let login: String
    let avatar_url: String?
}

struct GhLicenseDTO: Decodable, Sendable {
    let spdx_id: String?
    let name: String?
}

struct GhReleaseDTO: Decodable, Sendable {
    let id: Int64
    let tag_name: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let created_at: String?
    let html_url: String
    let zipball_url: String?
    let tarball_url: String?
    let author: GhUserDTO?
    let assets: [GhAssetDTO]
}

struct GhAssetDTO: Decodable, Sendable {
    let id: Int64
    let name: String
    let label: String?
    let content_type: String?
    let size: Int64
    let download_count: Int
    let browser_download_url: String
    let digest: String?
    let created_at: String?
}

struct GhTagDTO: Decodable, Sendable {
    let name: String
    let commit: GhTagCommitRef
    let zipball_url: String?
    let tarball_url: String?
}

struct GhTagCommitRef: Decodable, Sendable {
    let sha: String
}

struct GhCommitDTO: Decodable, Sendable {
    let sha: String
    let html_url: String
    let commit: GhCommitDetail
    let author: GhUserDTO?
}

struct GhCommitDetail: Decodable, Sendable {
    let message: String
    let author: GhCommitAuthor?
    let committer: GhCommitAuthor?
}

struct GhCommitAuthor: Decodable, Sendable {
    let name: String?
    let date: String?
}

struct GhContentEntryDTO: Decodable, Sendable {
    let name: String
    let path: String
    let sha: String
    let type: String
    let download_url: String?
}

struct GhIssueDTO: Decodable, Sendable {
    let number: Int
    let title: String
    let state: String
    let user: GhUserDTO?
    let labels: [GhLabelDTO]?
    let comments: Int
    let html_url: String
    let body: String?
    let created_at: String
    let updated_at: String
    let pull_request: GhPullRequestMarker?
}

struct GhLabelDTO: Decodable, Sendable {
    let name: String
    let color: String?
}

struct GhPullRequestMarker: Decodable, Sendable {
    let url: String?
}

struct GhIssueCommentDTO: Decodable, Sendable {
    let id: Int64
    let user: GhUserDTO?
    let body: String?
    let created_at: String
}

struct GhSingleCommitDTO: Decodable, Sendable {
    let sha: String
    let commit: GhCommitDetail
}
