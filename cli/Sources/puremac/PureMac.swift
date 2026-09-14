import ArgumentParser
import Foundation

let puremacVersion = "1.1.0"

@main
struct PureMac: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "puremac",
        abstract: "Review caches, clean project artifacts, and explore your storage.",
        discussion: """
        Run puremac to open the interactive workspace. Select individual paths,
        review their sizes, and confirm before permanent cleanup.
        Use --help on any command for script-friendly options.
        """,
        version: puremacVersion,
        subcommands: [Clean.self, Purge.self, Analyze.self, Optimize.self, Ignore.self, Config.self]
    )

    func run() throws {
        guard TerminalSession.isSupported else {
            print(Self.helpMessage())
            return
        }
        try HomeMenu.run()
    }
}

enum HomeMenu {
    static func run() throws {
        let options: [(title: String, detail: String)] = [
            ("Clean caches", "Choose tools and individual paths to remove"),
            ("Project cleanup", "Review dependencies and generated build artifacts"),
            ("Explore storage", "Browse folders and find what takes up space"),
            ("System status", "Inspect memory and available disk space"),
            ("Preferences", "View cleanup settings and configuration paths"),
            ("Protected paths", "View folders excluded from cleanup")
        ]
        while let choice = try TerminalMenu.choose(
            title: "PureMac",
            subtitle: "Your Mac, with room to work.  /  \(puremacVersion)",
            options: options
        ) {
            switch choice {
            case 0:
                guard let category = try TerminalMenu.choose(
                    title: "Clean caches",
                    subtitle: "Scan first. Choose what to remove afterward.",
                    options: [
                        ("All categories", "Developer caches, user junk, AI tools, and Trash"),
                        ("Developer caches", "Package managers and build tools"),
                        ("User junk", "Logs and generated Xcode files"),
                        ("AI tools", "Caches and logs from local AI tools"),
                        ("Trash", "Review items already in the Trash")
                    ]
                ) else { continue }
                let arguments = [[], ["dev"], ["junk"], ["ai"], ["trash"]]
                try Clean.parse(arguments[category]).run()
            case 1: try Purge.parse([]).run()
            case 2: try Analyze.parse([]).run()
            case 3: try Optimize.parse([]).run()
            case 4: try Config.parse([]).run()
            case 5: try Ignore.List.parse([]).run()
            default: return
            }
            print(Term.dim("\nPress Return to return to PureMac."), terminator: " ")
            guard readLine() != nil else { return }
        }
    }
}
