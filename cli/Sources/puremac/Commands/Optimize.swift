import ArgumentParser
import Foundation

struct Optimize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Review memory, storage, and local snapshot status.",
        discussion: """
          puremac optimize             Show memory and storage status
          puremac optimize ram         Show memory details
          puremac optimize purgeable   Explain APFS managed capacity
          puremac optimize snapshots   List local Time Machine snapshots
        These checks are read-only. PureMac does not force memory purges or promise
        that APFS managed capacity can be reclaimed on demand.
        """
    )

    @Argument(help: "View to show: status | ram | purgeable | snapshots.")
    var task: String?

    func validate() throws {
        guard let task else { return }
        guard ["status", "ram", "purgeable", "snapshots"].contains(task) else {
            throw ValidationError(
                "Unknown view '\(task)'. Use 'status', 'ram', 'purgeable', or 'snapshots'."
            )
        }
    }

    func run() throws {
        switch task ?? "status" {
        case "ram":
            try showMemory(includeHeading: true)
            print("")
            print(Term.dim("No memory was purged. macOS reclaims inactive memory when applications need it."))
        case "purgeable":
            try showStorage(includeHeading: true)
            print("")
            print(Term.dim("No storage was changed. APFS managed capacity is an estimate controlled by macOS."))
        case "snapshots":
            try showSnapshots()
        default:
            print(Term.bold("Mac status"))
            print(Term.dim("Read-only measurements from macOS"))
            print("")
            try showMemory(includeHeading: true)
            print("")
            try showStorage(includeHeading: true)
            print("")
            print("  " + Term.dim("Uptime") + "  " + Self.formatUptime(ProcessInfo.processInfo.systemUptime))
            print("")
            print(Term.dim("No maintenance ran. Use `puremac clean --dry-run` to review removable files."))
        }
    }

    static func parseLocalSnapshots(_ output: String) -> [String] {
        let snapshots = output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isValidLocalSnapshot)
        return Array(Set(snapshots)).sorted(by: >)
    }

    static func isValidLocalSnapshot(_ value: String) -> Bool {
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return false }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        let timestamp = String(value[start..<end])
        guard timestamp.count == 17 else { return false }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        guard let date = formatter.date(from: timestamp) else { return false }
        return formatter.string(from: date) == timestamp
    }

    static func formatUptime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func showMemory(includeHeading: Bool) throws {
        let status = try SystemInfo.memoryStatus()
        if includeHeading { print(Term.bold("Memory")) }
        printMetric("Installed", ByteCount.human(status.total))
        printMetric("Free now", ByteCount.human(status.free))
        printMetric("Active", ByteCount.human(status.active))
        printMetric("Inactive", ByteCount.human(status.inactive))
        printMetric("Compressed", ByteCount.human(status.compressed))
        printMetric("Wired", ByteCount.human(status.wired))
    }

    private func showStorage(includeHeading: Bool) throws {
        let status = try SystemInfo.volumeStatus("/")
        if includeHeading { print(Term.bold("Storage")) }
        printMetric("Free now", ByteCount.human(status.availableNow))
        printMetric("Total", ByteCount.human(status.total))
        printMetric("Managed by macOS", ByteCount.human(status.systemManagedCapacity))
        if status.systemManagedCapacity > 0 {
            print(Term.dim("  Managed capacity may include purgeable files and is not guaranteed free space."))
        }
    }

    private func showSnapshots() throws {
        let result = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard result.status == 0 else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ValidationError(detail.isEmpty ? "Could not list local Time Machine snapshots." : detail)
        }
        let snapshots = Self.parseLocalSnapshots(result.out)
        print(Term.bold("Local Time Machine snapshots"))
        if snapshots.isEmpty {
            print(Term.dim("  None reported by macOS."))
            return
        }
        for snapshot in snapshots {
            print("  \(snapshot)  " + Term.dim("size unavailable"))
        }
        print("")
        print(Term.dim("Read-only list. Snapshot storage is managed by Time Machine and macOS."))
    }

    private func printMetric(_ label: String, _ value: String) {
        print("  \(label.padding(toLength: 17, withPad: " ", startingAt: 0)) \(value)")
    }
}
