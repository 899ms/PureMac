import Foundation

struct TerminalMenuModel {
    let optionCount: Int
    private(set) var selection = 0

    mutating func move(_ delta: Int) {
        guard optionCount > 0 else { return }
        selection = min(optionCount - 1, max(0, selection + delta))
    }

    mutating func moveToStart() {
        selection = 0
    }

    mutating func moveToEnd() {
        selection = max(0, optionCount - 1)
    }

    mutating func select(number: Int) -> Int? {
        let index = number - 1
        guard (1...9).contains(number), index < optionCount else { return nil }
        selection = index
        return selection
    }
}

enum TerminalMenu {
    static func choose(
        title: String,
        subtitle: String,
        options: [(title: String, detail: String)]
    ) throws -> Int? {
        guard !options.isEmpty else { return nil }
        let session = try TerminalSession()
        defer { session.close() }

        var model = TerminalMenuModel(optionCount: options.count)
        while true {
            session.draw(
                lines: render(
                    title: title,
                    subtitle: subtitle,
                    options: options,
                    selection: model.selection,
                    width: session.width,
                    height: session.height
                )
            )

            switch session.readKey() {
            case .up:
                model.move(-1)
            case .down:
                model.move(1)
            case .pageUp:
                model.move(-max(1, session.height / 2))
            case .pageDown:
                model.move(max(1, session.height / 2))
            case .home:
                model.moveToStart()
            case .end:
                model.moveToEnd()
            case .enter:
                return model.selection
            case .escape:
                return nil
            case .character(let character):
                if String(character).lowercased() == "q" {
                    return nil
                }
                if let number = character.wholeNumberValue,
                   let selection = model.select(number: number) {
                    return selection
                }
            default:
                break
            }
        }
    }

    static func render(
        title: String,
        subtitle: String,
        options: [(title: String, detail: String)],
        selection: Int,
        width: Int,
        height: Int
    ) -> [String] {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        if safeWidth < 40 || safeHeight < 12 {
            let compact = [
                Term.bold(Term.cyan(Term.truncate("PureMac", to: safeWidth))),
                Term.truncate("Terminal too small", to: safeWidth),
                Term.dim(Term.truncate("Resize to at least 40 x 12", to: safeWidth)),
                "",
                Term.dim(Term.truncate("Esc/q cancel", to: safeWidth))
            ]
            return Array(compact.prefix(safeHeight))
        }
        let safeSelection = min(max(0, selection), max(0, options.count - 1))
        var lines = [
            Term.dim("PUREMAC  /  CHOOSE A TOOL"),
            Term.bold(Term.cyan(Term.truncate(title, to: safeWidth))),
            Term.dim(Term.truncate(subtitle, to: safeWidth)),
            ""
        ]

        let footerHeight = 3
        let rowHeight = 2
        let visibleCount = max(1, (safeHeight - lines.count - footerHeight) / rowHeight)
        let start = max(0, min(max(0, options.count - visibleCount), safeSelection - visibleCount / 2))
        let visible = options.enumerated().dropFirst(start).prefix(visibleCount)

        for (index, option) in visible {
            let focused = index == safeSelection
            let number = Term.pad("\(index + 1).", to: 4)
            let titleWidth = max(1, safeWidth - 6)
            let titleLine = "\(focused ? "›" : " ") \(number)\(Term.truncate(option.title, to: titleWidth))"
            let detailLine = "      " + Term.truncate(option.detail, to: max(1, safeWidth - 6))
            lines.append(focused ? Term.inverse(titleLine) : titleLine)
            lines.append(focused ? Term.bold(detailLine) : Term.dim(detailLine))
        }

        while lines.count < safeHeight - footerHeight {
            lines.append("")
        }

        lines.append(Term.dim(String(repeating: "─", count: safeWidth)))
        lines.append(Term.dim("↑↓ move  PgUp/PgDn page  1-9 open"))
        lines.append(Term.dim("Enter open  Esc/q cancel"))
        return Array(lines.prefix(safeHeight))
    }
}
