import XCTest
@testable import puremac

final class TerminalUITests: XCTestCase {
    func testANSIAndUnicodeDisplayWidth() {
        XCTAssertEqual(Term.displayWidth("\u{1B}[31mclean\u{1B}[0m"), 5)
        XCTAssertEqual(Term.displayWidth("界"), 2)
        XCTAssertEqual(Term.displayWidth("a\u{301}"), 1)
    }

    func testTerminalControlCharactersAreSanitized() {
        XCTAssertEqual(Term.sanitize("safe\u{1B}[2Jname\n"), "safe�[2Jname�")
        XCTAssertEqual(Term.sanitize("one\ttwo"), "one two")
    }

    func testMiddleTruncationRespectsVisibleWidth() {
        let value = Term.truncate("/Users/example/Library/Caches/tool", to: 18, middle: true)
        XCTAssertLessThanOrEqual(Term.displayWidth(value), 18)
        XCTAssertTrue(value.contains("…"))
        XCTAssertTrue(value.hasPrefix("/Users/e"))
        XCTAssertTrue(value.hasSuffix("ches/tool"))
    }

    func testReviewStartsWithNothingSelected() {
        let model = InteractiveReviewModel(categories: fixtureCategories())
        XCTAssertEqual(model.selectedCount, 0)
        XCTAssertEqual(model.selectedBytes, 0)
        XCTAssertEqual(model.matchingAddresses.count, 3)
    }

    func testReviewSelectionAndSearchPreserveExactItems() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.toggleFocused()
        model.move(1)
        model.toggleFocused()
        XCTAssertEqual(model.selectedCount, 2)
        XCTAssertEqual(model.selectedBytes, 3_000)

        model.updateQuery("second")
        XCTAssertEqual(model.matchingAddresses.count, 1)
        XCTAssertEqual(model.item(at: model.matchingAddresses[0]).path, "/tmp/second")

        model.selectNone()
        model.selectAllMatching()
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertEqual(model.selectedResult()[0].selectedItems.map(\.path), ["/tmp/second"])
    }

    func testReviewRequiresSelectionBeforeFinalReview() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        XCTAssertFalse(model.beginReview())
        XCTAssertFalse(model.isReviewing)
        XCTAssertFalse(model.status.isEmpty)

        model.toggleFocused()
        XCTAssertTrue(model.beginReview())
        XCTAssertTrue(model.isReviewing)
    }

    func testReviewRenderIsBoundedAndKeepsControlsVisible() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.selectAllMatching()
        for (width, height) in [(40, 12), (58, 14), (80, 24)] {
            let lines = InteractiveReview.render(
                model: model,
                title: "Review removable files",
                width: width,
                height: height
            )

            XCTAssertEqual(lines.count, height)
            XCTAssertTrue(lines.contains { $0.contains("Space toggle") })
            XCTAssertTrue(lines.contains { $0.contains("Enter review") })
            XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) <= width })
        }
    }

    func testReviewHeaderFitsFortyColumnsWithDifferentCountsAndSizes() {
        let categories = [
            CategoryScan(
                id: "cache",
                title: "Caches",
                groups: [
                    ToolGroup(
                        tool: "Applications",
                        items: [
                            ScanItem(path: "/tmp/one", sizeBytes: 138_300, modified: nil),
                            ScanItem(path: "/tmp/two", sizeBytes: 1_000, modified: nil)
                        ]
                    )
                ]
            )
        ]
        let model = InteractiveReviewModel(categories: categories)
        let lines = InteractiveReview.render(
            model: model,
            title: "Review removable files",
            width: 40,
            height: 12
        )

        XCTAssertEqual(Term.displayWidth(lines[2]), 40)
        XCTAssertTrue(lines[2].contains("2 shown"))
        XCTAssertTrue(lines[2].contains("0 selected"))
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) <= 40 })
    }

    func testFinalReviewControlsFitAtMinimumSupportedWidth() {
        var model = InteractiveReviewModel(categories: fixtureCategories())
        model.selectAllMatching()
        XCTAssertTrue(model.beginReview())
        let lines = InteractiveReview.render(
            model: model,
            title: "Review removable files",
            width: 40,
            height: 12
        )
        XCTAssertEqual(lines.count, 12)
        XCTAssertTrue(lines.contains { $0.contains("Enter confirm") })
        XCTAssertTrue(lines.contains { $0.contains("q cancel") })
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) <= 40 })
    }

    func testCompactReviewDoesNotLieAboutTerminalDimensions() {
        let model = InteractiveReviewModel(categories: fixtureCategories())
        let lines = InteractiveReview.render(
            model: model,
            title: "Review",
            width: 18,
            height: 4
        )

        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.contains { $0.contains("too small") })
        XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) <= 18 })
    }

    func testFocusedPathWindowCanRevealEntirePath() {
        let path = "/Users/example/Library/Caches/application/data"
        let first = InteractiveReview.horizontalWindow(path, offset: 0, width: 20)
        let last = InteractiveReview.horizontalWindow(path, offset: 30, width: 20)

        XCTAssertTrue(first.hasSuffix("›"))
        XCTAssertTrue(last.hasPrefix("‹"))
        XCTAssertLessThanOrEqual(Term.displayWidth(first), 20)
        XCTAssertLessThanOrEqual(Term.displayWidth(last), 20)
    }

    func testMenuSelectionClampsAndRenderPaginates() {
        var model = TerminalMenuModel(optionCount: 8)
        model.move(99)
        XCTAssertEqual(model.selection, 7)
        model.move(-99)
        XCTAssertEqual(model.selection, 0)
        XCTAssertEqual(model.select(number: 7), 6)
        XCTAssertEqual(model.selection, 6)
        XCTAssertNil(model.select(number: 9))
        XCTAssertNil(model.select(number: 0))

        let options = (1...8).map { (title: "Tool \($0)", detail: "Description \($0)") }
        for (width, height) in [(40, 12), (80, 24)] {
            let lines = TerminalMenu.render(
                title: "PureMac",
                subtitle: "Choose a task",
                options: options,
                selection: 6,
                width: width,
                height: height
            )
            XCTAssertEqual(lines.count, height)
            XCTAssertTrue(lines.contains { $0.contains("Tool 7") })
            XCTAssertTrue(lines.contains { $0.contains("Enter open") })
            XCTAssertTrue(lines.contains { $0.contains("1-9 open") })
            XCTAssertTrue(lines.allSatisfy { Term.displayWidth($0) <= width })
        }
    }

    private func fixtureCategories() -> [CategoryScan] {
        [
            CategoryScan(
                id: "dev",
                title: "Developer",
                groups: [
                    ToolGroup(
                        tool: "Build caches",
                        items: [
                            ScanItem(path: "/tmp/first", sizeBytes: 1_000, modified: nil, selected: true),
                            ScanItem(path: "/tmp/second", sizeBytes: 2_000, modified: nil, selected: true)
                        ]
                    ),
                    ToolGroup(
                        tool: "Package caches",
                        items: [
                            ScanItem(path: "/tmp/third", sizeBytes: 3_000, modified: nil, selected: false)
                        ]
                    )
                ]
            )
        ]
    }
}
