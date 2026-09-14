import Foundation
import Darwin

enum Safety {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var deniedRoots: [String] {
        [
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Application Support/FileProvider",
            "\(home)/Library/Application Support/CloudDocs",
            "\(home)/Library/Daemon Containers",
            "\(home)/Library/Caches/CloudKit",
            "\(home)/Library/Caches/com.apple.bird",
            "\(home)/Library/Caches/com.apple.cloudkit",
            "\(home)/Library/Caches/com.apple.cloudd",
            "\(home)/Library/Caches/com.apple.FileProvider",
        ]
    }

    static var criticalRoots: Set<String> {
        [
            "/", home, "/System", "/Library", "/Applications", "/Users", "/usr", "/bin", "/sbin", "/etc", "/var", "/private",
            "\(home)/Library", "\(home)/Library/Caches", "\(home)/Library/Application Support",
            "\(home)/Library/Containers", "\(home)/Library/Preferences", "\(home)/Library/Logs",
            "\(home)/Library/Developer", "\(home)/Library/Developer/Xcode",
            "\(home)/.config", "\(home)/.cache", "\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads",
        ]
    }

    static func isSymlink(_ path: String) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType
        return type == .typeSymbolicLink
    }

    static func hasSymlinkComponent(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: (path as NSString).standardizingPath)
        while url.path != "/" {
            if isSymlink(url.path), url.path != "/tmp", url.path != "/var" { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return false
    }

    static func isProviderOwned(_ path: String) -> Bool {
        let candidates = [
            (path as NSString).standardizingPath,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
        ]
        for candidate in candidates {
            if candidate.contains("com~apple~") { return true }
            for root in deniedRoots where candidate == root || candidate.hasPrefix(root + "/") { return true }
        }
        return false
    }

    static func isCloudOrDataless(_ path: String) -> Bool {
        if isProviderOwned(path) { return true }
        var info = stat()
        let status = path.withCString { lstat($0, &info) }
        if status == 0, info.st_flags & 0x40000000 != 0 { return true }
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        )
        guard values?.isUbiquitousItem == true else { return false }
        let downloadingStatus = values?.ubiquitousItemDownloadingStatus
        return downloadingStatus != .current && downloadingStatus != .downloaded
    }

    static var deniedUserRoots: [String] {
        [".ssh", ".aws", ".gnupg", ".gpg", ".kube", ".docker", ".claude", ".config", ".cargo", ".rustup",
         ".gem", ".nvm", ".pyenv", ".rbenv", ".ollama", ".lmstudio"].map { "\(home)/\($0)" }
    }

    static func isCredentialRoot(_ path: String) -> Bool {
        let allowed = [
            "\(home)/.docker/cli-plugins/.cache",
            "\(home)/.docker/buildx/cache",
            "\(home)/.cargo/registry/cache",
            "\(home)/.cargo/registry/index",
            "\(home)/.cargo/git/db",
            "\(home)/.cargo/git/checkouts",
            "\(home)/.ollama/logs",
            "\(home)/.lmstudio/server-logs",
        ]
        if allowed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        for root in deniedUserRoots where path == root || path.hasPrefix(root + "/") { return true }
        return false
    }

    static func ignoredPathProtectsCandidate(_ path: String, ignore: IgnoreStore) -> Bool {
        let candidates = canonicalForms(path)
        for ignored in ignore.roots where ignored.hasPrefix("/") {
            for root in canonicalForms(ignored) {
                if candidates.contains(where: {
                    $0 == root || $0.hasPrefix(root + "/") || root.hasPrefix($0 + "/")
                }) {
                    return true
                }
            }
        }
        return false
    }

    static func isPathIgnored(_ path: String, ignore: IgnoreStore) -> Bool {
        let candidates = canonicalForms(path)
        for ignored in ignore.roots where ignored.hasPrefix("/") {
            for root in canonicalForms(ignored) where candidates.contains(where: {
                $0 == root || $0.hasPrefix(root + "/")
            }) {
                return true
            }
        }
        return false
    }

    static func fileIdentity(at path: String) -> FileIdentity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return FileIdentity(device: device, inode: inode)
    }

    static func canRemove(_ path: String, ignore: IgnoreStore) -> (ok: Bool, reason: String?) {
        let std = (path as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: std).resolvingSymlinksInPath().path
        if std.isEmpty || !std.hasPrefix("/") || std == "/" || resolved == "/" { return (false, "root path") }
        if hasSymlinkComponent(std) { return (false, "symlink") }
        if criticalRoots.contains(std) || criticalRoots.contains(resolved) { return (false, "protected root") }
        let deniedTrees = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/cores"]
        if deniedTrees.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return (false, "protected system path")
        }
        if resolved.hasPrefix("/Users/"), resolved != home, !resolved.hasPrefix(home + "/") {
            return (false, "another user's files")
        }
        if isCredentialRoot(std) || isCredentialRoot(resolved) { return (false, "config/credentials dir") }
        if isCloudOrDataless(std) { return (false, "cloud/provider state") }
        if ignoredPathProtectsCandidate(std, ignore: ignore) { return (false, "ignored") }
        if !FileManager.default.fileExists(atPath: std) { return (false, "missing") }
        return (true, nil)
    }

    static func isValidScanRoot(
        _ path: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> (ok: Bool, reason: String?) {
        let absolute = absolutePath(path, currentDirectory: currentDirectory)
        guard !hasSymlinkComponent(absolute) else {
            return (false, "scan root must not contain symbolic links")
        }
        let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
        let std = (resolved as NSString).standardizingPath
        var systemRoots: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin", "/etc", "/var", "/opt", "/cores", "/Volumes", home]
        for dir in ["Library", "Pictures", "Music", "Movies", "Public"] { systemRoots.insert("\(home)/\(dir)") }
        if systemRoots.contains(std) { return (false, "'\(path)' is a system location — scan a project folder instead") }
        let deniedTrees = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/cores", "\(home)/Library", "\(home)/Pictures", "\(home)/Music", "\(home)/Movies", "\(home)/Public"]
        if deniedTrees.contains(where: { std == $0 || std.hasPrefix($0 + "/") }) {
            return (false, "'\(path)' is a protected location — scan a project folder instead")
        }
        if isCloudOrDataless(std) { return (false, "cloud/provider folders are not scanned") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue else {
            return (false, "not a folder: \(path)")
        }
        return (true, nil)
    }

    static func absolutePath(
        _ path: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
    }

    private static func canonicalForms(_ path: String) -> [String] {
        let std = (path as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: std).resolvingSymlinksInPath().path
        return std == resolved ? [std] : [std, resolved]
    }
}
