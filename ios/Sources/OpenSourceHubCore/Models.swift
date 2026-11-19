import Foundation

// MARK: - Enums & Labels

public enum Platform: String, Codable, CaseIterable, Sendable {
    case macos, windows, linux, ios, android, cross, unknown

    public var label: String {
        switch self {
        case .macos: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        case .ios: return "iOS"
        case .android: return "Android"
        case .cross: return "跨平台"
        case .unknown: return "其他"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .macos: return "laptopcomputer"
        case .windows: return "pc"
        case .linux: return "terminal"
        case .ios: return "iphone"
        case .android: return "candybarphone"
        case .cross: return "globe"
        case .unknown: return "doc"
        }
    }
}

public enum Arch: String, Codable, CaseIterable, Sendable {
    case arm64, x64, x86, universal, armv7, riscv64, unknown

    public var label: String {
        switch self {
        case .arm64: return "ARM64"
        case .x64: return "x64"
        case .x86: return "x86"
        case .universal: return "Universal"
        case .armv7: return "ARMv7"
        case .riscv64: return "RISC-V"
        case .unknown: return "未知架构"
        }
    }
}

public enum AssetKind: String, Codable, CaseIterable, Sendable {
    case installer, package, archive, binary, metadata, other

    public var label: String {
        switch self {
        case .installer: return "安装包"
        case .package: return "软件包"
        case .archive: return "压缩包"
        case .binary: return "二进制"
        case .metadata: return "校验/元数据"
        case .other: return "其他文件"
        }
    }

    public var isSoftware: Bool {
        switch self {
        case .installer, .package, .archive, .binary: return true
        case .metadata, .other: return false
        }
    }
}

public enum RepoStatus: String, Codable, Sendable {
    case pending
    case releaseWithAssets = "release_with_assets"
    case releaseNoAssets = "release_no_assets"
    case tagsOnly = "tags_only"
    case commitsOnly = "commits_only"
    case sourceOnly = "source_only"
    case stale
    case archived
    case inaccessible
    case empty

    public var label: String {
        switch self {
        case .pending: return "等待首次同步"
        case .releaseWithAssets: return "有正式 Release 和安装包"
        case .releaseNoAssets: return "有 Release，无独立安装包"
        case .tagsOnly: return "只有 Git Tags"
        case .commitsOnly: return "只有 Commit 更新"
        case .sourceOnly: return "只有源码文件变化"
        case .stale: return "长期没有更新"
        case .archived: return "仓库已归档"
        case .inaccessible: return "仓库不可访问"
        case .empty: return "空仓库"
        }
    }
}

// MARK: - Core Data Models

public struct CategoryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var parentId: Int64?
    public var sortOrder: Int
    public var repoCount: Int = 0

    public init(id: Int64 = 0, name: String, parentId: Int64? = nil, sortOrder: Int = 0, repoCount: Int = 0) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.repoCount = repoCount
    }
}

public struct RepositoryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var provider: String
    public var providerRepoId: String?
    public var owner: String
    public var name: String
    public var fullName: String
    public var fullNameKey: String
    public var description: String?
    public var homepage: String?
    public var htmlUrl: String
    public var avatarUrl: String?
    public var logoUrl: String?
    public var stars: Int
    public var forks: Int
    public var watchers: Int
    public var license: String?
    public var language: String?
    public var topics: [String]
    public var defaultBranch: String?
    public var isArchived: Bool
    public var isFork: Bool
    public var pushedAt: Date?
    public var hasReleases: Bool
    public var hasTags: Bool
    public var hasAssets: Bool
    public var platforms: [String]
    public var fileTypes: [String]
    public var status: String
    public var accessible: Bool
    public var lastError: String?
    public var headSha: String?
    public var latestVersion: String?
    public var latestVersionSource: String?
    public var latestVersionAt: Date?
    public var latestActivityAt: Date?
    public var readme: String?
    public var readmeSha: String?
    public var watchedFiles: [String]
    public var pollIntervalMinutes: Int?
    public var paused: Bool
    public var baselineEstablished: Bool
    public var baselineAt: Date?
    public var notifyEnabled: Bool
    public var notifyRelease: Bool
    public var notifyPrerelease: Bool
    public var notifyTag: Bool
    public var notifyCommit: Bool
    public var notifyChangelog: Bool
    public var lastSyncedAt: Date?
    public var lastSyncStatus: String?
    public var lastSyncDurationMs: Int?
    public var nextSyncAt: Date?
    public var consecutiveFailures: Int
    public var categoryId: Int64?
    public var addedAt: Date
    public var updatedAt: Date

    public var repoStatus: RepoStatus {
        RepoStatus(rawValue: status) ?? .pending
    }
}

