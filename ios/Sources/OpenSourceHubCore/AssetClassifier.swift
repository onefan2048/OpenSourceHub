import Foundation

public struct AssetClassification: Equatable, Sendable {
    public let platform: Platform
    public let arch: Arch
    public let fileType: String
    public let kind: AssetKind
    public let confidence: String
}

public enum AssetClassifier {
    private static let multiExts = ["tar.gz", "tar.xz", "tar.bz2", "tar.zst", "app.zip", "app.tar.gz", "pkg.tar.zst"]

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func getFileType(_ name: String) -> String {
        let lower = name.lowercased()
        for ext in multiExts {
            if lower.hasSuffix(".\(ext)") {
                return ext == "app.tar.gz" ? "tar.gz" : ext
            }
        }
        if lower.hasSuffix(".tgz") { return "tar.gz" }
        if lower.hasSuffix(".appimage") { return "AppImage" }
        guard let dotRange = lower.range(of: ".", options: .backwards) else { return "binary" }
        let ext = String(lower[dotRange.upperBound...])
        if ext.isEmpty || ext.count > 10 { return "binary" }
        if !ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return "binary" }
        if ext.allSatisfy({ $0.isNumber }) { return "binary" }
        return ext
    }

    public static func detectArch(_ name: String) -> Arch {
        let n = name.lowercased()
        if matches(#"universal|univ(?![a-z])|fat(?![a-z])"#, in: n) { return .universal }
        if matches(#"(arm64|aarch64|armv8|apple[-_]?silicon|m1)(?![a-z0-9])"#, in: n) { return .arm64 }
        if matches(#"(x86[-_]64|amd64|x64|win64|64[-_]?bit)(?![a-z0-9])"#, in: n) { return .x64 }
        if matches(#"(armv7|armhf|armeabi|arm32|armv6)"#, in: n) { return .armv7 }
        if n.contains("riscv64") { return .riscv64 }
        if matches(#"(i[3-6]86|x86|win32|ia32|32[-_]?bit|386)(?![a-z0-9])"#, in: n) { return .x86 }
        return .unknown
    }

    private static func detectPlatformByKeyword(_ name: String) -> Platform? {
        let n = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        if n.contains("android") { return .android }
        if matches(#"(^|\s)(ios|iphone|ipados)(\s|$)"#, in: n) { return .ios }
        if matches(#"(mac|macos|osx|darwin|apple(?!-?tv))"#, in: n) { return .macos }
        if matches(#"(^|\s)(win|windows|win32|win64|msvc|mingw|pc)(\s|$)"#, in: n) || n.contains("windows") { return .windows }
        if matches(#"(linux|ubuntu|debian|fedora|centos|el[789]|musl|gnu|appimage|flatpak|snap)(?![a-z])"#, in: n) { return .linux }
        return nil
    }

    public static func classify(name: String, contentType: String? = nil) -> AssetClassification {
        let fileType = getFileType(name)
        let ct = (contentType ?? "").lowercased()
        let arch = detectArch(name)
        let kw = detectPlatformByKeyword(name)

        if matches(#"\.(sha256|sha256sum|sha512|sha1|md5|sig|asc|pem|crt|minisig|sbom|spdx|intoto\.jsonl|blockmap|json|ya?ml|txt|sum)$"#, in: name) ||
            matches(#"(checksums?|sha256sums?|sbom|provenance|latest(-mac|-linux)?\.ya?ml)"#, in: name) {
            return AssetClassification(platform: kw ?? .unknown, arch: arch, fileType: fileType, kind: .metadata, confidence: "medium")
        }

        func r(_ p: Platform, _ k: AssetKind, _ c: String) -> AssetClassification {
            AssetClassification(platform: p, arch: arch, fileType: fileType, kind: k, confidence: c)
        }

        switch fileType {
        case "dmg", "pkg": return r(.macos, .installer, "high")
        case "app.zip": return r(.macos, .archive, "high")
        case "app": return r(.macos, .package, "medium")
        case "exe":
            let high = ct.contains("msdownload") || ct.contains("dosexec") || ct.isEmpty || ct.contains("octet")
            return r(.windows, .installer, high ? "high" : "medium")
        case "msi", "msix", "appx": return r(.windows, .installer, "high")
        case "deb", "rpm": return r(.linux, .installer, "high")
        case "AppImage", "flatpak", "snap", "pkg.tar.zst": return r(.linux, .package, "high")
        case "ipa": return r(.ios, .installer, "high")
        case "apk": return r(.android, .installer, "high")
        case "aab": return r(.android, .package, "high")
        case "jar", "vsix": return r(.cross, .package, "medium")
        case "whl": return r(kw ?? .cross, .package, "medium")
        case "nupkg": return r(.windows, .package, "medium")
        case "zip", "7z", "rar", "tar.gz", "tar.xz", "tar.bz2", "tar.zst", "gz", "xz", "bz2", "zst":
            return r(kw ?? .unknown, .archive, kw != nil ? "medium" : "low")
        case "binary":
            if kw != nil || ct.contains("octet-stream") || ct.contains("executable") {
                return r(kw ?? .unknown, .binary, kw != nil ? "medium" : "low")
            }
            return r(.unknown, .other, "low")
        default:
            return r(kw ?? .unknown, .other, "low")
        }
    }

    /// GitHub digest format: "sha256:<64 hex chars>"
    public static func parseDigest(_ digest: String?) -> String? {
        guard let digest = digest else { return nil }
        let lower = digest.lowercased()
        guard lower.hasPrefix("sha256:") else { return nil }
        let hex = String(lower.dropFirst(7))
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return hex
    }

    public static func formatBytes(_ n: Int64) -> String {
        if n <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var val = Double(n)
        var idx = 0
        while val >= 1024.0 && idx < units.count - 1 {
            val /= 1024.0
            idx += 1
        }
        return idx == 0 ? "\(Int(val)) B" : String(format: "%.1f %@", val, units[idx])
    }
}
