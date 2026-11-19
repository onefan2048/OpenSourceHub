import Foundation

public struct ChangelogParsed: Equatable, Sendable {
    public let version: String
    public let title: String
    public let date: String?
    public let body: String
}

public enum ChangelogParser {
    public static let versionFiles = [
        "package.json", "Cargo.toml", "pubspec.yaml", "pyproject.toml",
        "composer.json", "setup.cfg", "VERSION", "version.txt",
    ]

    public static func isChangelogName(_ name: String) -> Bool {
        name.range(of: #"^(changelog|changes|history|releases|news)(\.(md|markdown|rst|txt))?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func isReadmeName(_ name: String) -> Bool {
        name.range(of: #"^readme(\.(md|markdown|rst|txt))?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func isLogoName(_ name: String) -> Bool {
        name.range(of: #"^(logo|icon|app[-_]?icon)\.(png|jpe?g|svg|webp)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func parseChangelog(_ text: String, limit: Int = 100) -> [ChangelogParsed] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let headingRegex = try? NSRegularExpression(pattern: #"^(#{1,4})\s+(.*)$"#)
        let underlineRegex = try? NSRegularExpression(pattern: #"^[=\-~]{3,}\s*$"#)
        let versionRegex = try? NSRegularExpression(pattern: #"\[?\b(?:v(?:ersion)?\s*)?(\d+\.\d+(?:\.\d+)*(?:[-+.]?[0-9A-Za-z.-]*)?)\]?"#, options: .caseInsensitive)
        let dateRegex = try? NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2}|\d{4}/\d{2}/\d{2})"#)

        struct Head {
            let idx: Int
            let title: String
            let version: String
            let date: String?
        }

        var heads: [Head] = []
        var seenVersions = Set<String>()

        for i in 0..<lines.count {
            let line = lines[i]
            let nsLine = line as NSString
            var title: String? = nil

            if let m = headingRegex?.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                title = nsLine.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            } else if i + 1 < lines.count {
                let nextLine = lines[i + 1]
                let nsNext = nextLine as NSString
                if underlineRegex?.firstMatch(in: nextLine, range: NSRange(location: 0, length: nsNext.length)) != nil,
                   !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    title = line.trimmingCharacters(in: .whitespaces)
                }
            }

            guard let rawTitle = title, !rawTitle.localizedCaseInsensitiveContains("unreleased") else { continue }
            let nsTitle = rawTitle as NSString
            guard let vm = versionRegex?.firstMatch(in: rawTitle, range: NSRange(location: 0, length: nsTitle.length)) else { continue }
            let version = nsTitle.substring(with: vm.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            guard !version.isEmpty, seenVersions.insert(version).inserted else { continue }

            var date: String? = nil
            if let dm = dateRegex?.firstMatch(in: rawTitle, range: NSRange(location: 0, length: nsTitle.length)) {
                date = nsTitle.substring(with: dm.range(at: 1))
            }
            let cleanTitle = rawTitle.replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespaces)
            heads.append(Head(idx: i, title: cleanTitle, version: version, date: date))
            if heads.count >= limit { break }
        }

        return heads.enumerated().map { k, h in
            let end = k + 1 < heads.count ? heads[k + 1].idx : min(lines.count, h.idx + 400)
            let bodyLines = (h.idx + 1..<end).compactMap { idx -> String? in
                let l = lines[idx]
                let ns = l as NSString
                if underlineRegex?.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) != nil { return nil }
                return l
            }
            let body = String(bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(20000))
            return ChangelogParsed(version: h.version, title: h.title, date: h.date, body: body)
        }
    }

    public static func parseVersionFile(path: String, text: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "package.json" || name == "composer.json" {
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let v = obj["version"] as? String {
                return v
            }
            return nil
        }
        if name == "cargo.toml" || name == "pyproject.toml" {
            if let regex = try? NSRegularExpression(pattern: #"^\s*version\s*=\s*["']([^"']+)["']"#, options: .anchorsMatchLines) {
                let ns = text as NSString
                if let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    return ns.substring(with: m.range(at: 1))
                }
            }
            return nil
        }
        if name == "pubspec.yaml" {
            if let regex = try? NSRegularExpression(pattern: #"^version:\s*["']?([^\s"'#]+)"#, options: .anchorsMatchLines) {
                let ns = text as NSString
                if let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    return ns.substring(with: m.range(at: 1))
                }
            }
            return nil
        }
        if name == "setup.cfg" {
            if let regex = try? NSRegularExpression(pattern: #"^version\s*=\s*([^\s#]+)"#, options: .anchorsMatchLines) {
                let ns = text as NSString
                if let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    return ns.substring(with: m.range(at: 1))
                }
            }
            return nil
        }
        if name == "version" || name == "version.txt" {
            let first = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if first.range(of: #"^v?\d+(\.\d+)*"#, options: .regularExpression) != nil {
                return String(first.prefix(64))
            }
            return nil
        }
        return nil
    }
}