public struct ReleaseItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var providerId: String
    public var tagName: String
    public var name: String?
    public var body: String?
    public var isPrerelease: Bool
    public var isDraft: Bool
    public var isLatest: Bool
    public var publishedAt: Date?
    public var htmlUrl: String
    public var zipballUrl: String?
    public var tarballUrl: String?
    public var authorLogin: String?
    public var assetCount: Int

    public init(id: Int64, repositoryId: Int64, providerId: String, tagName: String, name: String?, body: String?, isPrerelease: Bool, isDraft: Bool, isLatest: Bool, publishedAt: Date?, htmlUrl: String, zipballUrl: String?, tarballUrl: String?, authorLogin: String?, assetCount: Int) {
        self.id = id; self.repositoryId = repositoryId; self.providerId = providerId; self.tagName = tagName; self.name = name
        self.body = body; self.isPrerelease = isPrerelease; self.isDraft = isDraft; self.isLatest = isLatest
        self.publishedAt = publishedAt; self.htmlUrl = htmlUrl; self.zipballUrl = zipballUrl; self.tarballUrl = tarballUrl
        self.authorLogin = authorLogin; self.assetCount = assetCount
    }
}

public struct AssetItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var releaseId: Int64
    public var providerId: String
    public var name: String
    public var label: String?
    public var contentType: String?
    public var size: Int64
    public var downloadCount: Int
    public var downloadUrl: String
    public var sha256: String?
    public var platform: String
    public var arch: String
    public var fileType: String
    public var kind: String
    public var confidence: String
    public var createdAtRemote: Date?
    // Joined optional metadata for Discover view
    public var repoFullName: String?
    public var releaseTag: String?

    public init(id: Int64, repositoryId: Int64, releaseId: Int64, providerId: String, name: String, label: String?, contentType: String?, size: Int64, downloadCount: Int, downloadUrl: String, sha256: String?, platform: String, arch: String, fileType: String, kind: String, confidence: String, createdAtRemote: Date?, repoFullName: String? = nil, releaseTag: String? = nil) {
        self.id = id; self.repositoryId = repositoryId; self.releaseId = releaseId; self.providerId = providerId; self.name = name
        self.label = label; self.contentType = contentType; self.size = size; self.downloadCount = downloadCount
        self.downloadUrl = downloadUrl; self.sha256 = sha256; self.platform = platform; self.arch = arch
        self.fileType = fileType; self.kind = kind; self.confidence = confidence; self.createdAtRemote = createdAtRemote
        self.repoFullName = repoFullName; self.releaseTag = releaseTag
    }

    public var platformEnum: Platform { Platform(rawValue: platform) ?? .unknown }
    public var archEnum: Arch { Arch(rawValue: arch) ?? .unknown }
    public var kindEnum: AssetKind { AssetKind(rawValue: kind) ?? .other }
}

public struct TagItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var name: String
    public var commitSha: String
    public var commitDate: Date?
    public var zipballUrl: String?
    public var tarballUrl: String?
}

public struct CommitItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var sha: String
    public var shortSha: String
    public var message: String
    public var authorName: String?
    public var authorLogin: String?
    public var committedAt: Date?
    public var htmlUrl: String
    public var branch: String?
}

public struct ChangelogEntryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var filePath: String
    public var version: String
    public var title: String
    public var body: String?
    public var entryDate: String?
}

public struct TrackedFileItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var path: String
    public var kind: String
    public var lastSha: String?
    public var lastVersion: String?
    public var lastCheckedAt: Date?
    public var lastChangedAt: Date?
}

public struct VersionEventItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var sourceType: String
    public var eventType: String
    public var sourceKey: String
    public var version: String?
    public var title: String
    public var url: String?
    public var occurredAt: Date?
    public var isBaseline: Bool
    public var detectedAt: Date
}

public struct SyncLogItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var trigger: String
    public var mode: String
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var durationMs: Int
    public var requestCount: Int
    public var notModifiedCount: Int
    public var newReleases: Int
    public var newTags: Int
    public var newCommits: Int
    public var newAssets: Int
    public var newChangelog: Int
    public var summary: String?
    public var error: String?
    public var rateLimitRemaining: Int?
}

