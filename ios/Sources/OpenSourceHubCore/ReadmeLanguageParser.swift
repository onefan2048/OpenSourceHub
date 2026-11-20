import Foundation

public struct ReadmeVariant: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path.lowercased() }
    public let label: String
    public let path: String // repo-relative path, e.g. "docs/readme/README_zh.md"
    public let isChinese: Bool

    public init(label: String, path: String, isChinese: Bool) {
        self.label = label
        self.path = path
        self.isChinese = isChinese
    }
}

public enum ReadmeLanguageParser {
    private static let chineseMarkers = ["简体中文", "中文", "繁體中文", "繁体中文", "chinese", "zh-cn", "zh_cn", "zh-hans", "zh-tw", "zh_tw", "zh-hant", "_zh.", "-zh.", ".zh."]

    public static func isChineseVariant(label: String, path: String) -> Bool {
        let l = label.lowercased()
        let p = path.lowercased()
        if chineseMarkers.contains(where: { l.contains($0) || p.contains($0) }) { return true }
        // e.g. README_zh.md or zh.md
        if p.range(of: #"(^|[/._-])zh([._-](cn|tw|hk|hans|hant))?\.md$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    public static func isSimplifiedChinese(label: String, path: String) -> Bool {
        let l = label.lowercased()
        let p = path.lowercased()
        if l.contains("简体") || l.contains("中文") && !l.contains("繁") { return true }
        if p.contains("zh-cn") || p.contains("zh_cn") || p.contains("zh-hans") || p.range(of: #"readme[._-]zh\.md$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Extracts multi-language README variants from both the README content (Markdown & HTML links)
    /// and the repository's root directory tree.
    public static func extractVariants(
        readme: String,
        owner: String,
        repo: String,
        branch: String?,
        rootTree: [RepoTreeEntry]
    ) -> [ReadmeVariant] {
        var variants: [ReadmeVariant] = []
        var seenPaths = Set<String>()

        func addVariant(label rawLabel: String, rawPath: String) {
            guard let normPath = normalizeRepoMarkdownPath(rawPath, owner: owner, repo: repo, branch: branch) else { return }
            let lower = normPath.lowercased()
            // Skip the default root README.md itself
            if lower == "readme.md" || lower == "readme.markdown" { return }
            guard isLikelyReadmePath(lower, label: rawLabel) else { return }
            guard seenPaths.insert(lower).inserted else { return }
            let cleanLabel = stripHTMLTags(rawLabel).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalLabel = cleanLabel.isEmpty ? (normPath as NSString).lastPathComponent : cleanLabel
            variants.append(ReadmeVariant(
                label: finalLabel,
                path: normPath,
                isChinese: isChineseVariant(label: finalLabel, path: normPath)
            ))
        }

        // 1. Parse HTML <a href="...">label</a> links
        if let regex = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#) {
            let ns = readme as NSString
            for m in regex.matches(in: readme, range: NSRange(location: 0, length: ns.length)) {
                let href = ns.substring(with: m.range(at: 1))
                let text = ns.substring(with: m.range(at: 2))
                addVariant(label: text, rawPath: href)
            }
        }

        // 2. Parse Markdown [label](url) links
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) {
            let ns = readme as NSString
            for m in regex.matches(in: readme, range: NSRange(location: 0, length: ns.length)) {
                let text = ns.substring(with: m.range(at: 1))
                let href = ns.substring(with: m.range(at: 2))
                addVariant(label: text, rawPath: href)
            }
        }

        // 3. Also scan rootTree for README*.md files (e.g. README_zh.md, README.en.md)
        for entry in rootTree where entry.type == "file" {
            let lower = entry.name.lowercased()
            if lower.hasPrefix("readme") && (lower.hasSuffix(".md") || lower.hasSuffix(".markdown")) && lower != "readme.md" {
                let label = friendlyLabelFromFilename(entry.name)
                addVariant(label: label, rawPath: entry.path)
            }
        }

        return variants
    }

    /// Converts a relative path or same-repo GitHub blob URL into a repo-relative `.md` path.
    public static func normalizeRepoMarkdownPath(_ raw: String, owner: String, repo: String, branch: String?) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("#") || s.lowercased().hasPrefix("mailto:") { return nil }
        // Strip query/fragment
        if let qIdx = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            s = String(s[..<qIdx])
        }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: s), let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else {
                return nil
            }
            let parts = url.path.split(separator: "/").map(String.init)
            // /owner/repo/blob/branch/path/to/file.md
            guard parts.count >= 5,
                  parts[0].lowercased() == owner.lowercased(),
                  parts[1].lowercased() == repo.lowercased(),
                  parts[2].lowercased() == "blob" else {
                return nil
            }
            let rel = parts.dropFirst(4).joined(separator: "/")
            return isMarkdownFile(rel) ? rel : nil
        }

        // Relative path
        while s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        while s.hasPrefix("/") { s = String(s.dropFirst()) }
        return isMarkdownFile(s) ? s : nil
    }

    /// Checks whether a tapped URL in WKWebView points to a `.md` file inside this same repository.
    public static func extractSameRepoMarkdownPath(from url: URL, owner: String, repo: String) -> String? {
        normalizeRepoMarkdownPath(url.absoluteString, owner: owner, repo: repo, branch: nil)
    }

    private static func isMarkdownFile(_ path: String) -> Bool {
        let l = path.lowercased()
        return l.hasSuffix(".md") || l.hasSuffix(".markdown")
    }

    private static func isLikelyReadmePath(_ lowerPath: String, label: String) -> Bool {
        let filename = (lowerPath as NSString).lastPathComponent
        if filename.contains("readme") { return true }
        let l = label.lowercased()
        let knownLangLabels = [
            "中文", "简体", "繁體", "繁体", "english", "日本語", "한국어",
            "deutsch", "español", "français", "русский", "italiano", "português",
            "türkçe", "tiếng việt", "polski", "bahasa", "العربية", "فارسی",
        ]
        if knownLangLabels.contains(where: { l.contains($0) }) { return true }
        return false
    }

    private static func friendlyLabelFromFilename(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("zh-cn") || l.contains("zh_cn") || l.contains("zh-hans") || l.contains("_zh.") || l.contains(".zh.") || l.contains("-zh.") {
            return "简体中文"
        }
        if l.contains("zh-tw") || l.contains("zh_tw") || l.contains("zh-hant") { return "繁體中文" }
        if l.contains(".en.") || l.contains("_en.") || l.contains("-en.") { return "English" }
        if l.contains(".ja.") || l.contains("_ja.") || l.contains("-ja.") || l.contains("_jp.") { return "日本語" }
        if l.contains(".ko.") || l.contains("_ko.") || l.contains("-ko.") { return "한국어" }
        return name
    }

    private static func stripHTMLTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }
}
