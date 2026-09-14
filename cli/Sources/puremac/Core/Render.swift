import Darwin
import Foundation

enum Render {
    static let rule = String(repeating: "─", count: 60)

    static func scanResults(_ categories: [CategoryScan]) {
        let total = categories.reduce(Int64(0)) { $0 + $1.allBytes }
        let itemCount = categories.flatMap(\.groups).flatMap(\.items).count
        print("")
        print(Term.bold("Scan complete"))
        print(
            Term.bold(ByteCount.human(total))
                + Term.dim(" across \(itemCount) item\(itemCount == 1 ? "" : "s")")
        )

        for category in categories where !category.groups.isEmpty {
            print("")
            print(
                Term.cyan(Term.bold(Term.sanitize(category.title)))
                    + Term.dim("  \(ByteCount.human(category.allBytes))")
            )
            for group in category.groups {
                print(
                    "  " + Term.bold(Term.sanitize(group.tool))
                        + Term.dim("  \(group.items.count) item\(group.items.count == 1 ? "" : "s")")
                )
                for item in group.items {
                    let mark = item.selected ? Term.cyan("●") : Term.dim("○")
                    let path = displayedPath(item.path, available: max(12, outputWidth - 18))
                    print("    \(mark) \(sizeCol(item.sizeBytes)) \(path)")
                }
            }
        }
    }

    static func selectionLine(_ categories: [CategoryScan]) {
        let items = categories.flatMap { $0.selectedItems }
        let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print(
            Term.bold("\(items.count) selected")
                + Term.dim("  \(ByteCount.human(total))")
        )
    }

    static func deletionReview(_ categories: [CategoryScan]) {
        let selected = categories.flatMap { $0.selectedItems }
        let total = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print(Term.yellow(Term.bold("Permanent deletion review")))
        print(Term.dim(String(repeating: "─", count: min(72, outputWidth))))

        for category in categories {
            let selectedInCategory = category.selectedItems
            guard !selectedInCategory.isEmpty else { continue }
            print(
                Term.cyan(Term.sanitize(category.title))
                    + Term.dim("  \(ByteCount.human(selectedInCategory.reduce(0) { $0 + $1.sizeBytes }))")
            )
            for group in category.groups {
                for item in group.items where item.selected {
                    print("  \(sizeCol(item.sizeBytes)) \(Term.sanitize(group.tool))")
                    print("    \(Term.sanitize(item.path))")
                }
            }
        }

        print(Term.dim(String(repeating: "─", count: min(72, outputWidth))))
        print(
            Term.bold(ByteCount.human(total))
                + Term.dim("  \(selected.count) item\(selected.count == 1 ? "" : "s")")
        )
    }

    static func cleanupSummary(_ outcome: CleanOutcome, dryRun: Bool) {
        print("")
        if dryRun {
            print(Term.bold("Dry run complete"))
            print(
                Term.cyan(ByteCount.human(outcome.freedBytes))
                    + Term.dim(" reclaimable across \(outcome.removed) item\(outcome.removed == 1 ? "" : "s")")
            )
            print(Term.dim("Nothing was deleted."))
        } else {
            print(Term.green(Term.bold("Cleanup complete")))
            print(
                Term.bold(ByteCount.human(outcome.freedBytes))
                    + Term.dim(" removed across \(outcome.removed) item\(outcome.removed == 1 ? "" : "s")")
            )
        }

        if !outcome.skipped.isEmpty {
            print(Term.yellow("\(outcome.skipped.count) skipped") + Term.dim("  protected or ignored"))
        }
        if !outcome.failed.isEmpty {
            print(Term.red("\(outcome.failed.count) failed"))
            for failure in outcome.failed.prefix(10) {
                Term.err("  ! \(Term.sanitize(failure.path))")
                Term.err("    \(Term.sanitize(failure.error))")
            }
        }
        print("")
    }

    static func sizeCol(_ bytes: Int64) -> String {
        pad(ByteCount.human(bytes), 10)
    }

    static func pad(_ string: String, _ width: Int) -> String {
        Term.pad(string, to: width)
    }

    static func shorten(_ path: String) -> String {
        let safePath = Term.sanitize(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if safePath == home { return "~" }
        return safePath.hasPrefix(home + "/")
            ? "~" + safePath.dropFirst(home.count)
            : safePath
    }

    private static var outputWidth: Int {
        guard isatty(STDOUT_FILENO) == 1 else { return 100 }
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 else { return 100 }
        return max(1, Int(window.ws_col))
    }

    private static func displayedPath(_ path: String, available: Int) -> String {
        return isatty(STDOUT_FILENO) == 1
            ? Term.truncate(shorten(path), to: available, middle: true)
            : Term.sanitize(path)
    }
}
