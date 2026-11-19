import Foundation

public struct RepoRef: Equatable, Sendable {
    public let provider: String
    public let owner: String
    public let name: String

    public init(provider: String, owner: String, name: String) {
        self.provider = provider
        self.owner = owner
        self.name = name
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var fullNameKey: String { "\(owner)/\(name)".lowercased() }
    public var htmlUrl: String { "https://github.com/\(owner)/\(name)" }
}

public enum RepoParseResult: Equatable, Sendable {
    case ok(RepoRef)
    case error(String)
}

public enum RepoParser {
    private static let validNameSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")

    public static func parse(_ input: String) -> RepoParseResult {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .error("输入为空") }
        if s.hasPrefix("git+") {
            s = String(s.dropFirst(4))
        }

        // git@github.com:owner/repo(.git)
        if s.lowercased().hasPrefix("git@github.com:") {
            let rest = String(s.dropFirst("git@github.com:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = rest.split(separator: "/").map(String.init)
            if parts.count == 2 {
                return finalize(owner: parts[0], name: parts[1])
            }
            return .error("SSH 地址格式不正确")
        }

        // URL or domain/owner/repo
        if s.contains(".") && s.contains("/") {
            let urlStr = (s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://")) ? s : "https://\(s)"
            guard let url = URL(string: urlStr), let rawHost = url.host?.lowercased() else {
                return .error("无法识别的 URL")
            }
            let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
            if host != "github.com" {
                if ["gitlab.com", "codeberg.org", "gitee.com"].contains(host) {
                    return .error("暂不支持 \(host)（已预留扩展接口）")
                }
                return .error("目前只支持 GitHub 仓库地址")
            }
            let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            if parts.count < 2 { return .error("URL 中缺少 owner/repository") }
            return finalize(owner: parts[0], name: parts[1])
        }

        // owner/repo
        let parts = s.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.count == 2 {
            return finalize(owner: parts[0], name: parts[1])
        }
        return .error("请输入 GitHub 仓库 URL 或 owner/repository")
    }

    private static func finalize(owner: String, name rawName: String) -> RepoParseResult {
        var name = rawName
        if name.lowercased().hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        guard !owner.isEmpty, !name.isEmpty,
              owner.unicodeScalars.allSatisfy({ validNameSet.contains($0) }),
              name.unicodeScalars.allSatisfy({ validNameSet.contains($0) }),
              name != ".", name != ".." else {
            return .error("owner 或仓库名包含非法字符")
        }
        return .ok(RepoRef(provider: "github", owner: owner, name: name))
    }

    /// 将批量导入文本拆分为去重条目（换行、逗号、分号、空格分隔）
    public static func splitBatchInput(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；"))
        var seen = Set<String>()
        var result: [String] = []
        for token in text.components(separatedBy: separators) {
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && seen.insert(t).inserted {
                result.append(t)
            }
        }
        return result
    }
}
