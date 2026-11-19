import Foundation

public enum PrePart: Equatable, Sendable {
    case number(Int)
    case text(String)
}

public struct ParsedVersion: Equatable, Sendable {
    public let nums: [Int]
    public let pre: [PrePart]?
    public let raw: String
}

public enum VersionUtils {
    private static let preOrder: [String: Int] = [
        "dev": 0, "nightly": 0, "canary": 0,
        "a": 1, "alpha": 1,
        "b": 2, "beta": 2,
        "pre": 3, "preview": 3,
        "rc": 4,
    ]

    public static func parseVersion(_ input: String) -> ParsedVersion? {
        let pattern = #"(\d+(?:\.\d+)*)(?:[-_.+]?((?:alpha|beta|rc|pre|preview|dev|canary|nightly|a|b)[.\-_]?\d*(?:[.\-][0-9A-Za-z]+)*))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = input as NSString
        guard let match = regex.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let numsStr = ns.substring(with: match.range(at: 1))
        let nums = numsStr.split(separator: ".").compactMap { Int($0) }
        guard !nums.isEmpty else { return nil }

        var preParts: [PrePart]? = nil
        if match.range(at: 2).location != NSNotFound {
            let preStr = ns.substring(with: match.range(at: 2)).lowercased()
            var parts: [PrePart] = []
            // Split on separators and letter/digit boundaries
            let tokenRegex = try? NSRegularExpression(pattern: #"[a-z]+|\d+"#)
            let pns = preStr as NSString
            let matches = tokenRegex?.matches(in: preStr, range: NSRange(location: 0, length: pns.length)) ?? []
            for m in matches {
                let tok = pns.substring(with: m.range)
                if let n = Int(tok) {
                    parts.append(.number(n))
                } else {
                    parts.append(.text(tok))
                }
            }
            if !parts.isEmpty { preParts = parts }
        }
        return ParsedVersion(nums: nums, pre: preParts, raw: input)
    }

    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = parseVersion(a)
        let pb = parseVersion(b)
        switch (pa, pb) {
        case (nil, nil):
            let ord = a.localizedStandardCompare(b)
            return ord == .orderedAscending ? -1 : (ord == .orderedDescending ? 1 : 0)
        case (nil, _): return -1
        case (_, nil): return 1
        case let (va?, vb?):
            let len = max(va.nums.count, vb.nums.count)
            for i in 0..<len {
                let x = i < va.nums.count ? va.nums[i] : 0
                let y = i < vb.nums.count ? vb.nums[i] : 0
                if x != y { return x - y }
            }
            switch (va.pre, vb.pre) {
            case (nil, nil): return 0
            case (nil, _): return 1
            case (_, nil): return -1
            case let (preA?, preB?):
                let l = max(preA.count, preB.count)
                for i in 0..<l {
                    if i >= preA.count { return -1 }
                    if i >= preB.count { return 1 }
                    switch (preA[i], preB[i]) {
                    case let (.number(x), .number(y)):
                        if x != y { return x - y }
                    case let (.text(x), .text(y)):
                        let ox = preOrder[x] ?? 5
                        let oy = preOrder[y] ?? 5
                        if ox != oy { return ox - oy }
                        if x != y { return x < y ? -1 : 1 }
                    case (.number, .text):
                        return -1
                    case (.text, .number):
                        return 1
                    }
                }
                return 0
            }
        }
    }

    public static func isPrerelease(_ v: String) -> Bool {
        parseVersion(v)?.pre != nil
    }

    public static func selectLatestTag(_ tags: [TagItem]) -> TagItem? {
        guard !tags.isEmpty else { return nil }
        if tags.allSatisfy({ ($0.commitDate?.timeIntervalSince1970 ?? 0) > 0 }) {
            return tags.max(by: { ($0.commitDate ?? .distantPast) < ($1.commitDate ?? .distantPast) })
        }
        func family(_ name: String) -> String? {
            if name.range(of: #"\d{4}[-/.]\d{1,2}[-/.]\d{1,2}"#, options: .regularExpression) != nil { return nil }
            guard parseVersion(name) != nil else { return nil }
            guard let digitIdx = name.firstIndex(where: { $0.isNumber }) else { return nil }
            let prefix = String(name[..<digitIdx]).lowercased()
            return prefix == "v" ? "" : prefix
        }
        let families = tags.map { family($0.name) }
        if families.contains(nil) { return nil }
        let unique = Set(families.compactMap { $0 })
        guard unique.count == 1 else { return nil }
        return tags.max(by: { compareVersions($0.name, $1.name) < 0 })
    }

    public static func computeStatus(
        accessible: Bool,
        isArchived: Bool,
        synced: Bool,
        releaseCount: Int,
        softwareAssetCount: Int,
        tagCount: Int,
        commitCount: Int,
        trackedFileCount: Int,
        lastActivityAt: Date?,
        staleDays: Int,
        now: Date = Date()
    ) -> RepoStatus {
        if !accessible { return .inaccessible }
        if !synced { return .pending }
        if isArchived { return .archived }
        if let last = lastActivityAt, now.timeIntervalSince(last) > Double(staleDays) * 86400.0 {
            return .stale
        }
        if releaseCount > 0 {
            return softwareAssetCount > 0 ? .releaseWithAssets : .releaseNoAssets
        }
        if tagCount > 0 { return .tagsOnly }
        if commitCount > 0 { return .commitsOnly }
        if trackedFileCount > 0 { return .sourceOnly }
        return .empty
    }
}
