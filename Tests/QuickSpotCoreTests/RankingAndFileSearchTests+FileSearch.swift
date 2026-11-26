import Foundation
import XCTest
@testable import QuickSpotCore

extension RankingAndFileSearchTests {
    // MARK: - SpotlightFileSearch & SpotlightQueryBuilder

    @MainActor
    func testSpotlightExclusionPathsAndTurkishSearchVariants() {
        let home = "/Users/tester"

        // iCloud Drive documents must NEVER be excluded
        XCTAssertFalse(
            SpotlightFileSearch.isExcludedPath(
                "\(home)/Library/Mobile Documents/com~apple~CloudDocs/fatura.pdf",
                homeDirectory: home
            )
        )
        XCTAssertFalse(
            SpotlightFileSearch.isExcludedPath(
                "\(home)/Library/Mobile Documents",
                homeDirectory: home
            )
        )
        XCTAssertFalse(
            SpotlightFileSearch.isExcludedPath(
                "\(home)/Desktop/rapor.pdf",
                homeDirectory: home
            )
        )

        // Caches, node_modules, .git, .app bundles, and system Libraries ARE excluded
        XCTAssertTrue(SpotlightFileSearch.isExcludedPath("\(home)/Library/Caches/foo", homeDirectory: home))
        XCTAssertTrue(SpotlightFileSearch.isExcludedPath("\(home)/Projects/app/node_modules/x.js", homeDirectory: home))
        XCTAssertTrue(SpotlightFileSearch.isExcludedPath("\(home)/Projects/app/.git/HEAD", homeDirectory: home))
        XCTAssertTrue(SpotlightFileSearch.isExcludedPath("/Applications/Foo.app", homeDirectory: home))
        XCTAssertTrue(SpotlightFileSearch.isExcludedPath("/Applications/Foo.app/Contents/Info.plist", homeDirectory: home))
        XCTAssertTrue(SpotlightFileSearch.isExcludedPath("/Library/Preferences/com.example.plist", homeDirectory: home))

        // Turkish search variants (ı <-> i)
        let fromAscii = SpotlightFileSearch.turkishSearchVariants(for: "sinav")
        XCTAssertEqual(Set(fromAscii), Set(["sinav", "sınav"]))
        XCTAssertEqual(fromAscii.count, 2)

        let fromDotless = SpotlightFileSearch.turkishSearchVariants(for: "sınav")
        XCTAssertEqual(Set(fromDotless), Set(["sınav", "sinav"]))
        XCTAssertEqual(fromDotless.count, 2)

        XCTAssertEqual(SpotlightFileSearch.turkishSearchVariants(for: "rapor"), ["rapor"])
        XCTAssertEqual(SpotlightFileSearch.turkishSearchVariants(for: ""), [])

        let manyIs = SpotlightFileSearch.turkishSearchVariants(for: "isimsizlik")
        XCTAssertLessThanOrEqual(manyIs.count, 4)
        XCTAssertEqual(Set(manyIs).count, manyIs.count)
        XCTAssertTrue(manyIs.contains("isimsizlik"))
        XCTAssertTrue(manyIs.contains("ısımsızlık"))

        // Path shortening and calibrated content score bounds
        XCTAssertEqual(
            SpotlightQueryBuilder.shortenPath(
                "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Vergi",
                homeDirectory: home
            ),
            "iCloud Drive/Vergi"
        )
        let contentScore = SpotlightQueryBuilder.scoreContentMatch(
            query: "rapor",
            fileName: "notes.txt",
            standardizedPath: "\(home)/Desktop/notes.txt",
            referenceDate: Date(),
            frecencyBoost: 160,
            rankIndex: 0,
            homeDirectory: home
        )
        XCTAssertGreaterThanOrEqual(contentScore, 360)
        XCTAssertLessThanOrEqual(contentScore, 520)
    }

    // MARK: - PathNavigator & RecentFilesProvider

