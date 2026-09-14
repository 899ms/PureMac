import ArgumentParser
import Foundation

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change CLI preferences.",
        discussion: """
          puremac config                       Show settings and storage locations
          puremac config set purge.older_than_days 14
        The age setting controls which project artifacts `puremac purge` preselects.
        PureMac CLI has no telemetry setting because it sends no telemetry.
        """
    )

    @Argument(help: "Use 'set' to change a value. Omit to show settings.")
    var action: String?

    @Argument(help: "Setting key.")
    var key: String?

    @Argument(help: "New value.")
    var value: String?

    func validate() throws {
        if action == nil, key == nil, value == nil { return }
        guard action == "set" else {
            throw ValidationError("Unknown action '\(action ?? "")'. Use 'set' or omit all arguments.")
        }
        guard let key, let value else {
            throw ValidationError("Usage: puremac config set <key> <value>")
        }
        do {
            _ = try ConfigStore.normalizedValue(value, for: key)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    func run() throws {
        var store = try ConfigStore(fileURL: AppPaths.configFile)
        if action == "set" {
            guard let key, let value else {
                throw ValidationError("Usage: puremac config set <key> <value>")
            }
            try store.set(key, value)
            let saved = store.values[key] ?? value
            print(Term.green("✓ Saved \(key) = \(saved)"))
            print(Term.dim("  \(Render.shorten(AppPaths.configFile.path))"))
            return
        }

        print(Term.bold("PureMac CLI settings"))
        print(Term.dim("Values used when a command-line option is omitted"))
        print("")
        for key in ConfigStore.knownKeys {
            let isSaved = store.values[key] != nil
            let value = store.values[key] ?? ConfigStore.defaultValues[key] ?? ""
            let source = isSaved ? "saved" : "default"
            print("  \(key.padding(toLength: 26, withPad: " ", startingAt: 0)) \(value) days  " + Term.dim(source))
        }
        print("")
        print(Term.bold("Files"))
        print("  \("Settings".padding(toLength: 12, withPad: " ", startingAt: 0)) \(Render.shorten(AppPaths.configFile.path))")
        print("  \("Protected".padding(toLength: 12, withPad: " ", startingAt: 0)) \(Render.shorten(AppPaths.ignoreFile.path))")
    }
}
