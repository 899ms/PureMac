import Foundation

enum AppPaths {
    static var configDir: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
           !xdg.isEmpty,
           xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("puremac", isDirectory: true)
    }

    static var ignoreFile: URL { configDir.appendingPathComponent("ignore") }
    static var configFile: URL { configDir.appendingPathComponent("config.json") }

    static func ensureDir() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }
}

enum StoreError: LocalizedError {
    case invalidConfigFile(String)
    case unknownConfigKey(String)
    case invalidConfigValue(key: String, value: String)
    case invalidIgnorePath
    case invalidIgnoreFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfigFile(let path):
            return "Configuration file is not a valid PureMac settings file: \(path)"
        case .unknownConfigKey(let key):
            return "Unknown setting '\(key)'."
        case .invalidConfigValue(let key, let value):
            return "Invalid value '\(value)' for \(key). Use a whole number from 1 to 3650."
        case .invalidIgnorePath:
            return "Protected paths cannot be empty, the filesystem root, or contain newline or NUL characters."
        case .invalidIgnoreFile(let path):
            return "Ignore file contains an invalid or relative path: \(path)"
        }
    }
}

struct IgnoreStore {
    private(set) var roots: [String]
    private let fileURL: URL
    private let currentDirectoryPath: String

    init() {
        fileURL = AppPaths.ignoreFile
        currentDirectoryPath = FileManager.default.currentDirectoryPath
        roots = (try? Self.load(from: fileURL)) ?? []
    }

    init(
        fileURL: URL,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) throws {
        self.fileURL = fileURL
        self.currentDirectoryPath = currentDirectoryPath
        roots = try Self.load(from: fileURL)
    }

    func isIgnored(_ path: String) -> Bool {
        guard let standardized = try? Self.standardized(
            path,
            relativeTo: currentDirectoryPath,
            allowRelative: true
        ) else { return false }
        for root in roots where standardized == root || standardized.hasPrefix(root + "/") {
            return true
        }
        return false
    }

    mutating func add(_ path: String) throws -> Bool {
        let standardized = try Self.standardized(
            path,
            relativeTo: currentDirectoryPath,
            allowRelative: true
        )
        guard !roots.contains(standardized) else { return false }
        let updated = roots + [standardized]
        try save(updated)
        roots = updated
        return true
    }

    mutating func remove(_ path: String) throws -> Bool {
        let standardized = try Self.standardized(
            path,
            relativeTo: currentDirectoryPath,
            allowRelative: true
        )
        guard roots.contains(standardized) else { return false }
        let updated = roots.filter { $0 != standardized }
        try save(updated)
        roots = updated
        return true
    }

    private static func standardized(
        _ path: String,
        relativeTo currentDirectoryPath: String,
        allowRelative: Bool
    ) throws -> String {
        guard !path.isEmpty,
              !path.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.newlines.contains($0)
              })
        else {
            throw StoreError.invalidIgnorePath
        }
        let expanded = (path as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            guard allowRelative else {
                throw StoreError.invalidIgnorePath
            }
            absolute = currentDirectoryPath + "/" + expanded
        }
        let standardized = try lexicalStandardizedAbsolutePath(absolute)
        guard standardized.hasPrefix("/"), standardized != "/",
              !standardized.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.newlines.contains($0)
              })
        else {
            throw StoreError.invalidIgnorePath
        }
        return standardized
    }

    private static func lexicalStandardizedAbsolutePath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw StoreError.invalidIgnorePath
        }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }

    private static func load(from fileURL: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        var seen = Set<String>()
        var roots: [String] = []
        for line in contents.split(separator: "\n").map(String.init) {
            do {
                let root = try standardized(line, relativeTo: "/", allowRelative: false)
                if seen.insert(root).inserted { roots.append(root) }
            } catch {
                throw StoreError.invalidIgnoreFile(fileURL.path)
            }
        }
        return roots
    }

    private func save(_ roots: [String]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = roots.isEmpty ? "" : roots.sorted().joined(separator: "\n") + "\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

struct ConfigStore {
    private(set) var values: [String: String]
    private let fileURL: URL

    static let knownKeys = ["purge.older_than_days"]
    static let defaultValues = ["purge.older_than_days": "7"]

    init() {
        fileURL = AppPaths.configFile
        values = (try? Self.load(from: fileURL)) ?? [:]
    }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        values = try Self.load(from: fileURL)
    }

    mutating func set(_ key: String, _ value: String) throws {
        let normalized = try Self.normalizedValue(value, for: key)
        var updated = values
        updated[key] = normalized
        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        values = updated
    }

    static func normalizedValue(_ value: String, for key: String) throws -> String {
        guard knownKeys.contains(key) else {
            throw StoreError.unknownConfigKey(key)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let days = Int(trimmed), (1...3650).contains(days) else {
            throw StoreError.invalidConfigValue(key: key, value: value)
        }
        return String(days)
    }

    private static func load(from fileURL: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: String]
        else {
            throw StoreError.invalidConfigFile(fileURL.path)
        }
        for (key, value) in values {
            _ = try normalizedValue(value, for: key)
        }
        return values
    }
}
