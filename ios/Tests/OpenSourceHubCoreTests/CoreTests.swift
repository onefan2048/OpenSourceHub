import XCTest
@testable import OpenSourceHubCore

final class CoreTests: XCTestCase {
    func testRepoParser() {
        XCTAssertEqual(RepoParser.parse("owner/repo"), .ok(RepoRef(provider: "github", owner: "owner", name: "repo")))
        XCTAssertEqual(RepoParser.parse("https://github.com/GopeedLab/gopeed/releases"), .ok(RepoRef(provider: "github", owner: "GopeedLab", name: "gopeed")))
        XCTAssertEqual(RepoParser.parse("git@github.com:karpathy/nanoGPT.git"), .ok(RepoRef(provider: "github", owner: "karpathy", name: "nanoGPT")))
        XCTAssertEqual(RepoParser.parse("github.com/apple/swift"), .ok(RepoRef(provider: "github", owner: "apple", name: "swift")))
        if case .error = RepoParser.parse("https://gitlab.com/a/b") {} else { XCTFail("Expected error for gitlab") }

        let batch = RepoParser.splitBatchInput("owner/a\nowner/b, owner/a; https://github.com/c/d")
        XCTAssertEqual(batch, ["owner/a", "owner/b", "https://github.com/c/d"])
    }

    func testAssetClassifier() {
        let ipa = AssetClassifier.classify(name: "OpenSourceHub-1.0.0-arm64.ipa")
        XCTAssertEqual(ipa.platform, .ios)
        XCTAssertEqual(ipa.arch, .arm64)
        XCTAssertEqual(ipa.fileType, "ipa")
        XCTAssertEqual(ipa.kind, .installer)

        let dmg = AssetClassifier.classify(name: "App-2.1.0-universal.dmg")
        XCTAssertEqual(dmg.platform, .macos)
        XCTAssertEqual(dmg.arch, .universal)
        XCTAssertEqual(dmg.kind, .installer)

        let sha = AssetClassifier.classify(name: "SHA256SUMS.txt")
        XCTAssertEqual(sha.kind, .metadata)

        let digest = AssetClassifier.parseDigest("sha256:" + String(repeating: "a", count: 64))
        XCTAssertEqual(digest, String(repeating: "a", count: 64))
        XCTAssertNil(AssetClassifier.parseDigest("sha256:short"))
        XCTAssertEqual(AssetClassifier.formatBytes(1_572_864), "1.5 MB")
    }

    func testVersionUtils() {
        XCTAssertGreaterThan(VersionUtils.compareVersions("v2.0.0", "v1.9.9"), 0)
        XCTAssertGreaterThan(VersionUtils.compareVersions("1.0.0", "1.0.0-rc.1"), 0)
        XCTAssertGreaterThan(VersionUtils.compareVersions("1.0.0-rc.1", "1.0.0-beta.2"), 0)
        XCTAssertTrue(VersionUtils.isPrerelease("v1.2.0-beta.1"))
        XCTAssertFalse(VersionUtils.isPrerelease("v1.2.0"))
    }

    func testChangelogParser() {
        let md = """
        # Changelog
        ## [Unreleased]
        - wip
        ## [1.2.0] - 2026-05-01
        - Added iOS support
        ## v1.1.0 (2026-04-01)
        - Initial release
        """
        let entries = ChangelogParser.parseChangelog(md)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].version, "1.2.0")
        XCTAssertEqual(entries[0].date, "2026-05-01")
        XCTAssertEqual(entries[1].version, "1.1.0")

        XCTAssertEqual(ChangelogParser.parseVersionFile(path: "package.json", text: #"{"version":"3.4.5"}"#), "3.4.5")
        XCTAssertEqual(ChangelogParser.parseVersionFile(path: "Cargo.toml", text: "[package]\nversion = \"0.9.1\"\n"), "0.9.1")
    }

    func testSQLiteStoreCRUDAndBackup() throws {
        let tmpPath = NSTemporaryDirectory() + "osh-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let store = try SQLiteStore(path: tmpPath)
        let catId = store.createCategory(name: "开发工具")
        XCTAssertEqual(store.listCategories().count, 1)

        guard case let .ok(ref) = RepoParser.parse("GopeedLab/gopeed") else { return XCTFail() }
        let added = store.addRepository(ref, categoryId: catId)
        XCTAssertNotNil(added)
        XCTAssertTrue(added!.created)

        let repoId = added!.repo.id
        let (relId, relInserted) = store.upsertRelease(ReleaseItem(
            id: 0, repositoryId: repoId, providerId: "1001", tagName: "v1.6.0",
            name: "v1.6.0", body: "Notes", isPrerelease: false, isDraft: false, isLatest: true,
            publishedAt: Date(), htmlUrl: "https://github.com/GopeedLab/gopeed/releases/tag/v1.6.0",
            zipballUrl: nil, tarballUrl: nil, authorLogin: "monkeyWie", assetCount: 1
        ))
        XCTAssertTrue(relInserted)

        let assetInserted = store.upsertAsset(AssetItem(
            id: 0, repositoryId: repoId, releaseId: relId, providerId: "2001",
            name: "Gopeed-v1.6.0-ios.ipa", label: nil, contentType: nil, size: 12_000_000,
            downloadCount: 42, downloadUrl: "https://example.com/app.ipa", sha256: nil,
            platform: "ios", arch: "arm64", fileType: "ipa", kind: "installer", confidence: "high", createdAtRemote: Date()
        ))
        XCTAssertTrue(assetInserted)

        let iosAssets = store.listAssets(platform: "ios", softwareOnly: true)
        XCTAssertEqual(iosAssets.count, 1)
        XCTAssertEqual(iosAssets[0].repoFullName, "GopeedLab/gopeed")

        // ETag cache
        store.setHttpCache(HttpCacheEntry(key: "https://api.github.com/repos/a/b", etag: "W/\"123\"", lastModified: nil, body: "{}", linkHeader: nil, updatedAt: Date()))
        XCTAssertEqual(store.getHttpCache(key: "https://api.github.com/repos/a/b")?.etag, "W/\"123\"")

        // Backup & restore into fresh DB
        let backup = try store.exportBackupJSON()
        let tmpPath2 = NSTemporaryDirectory() + "osh-test2-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmpPath2) }
        let store2 = try SQLiteStore(path: tmpPath2)
        let importedCount = try store2.importBackupJSON(backup)
        XCTAssertEqual(importedCount, 1)
        XCTAssertEqual(store2.listRepositories().first?.fullName, "GopeedLab/gopeed")
        XCTAssertEqual(store2.listCategories().first?.name, "开发工具")
    }
}
