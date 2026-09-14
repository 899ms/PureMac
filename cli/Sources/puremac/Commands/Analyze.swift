import ArgumentParser
import Foundation

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show what is taking up disk space, largest first.",
        discussion: """
        Sizes the immediate children of a folder and ranks them, like `du -d1 | sort`.
          puremac analyze              Explore your home folder
          puremac analyze ~/Library    Explore a specific folder
          puremac analyze --plain      Print a report without fullscreen browsing
        Browsing never modifies files.
        """
    )

    @Argument(help: "Folder to analyze. Omit for your home folder.")
    var path: String?

    @Option(name: .shortAndLong, help: "How many levels deep to print in plain mode (1...8).")
    var depth: Int = 1

    @Flag(name: .long, help: "Emit machine-readable JSON and exit.")
    var json = false

    @Flag(name: .long, help: "Print a report instead of opening the fullscreen explorer.")
    var plain = false

    func validate() throws {
        guard (1...8).contains(depth) else {
            throw ValidationError("Depth must be between 1 and 8.")
        }
    }

    func run() throws {
        let target = ((path ?? Safety.home) as NSString).expandingTildeInPath
        let ignore = try IgnoreStore(fileURL: AppPaths.ignoreFile)
        try validateRoot(target, ignore: ignore)

        if json {
            let snapshot = scanFolder(target, ignore: ignore)
            struct Row: Encodable { let path: String; let bytes: Int64 }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(snapshot.children.map { Row(path: $0.path, bytes: $0.size) })
            print(String(decoding: data, as: UTF8.self))
            return
        }

        if Self.usesInteractiveBrowser(plain: plain, depth: depth) {
            try browse(target, ignore: ignore)
            return
        }

        printPlain(target, ignore: ignore)
    }

    static func usesInteractiveBrowser(
        plain: Bool,
        depth: Int,
        terminalSupported: Bool = TerminalSession.isSupported
    ) -> Bool {
        !plain && depth == 1 && terminalSupported
    }

    struct Child: Equatable {
        let path: String
        let size: Int64
        let isDir: Bool
        let isPackage: Bool
        let inaccessibleCount: Int
        let skippedCount: Int

        var isPartial: Bool { inaccessibleCount > 0 || skippedCount > 0 }
    }

    struct FolderSnapshot: Equatable {
        let path: String
        let children: [Child]
        let total: Int64
        let inaccessibleCount: Int
        let skippedCount: Int
        let errors: [String]

        var isPartial: Bool { inaccessibleCount > 0 || skippedCount > 0 }
    }

    private struct MeasureContext {
        var inaccessibleCount = 0
        var skippedCount = 0
        var errors: [String] = []
    }

    struct BrowserLevel {
        let snapshot: FolderSnapshot
        var selected = 0
        var offset = 0
    }

    func scanFolder(_ directory: String, ignore: IgnoreStore = IgnoreStore()) -> FolderSnapshot {
        let standardized = (directory as NSString).standardizingPath
        let directoryURL = URL(fileURLWithPath: standardized, isDirectory: true)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: standardized)
        } catch {
            return FolderSnapshot(
                path: standardized,
                children: [],
                total: 0,
                inaccessibleCount: 1,
                skippedCount: 0,
                errors: ["\(standardized): \(error.localizedDescription)"]
            )
        }

        var context = MeasureContext()
        var children: [Child] = []
        let orderedNames = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in orderedNames {
            let url = directoryURL.appendingPathComponent(name)
            if let child = measureChild(url, ignore: ignore, context: &context) {
                children.append(child)
            }
        }

        children.sort {
            if $0.size == $1.size {
                return URL(fileURLWithPath: $0.path).lastPathComponent
                    .localizedStandardCompare(URL(fileURLWithPath: $1.path).lastPathComponent) == .orderedAscending
            }
            return $0.size > $1.size
        }
        return FolderSnapshot(
            path: standardized,
            children: children,
            total: children.reduce(Int64(0)) { $0 + $1.size },
            inaccessibleCount: context.inaccessibleCount,
            skippedCount: context.skippedCount,
            errors: context.errors
        )
    }

    func sizedChildren(of directory: String) -> [Child] {
        scanFolder(directory).children
    }

    private func measureChild(_ topURL: URL, ignore: IgnoreStore, context: inout MeasureContext) -> Child? {
        let path = topURL.path
        if Safety.ignoredPathProtectsCandidate(path, ignore: ignore) {
            context.skippedCount += 1
            return nil
        }
        let measurement = DirSizer.measure(of: path)
        switch measurement.status {
        case .symlink, .cloudOrDataless:
            context.skippedCount += max(1, measurement.skippedEntries)
            return nil
        case .unavailable:
            context.inaccessibleCount += max(1, measurement.skippedEntries)
            if context.errors.count < 20 { context.errors.append("\(path): unavailable") }
            return nil
        case .partial:
            context.skippedCount += max(1, measurement.skippedEntries)
            if context.errors.count < 20 { context.errors.append("\(path): partial measurement") }
        case .complete:
            break
        }

        let values = try? topURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDirectory = values?.isDirectory == true
        return Child(
            path: path,
            size: measurement.bytes,
            isDir: isDirectory,
            isPackage: isDirectory && values?.isPackage == true,
            inaccessibleCount: 0,
            skippedCount: measurement.status == .partial ? max(1, measurement.skippedEntries) : 0
        )
    }

    private func validateRoot(_ target: String, ignore: IgnoreStore) throws {
        let standardized = (target as NSString).standardizingPath
        guard !ignore.isIgnored(standardized) else { throw ValidationError("Ignored path: \(standardized)") }
        guard !Safety.hasSymlinkComponent(standardized) else {
            throw ValidationError("Symbolic links are not scanned: \(standardized)")
        }
        guard !Safety.isCloudOrDataless(standardized) else {
            throw ValidationError("Cloud-only folders must be downloaded before scanning: \(standardized)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("Not a folder: \(standardized)")
        }
    }

    private func printPlain(_ target: String, ignore: IgnoreStore) {
        let snapshot = scanFolder(target, ignore: ignore)
        if let volume = try? SystemInfo.volumeStatus(target), volume.total > 0 {
            print("")
            print(Term.bold("\(ByteCount.human(volume.availableNow)) free of \(ByteCount.human(volume.total))"))
        }
        print(Term.dim("\(Render.shorten(target)) — \(ByteCount.human(snapshot.total))"))
        print("")
        printLevel(snapshot.children, total: snapshot.total, indent: "  ", depthLeft: depth - 1, ignore: ignore)
        printDiagnostics(snapshot, indent: "  ")
    }

    func printLevel(
        _ children: [Child],
        total: Int64,
        indent: String,
        depthLeft: Int,
        ignore: IgnoreStore = IgnoreStore()
    ) {
        for child in children where child.size > 0 || child.isPartial {
            let fraction = total > 0 ? Double(child.size) / Double(total) : 0
            let percentage = String(format: "%5.1f%%", fraction * 100)
            let size = ByteCount.human(child.size).padding(toLength: 10, withPad: " ", startingAt: 0)
            let suffix = child.isDir && !child.isPackage ? "/" : (child.isPackage ? " [package]" : "")
            let partial = child.isPartial ? Term.yellow(" !") : ""
            let name = URL(fileURLWithPath: child.path).lastPathComponent + suffix
            print("\(indent)\(size) \(Term.dim(percentage)) \(Term.bar(fraction: fraction, width: 20)) \(name)\(partial)")
            if depthLeft > 0 && child.isDir && !child.isPackage {
                let snapshot = scanFolder(child.path, ignore: ignore)
                printLevel(Array(snapshot.children.prefix(10)), total: child.size, indent: indent + "  ", depthLeft: depthLeft - 1, ignore: ignore)
                printDiagnostics(snapshot, indent: indent + "  ")
            }
        }
    }

    private func printDiagnostics(_ snapshot: FolderSnapshot, indent: String) {
        if snapshot.skippedCount > 0 {
            print(indent + Term.yellow("\(snapshot.skippedCount) skipped") + Term.dim(" (ignored, linked, or cloud-only)"))
        }
        if snapshot.inaccessibleCount > 0 {
            print(indent + Term.red("\(snapshot.inaccessibleCount) inaccessible"))
            for error in snapshot.errors.prefix(5) { Term.err(indent + "! " + error) }
        }
    }

    private func browse(_ target: String, ignore: IgnoreStore) throws {
        let session = try TerminalSession()
        defer { session.close() }
        session.draw(lines: measuringLines(target, width: session.width))
        var levels = [BrowserLevel(snapshot: scanFolder(target, ignore: ignore))]
        var running = true

        while running {
            let index = levels.index(before: levels.endIndex)
            let visibleRows = Self.visibleRowCount(snapshot: levels[index].snapshot, selected: levels[index].selected, width: session.width, height: session.height)
            levels[index].offset = Self.adjustedOffset(
                levels[index].offset,
                selected: levels[index].selected,
                count: levels[index].snapshot.children.count,
                visibleRows: visibleRows
            )
            session.draw(lines: Self.browserLines(level: levels[index], width: session.width, height: session.height))

            switch session.readKey() {
            case .up:
                levels[index].selected = max(0, levels[index].selected - 1)
            case .down:
                levels[index].selected = min(max(0, levels[index].snapshot.children.count - 1), levels[index].selected + 1)
            case .pageUp:
                levels[index].selected = max(0, levels[index].selected - visibleRows)
            case .pageDown:
                levels[index].selected = min(max(0, levels[index].snapshot.children.count - 1), levels[index].selected + visibleRows)
            case .home:
                levels[index].selected = 0
            case .end:
                levels[index].selected = max(0, levels[index].snapshot.children.count - 1)
            case .enter, .right:
                guard let child = Self.focusedChild(levels[index]), child.isDir, !child.isPackage else { continue }
                session.draw(lines: measuringLines(child.path, width: session.width))
                levels.append(BrowserLevel(snapshot: scanFolder(child.path, ignore: ignore)))
            case .left, .backspace:
                if levels.count > 1 { levels.removeLast() }
            case .escape:
                running = false
            case .character(let character):
                switch character.lowercased() {
                case "q": running = false
                case "o":
                    if let child = Self.focusedChild(levels[index]) { Self.revealInFinder(child.path) }
                default: break
                }
            case .delete, .space, .unknown:
                break
            }
        }
    }

    private func measuringLines(_ path: String, width: Int) -> [String] {
        let safeWidth = max(1, width)
        return [
            Term.bold(Term.cyan(Term.truncate("PureMac Space Explorer", to: safeWidth))),
            "",
            Term.dim(Term.truncate("Measuring allocated space...", to: safeWidth)),
            Term.truncate(path, to: safeWidth, middle: true),
            "",
            Term.dim(Term.truncate("Ctrl+C cancel", to: safeWidth))
        ]
    }

    static func browserLines(level: BrowserLevel, width: Int, height: Int) -> [String] {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        if safeWidth < 40 || safeHeight < 12 {
            let compact = [
                Term.bold(Term.cyan(Term.truncate("PureMac Space Explorer", to: safeWidth))),
                Term.truncate("Terminal too small", to: safeWidth),
                Term.dim(Term.truncate("Resize to at least 40 x 12", to: safeWidth)),
                "",
                Term.dim(Term.truncate("Esc/q exit", to: safeWidth))
            ]
            return Array(compact.prefix(safeHeight))
        }
        let snapshot = level.snapshot
        let pathLines = wrap(focusedChild(level)?.path ?? snapshot.path, width: max(1, safeWidth - 9))
        let visibleRows = visibleRowCount(snapshot: snapshot, selected: level.selected, width: safeWidth, height: safeHeight)
        let upperBound = min(snapshot.children.count, level.offset + visibleRows)
        let rows = level.offset < upperBound
            ? snapshot.children[level.offset..<upperBound].enumerated().map { offset, child in
                row(child, focused: level.offset + offset == level.selected, total: snapshot.total, width: safeWidth)
            }
            : []

        var lines = [
            Term.bold(Term.cyan("PureMac Space Explorer")),
            Term.truncate(snapshot.path, to: safeWidth, middle: true),
            statusLine(snapshot, width: safeWidth),
            String(repeating: "─", count: safeWidth)
        ]
        lines.append(contentsOf: rows.isEmpty
            ? [snapshot.inaccessibleCount > 0 ? Term.red("Folder contents are inaccessible.") : Term.dim("No measurable items.")]
            : rows)
        lines.append(String(repeating: "─", count: safeWidth))
        lines.append(Term.dim("↑↓ move  Enter/→ open  O reveal"))
        lines.append(Term.dim("←/⌫ back  q/Esc exit"))
        for (index, line) in pathLines.enumerated() {
            lines.append((index == 0 ? Term.dim("Focused: ") : String(repeating: " ", count: 9)) + line)
        }
        if let error = snapshot.errors.first {
            lines.append(Term.red("! ") + Term.truncate(error, to: max(1, safeWidth - 2), middle: true))
        }
        return Array(lines.prefix(safeHeight))
    }

    static func visibleRowCount(snapshot: FolderSnapshot, selected: Int, width: Int, height: Int) -> Int {
        let focusedPath = snapshot.children.indices.contains(selected) ? snapshot.children[selected].path : snapshot.path
        let pathLines = wrap(focusedPath, width: max(1, max(1, width) - 9)).count
        return max(1, height - 7 - pathLines - (snapshot.errors.isEmpty ? 0 : 1))
    }

    static func adjustedOffset(_ offset: Int, selected: Int, count: Int, visibleRows: Int) -> Int {
        guard count > 0 else { return 0 }
        let selection = min(max(0, selected), count - 1)
        var result = min(max(0, offset), max(0, count - visibleRows))
        if selection < result { result = selection }
        if selection >= result + visibleRows { result = selection - visibleRows + 1 }
        return max(0, result)
    }

    private static func focusedChild(_ level: BrowserLevel) -> Child? {
        guard level.snapshot.children.indices.contains(level.selected) else { return nil }
        return level.snapshot.children[level.selected]
    }

    private static func row(_ child: Child, focused: Bool, total: Int64, width: Int) -> String {
        let fraction = total > 0 ? Double(child.size) / Double(total) : 0
        let size = Render.pad(ByteCount.human(child.size), 10)
        let barWidth = min(20, max(6, (width - 32) / 3))
        let suffix = child.isDir && !child.isPackage ? "/" : (child.isPackage ? " [package]" : "")
        let partial = child.isPartial ? " !" : ""
        let nameWidth = max(1, width - 14 - barWidth - partial.count)
        let name = Term.truncate(URL(fileURLWithPath: child.path).lastPathComponent + suffix, to: nameWidth, middle: true)
        let line = "\(focused ? "›" : " ") \(size) \(Term.bar(fraction: fraction, width: barWidth)) \(name)\(partial)"
        return focused ? Term.inverse(Term.pad(line, to: width)) : line
    }

    private static func statusLine(_ snapshot: FolderSnapshot, width: Int) -> String {
        var parts = [ByteCount.human(snapshot.total) + " allocated", "\(snapshot.children.count) items"]
        if snapshot.skippedCount > 0 { parts.append("\(snapshot.skippedCount) skipped") }
        if snapshot.inaccessibleCount > 0 { parts.append("\(snapshot.inaccessibleCount) inaccessible") }
        return Term.truncate(parts.joined(separator: "  ·  "), to: width)
    }

    static func wrap(_ string: String, width: Int) -> [String] {
        let safe = Term.sanitize(string)
        guard !safe.isEmpty else { return [""] }
        var lines: [String] = []
        var current = ""
        var used = 0
        for character in safe {
            let value = String(character)
            let characterWidth = max(0, Term.displayWidth(value))
            if used + characterWidth > width && !current.isEmpty {
                lines.append(current)
                current = ""
                used = 0
            }
            current.append(character)
            used += characterWidth
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    private static func revealInFinder(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-R", path]
        try? process.run()
    }

}