    func testPathNavigatorAndRecentFilesProviderIsolatedTree() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory
            .appendingPathComponent("quickspot-nav-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? fm.removeItem(at: tempHome) }

        let desktop = tempHome.appendingPathComponent("Desktop", isDirectory: true)
        let downloads = tempHome.appendingPathComponent("Downloads", isDirectory: true)
        let projectsApp = tempHome.appendingPathComponent("Projects/MyApp", isDirectory: true)
        let alphaFolder = desktop.appendingPathComponent("AlphaFolder", isDirectory: true)
        let subFolder = desktop.appendingPathComponent("SubFolder", isDirectory: true)

        for dir in [desktop, downloads, projectsApp, alphaFolder, subFolder] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let raporURL = desktop.appendingPathComponent("rapor.pdf")
        let notesURL = desktop.appendingPathComponent("notlar.txt")
        let dotfileURL = desktop.appendingPathComponent(".secret.env")
        let imageURL = downloads.appendingPathComponent("ekran.png")
        let codeURL = projectsApp.appendingPathComponent("index.ts")

        try Data("pdf".utf8).write(to: raporURL)
        try Data("notes".utf8).write(to: notesURL)
        try Data("SECRET=1".utf8).write(to: dotfileURL)
        try Data("png".utf8).write(to: imageURL)
        try Data("export {}".utf8).write(to: codeURL)

        let homePath = tempHome.path

        // 1. Listing directory with trailing `/` shows folders first, then files, hiding dotfiles
        let listing = PathNavigator.search(rawPath: "\(desktop.path)/", limit: 24, homeDirectory: homePath)
        let titles = listing.map(\.title)
        XCTAssertEqual(Array(titles.prefix(2)), ["AlphaFolder", "SubFolder"])
        XCTAssertTrue(titles.contains("rapor.pdf"))
        XCTAssertTrue(titles.contains("notlar.txt"))
        XCTAssertFalse(titles.contains(".secret.env"))
        XCTAssertTrue(listing.allSatisfy { $0.matchSource == .path })

        // 2. Filtering by prefix
        let prefixHits = PathNavigator.search(rawPath: "~/Desktop/rap", limit: 12, homeDirectory: homePath)
        XCTAssertEqual(prefixHits.map(\.title), ["rapor.pdf"])

        // 3. Showing dotfiles when filter term starts with `.`
        let dotHits = PathNavigator.search(rawPath: "~/Desktop/.", limit: 12, homeDirectory: homePath)
        XCTAssertTrue(dotHits.contains { $0.title == ".secret.env" })

        let specificDot = PathNavigator.search(rawPath: "~/Desktop/.sec", limit: 12, homeDirectory: homePath)
        XCTAssertEqual(specificDot.first?.title, ".secret.env")

        // 4. autocompletePath appends `/` for folders and omits `/` for files
        let folderItem = try XCTUnwrap(listing.first { $0.title == "SubFolder" })
        let fileItem = try XCTUnwrap(listing.first { $0.title == "rapor.pdf" })
        XCTAssertEqual(
            PathNavigator.autocompletePath(for: folderItem, homeDirectory: homePath),
            "~/Desktop/SubFolder/"
        )
        XCTAssertEqual(
            PathNavigator.autocompletePath(for: fileItem, homeDirectory: homePath),
            "~/Desktop/rapor.pdf"
        )
        let publicFolderCompletion = try XCTUnwrap(PathNavigator.autocompletePath(for: folderItem))
        let publicFileCompletion = try XCTUnwrap(PathNavigator.autocompletePath(for: fileItem))
        XCTAssertTrue(publicFolderCompletion.hasSuffix("/"))
        XCTAssertFalse(publicFileCompletion.hasSuffix("/"))

        // 4b. Shift+Tab parentDirectoryQuery steps up one folder cleanly
        XCTAssertEqual(
            PathNavigator.parentDirectoryQuery(for: "~/Desktop/SubFolder/", homeDirectory: homePath),
            "~/Desktop/"
        )
        XCTAssertEqual(
            PathNavigator.parentDirectoryQuery(for: "~/Desktop/rap", homeDirectory: homePath),
            "~/Desktop/"
        )
        XCTAssertEqual(
            PathNavigator.parentDirectoryQuery(for: "~/Desktop/", homeDirectory: homePath),
            "~/"
        )
        XCTAssertNil(PathNavigator.parentDirectoryQuery(for: "/", homeDirectory: homePath))
        XCTAssertNil(PathNavigator.parentDirectoryQuery(for: "chrome", homeDirectory: homePath))

        // 5. RecentFilesProvider isolated refresh, recentItems, and searchInstant filters
        let suite = "QuickSpotRecentFiles-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let frecency = FrecencyStore(defaults: defaults)
        frecency.record(id: codeURL.path, query: "index")

        let provider = RecentFilesProvider(frecency: frecency, homeDirectory: homePath)
        provider.refresh()

        let recent = provider.recentItems(limit: 5)
        XCTAssertEqual(recent.first?.title, "index.ts")
        XCTAssertEqual(recent.first?.matchSource, .recent)
        XCTAssertTrue(recent.contains { $0.title == "rapor.pdf" })
        XCTAssertFalse(recent.contains { $0.category == .folder })

        XCTAssertEqual(provider.searchInstant(query: "rapor", filter: .pdfOnly).map(\.title), ["rapor.pdf"])
        XCTAssertEqual(provider.searchInstant(query: "ekran", filter: .imagesOnly).map(\.title), ["ekran.png"])
        XCTAssertEqual(provider.searchInstant(query: "ekran", filter: .pdfOnly), [])
        XCTAssertEqual(provider.searchInstant(query: "Sub", filter: .foldersOnly).map(\.title), ["SubFolder"])
        XCTAssertEqual(provider.searchInstant(query: "rapor", filter: .contentOnly), [])
    }
}