public struct NotificationItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var repoFullName: String?
    public var versionEventId: Int64?
    public var channel: String
    public var title: String
    public var body: String?
    public var url: String?
    public var status: String
    public var error: String?
    public var readAt: Date?
    public var createdAt: Date
}

public struct IssueItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var number: Int
    public var title: String
    public var state: String
    public var authorLogin: String?
    public var labels: [LabelBadge]
    public var comments: Int
    public var htmlUrl: String
    public var body: String?
    public var createdAtRemote: Date
    public var updatedAtRemote: Date
}

public struct DiscussionItem: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var repositoryId: Int64
    public var number: Int
    public var title: String
    public var authorLogin: String?
    public var categoryName: String?
    public var categoryEmoji: String?
    public var isAnswered: Bool
    public var closed: Bool
    public var upvotes: Int
    public var comments: Int
    public var htmlUrl: String
    public var body: String?
    public var createdAtRemote: Date
    public var updatedAtRemote: Date
}

public struct LabelBadge: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var color: String?

    public init(name: String, color: String? = nil) {
        self.name = name
        self.color = color
    }
}

public struct HttpCacheEntry: Sendable {
    public var key: String
    public var etag: String?
    public var lastModified: String?
    public var body: String
    public var linkHeader: String?
    public var updatedAt: Date

    public init(key: String, etag: String?, lastModified: String?, body: String, linkHeader: String?, updatedAt: Date) {
        self.key = key; self.etag = etag; self.lastModified = lastModified; self.body = body; self.linkHeader = linkHeader; self.updatedAt = updatedAt
    }
}

public struct RateLimitInfo: Equatable, Sendable {
    public var limit: Int?
    public var remaining: Int?
    public var resetAt: Date?

    public init(limit: Int? = nil, remaining: Int? = nil, resetAt: Date? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

public struct HubStats: Equatable, Sendable {
    public var totalRepos: Int
    public var syncedRepos: Int
    public var totalSoftwareAssets: Int
    public var unreadNotifications: Int
    public var databaseBytes: Int64
    public var cacheBytes: Int64

    public static let empty = HubStats(totalRepos: 0, syncedRepos: 0, totalSoftwareAssets: 0, unreadNotifications: 0, databaseBytes: 0, cacheBytes: 0)
}

public struct SyncResult: Sendable {
    public var ok: Bool
    public var status: String // success | failed | partial
    public var newReleases: Int = 0
    public var newTags: Int = 0
    public var newCommits: Int = 0
    public var newAssets: Int = 0
    public var newChangelog: Int = 0
    public var requestCount: Int = 0
    public var notModifiedCount: Int = 0
    public var durationMs: Int = 0
    public var errors: [String] = []
    public var summary: String = ""
}

// MARK: - Settings Defaults

public enum HubSettings {
    public static let pollIntervals: [Int] = [5, 15, 30, 60, 360, 720, 1440]

    public static let defaults: [String: String] = [
        "poll.defaultIntervalMinutes": "15",
        "sync.initialCommitCount": "30",
        "sync.maxReleasePages": "10",
        "sync.maxTagPages": "5",
        "sync.tagDateBackfillPerSync": "5",
        "sync.staleDays": "365",
        "github.token": "",
        "notify.local.enabled": "true",
        "notify.telegram.botToken": "",
        "notify.telegram.chatId": "",
        "notify.discord.webhookUrl": "",
        "notify.wecom.webhookUrl": "",
        "notify.feishu.webhookUrl": "",
        "notify.feishu.secret": "",
        "notify.qq.appId": "",
        "notify.qq.clientSecret": "",
        "notify.qq.groupOpenId": "",
        "notify.webhook.url": "",
    ]
}

// MARK: - Backup Payload

public struct HubBackupPayload: Codable, Sendable {
    public var version: Int = 1
    public var exportedAt: Date
    public var categories: [CategoryItem]
    public var repos: [BackupRepoEntry]
    public var settings: [String: String]

    public struct BackupRepoEntry: Codable, Sendable {
        public var fullName: String
        public var categoryName: String?
        public var pollIntervalMinutes: Int?
        public var paused: Bool
        public var notifyEnabled: Bool
        public var notifyRelease: Bool
        public var notifyPrerelease: Bool
        public var notifyTag: Bool
        public var notifyCommit: Bool
        public var notifyChangelog: Bool
        public var watchedFiles: [String]
    }
}
