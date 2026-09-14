import Darwin
import XCTest
@testable import puremac

final class AnalyzeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-analyze-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testDepthValidationUsesDocumentedBounds() throws {
        var analyze = Analyze()
        analyze.depth = 1
        XCTAssertNoThrow(try analyze.validate())
        analyze.depth = 8
        XCTAssertNoThrow(try analyze.validate())
        analyze.depth = 0
        XCTAssertThrowsError(try analyze.validate())
        analyze.depth = 9
        XCTAssertThrowsError(try analyze.validate())
    }

    func testDepthAndPlainModesDisableFullscreenBrowser() {
        XCTAssertTrue(Analyze.usesInteractiveBrowser(plain: false, depth: 1, terminalSupported: true))
        XCTAssertFalse(Analyze.usesInteractiveBrowser(plain: true, depth: 1, terminalSupported: true))
        XCTAssertFalse(Analyze.usesInteractiveBrowser(plain: false, depth: 2, terminalSupported: true))
        XCTAssertFalse(Analyze.usesInteractiveBrowser(plain: false, depth: 1, terminalSupported: false))
    }

    func testScanRanksAllocatedSizesAndMeasuresPackageWithoutDrilldown() throws {
        let small = root.appendingPathComponent("small.bin")
        let package = root.appendingPathComponent("Example.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8_192).write(to: small)
        try Data(repeating: 0x42, count: 1_000_000).write(to: contents.appendingPathComponent("payload.bin"))

        let snapshot = Analyze().scanFolder(root.path)

        XCTAssertEqual(snapshot.children.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["Example.app", "small.bin"])
        let packageChild = try XCTUnwrap(snapshot.children.first)
        XCTAssertTrue(packageChild.isDir)
        XCTAssertTrue(packageChild.isPackage)
        XCTAssertGreaterThan(packageChild.size, 0)
    }

    func testScanSkipsIgnoredAndSymbolicLinkedEntries() throws {
        let visible = root.appendingPathComponent("visible.bin")
        let ignored = root.appendingPathComponent("ignored.bin")
        let link = root.appendingPathComponent("linked.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: visible)
        try Data(repeating: 0x42, count: 4_096).write(to: ignored)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: visible)

        let ignoreFile = root.appendingPathComponent("ignore-config")
        try (ignored.path + "\n").write(to: ignoreFile, atomically: true, encoding: .utf8)
        let ignore = try IgnoreStore(fileURL: ignoreFile)
        let snapshot = Analyze().scanFolder(root.path, ignore: ignore)

        XCTAssertEqual(snapshot.children.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["ignore-config", "visible.bin"])
        XCTAssertEqual(snapshot.skippedCount, 2)
        XCTAssertTrue(snapshot.isPartial)
    }

    func testUnreadableChildIsReportedAsPartialOrInaccessible() throws {
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 4_096).write(to: locked.appendingPathComponent("private.bin"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, S_IRWXU) }

        let snapshot = Analyze().scanFolder(root.path)

        XCTAssertTrue(snapshot.isPartial)
        XCTAssertGreaterThan(snapshot.skippedCount + snapshot.inaccessibleCount, 0)
        XCTAssertFalse(snapshot.errors.isEmpty)
    }

    func testViewportKeepsSelectionVisibleAndWithinHeight() {
        let children = (0..<20).map {
            Analyze.Child(
                path: "/tmp/item-\($0)",
                size: Int64(20 - $0) * 1_024,
                isDir: true,
                isPackage: false,
                inaccessibleCount: 0,
                skippedCount: 0
            )
        }
        let snapshot = Analyze.FolderSnapshot(
            path: "/tmp",
            children: children,
            total: children.reduce(Int64(0)) { $0 + $1.size },
            inaccessibleCount: 0,
            skippedCount: 0,
            errors: []
        )
        let visible = Analyze.visibleRowCount(snapshot: snapshot, selected: 17, width: 60, height: 14)
        let offset = Analyze.adjustedOffset(0, selected: 17, count: children.count, visibleRows: visible)
        let level = Analyze.BrowserLevel(snapshot: snapshot, selected: 17, offset: offset)
        let lines = Analyze.browserLines(level: level, width: 60, height: 14)

        XCTAssertGreaterThan(offset, 0)
        XCTAssertLessThanOrEqual(lines.count, 14)
        XCTAssertTrue(lines.joined(separator: "\n").contains("item-17"))
    }

    func testFocusedPathWrappingPreservesEveryCharacter() {
        let path = "/Users/example/a folder/with/a/very-long-name/file.bin"
        let lines = Analyze.wrap(path, width: 11)

        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.joined(), path)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) <= 11 })
    }

    func testNarrowBrowserRenderStaysWithinViewport() {
        let path = "/Users/example/a folder/with/a/very-long-name/file.bin"
        let child = Analyze.Child(
            path: path,
            size: 8_192,
            isDir: false,
            isPackage: false,
            inaccessibleCount: 0,
            skippedCount: 0
        )
        let snapshot = Analyze.FolderSnapshot(
            path: "/Users/example/a folder",
            children: [child],
            total: child.size,
            inaccessibleCount: 0,
            skippedCount: 0,
            errors: []
        )
        let lines = Analyze.browserLines(
            level: Analyze.BrowserLevel(snapshot: snapshot),
            width: 40,
            height: 12
        )

        XCTAssertLessThanOrEqual(lines.count, 12)
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) <= 40 })
        XCTAssertTrue(lines.joined(separator: "\n").contains("O reveal"))
        XCTAssertTrue(lines.joined(separator: "\n").contains("q/Esc exit"))

        let tooSmall = Analyze.browserLines(
            level: Analyze.BrowserLevel(snapshot: snapshot),
            width: 39,
            height: 11
        )
        XCTAssertTrue(tooSmall.contains { $0.contains("Terminal too small") })
        XCTAssertTrue(tooSmall.allSatisfy { Term.displayWidth($0) <= 39 })
    }
}
