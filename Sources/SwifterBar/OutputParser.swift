import Foundation

// MARK: - OutputParser

nonisolated enum OutputParser {
    static let maxLineLength = 4096     // 4KB per line
    static let maxLineCount = 500
    static let maxImageDataSize = 1_048_576  // 1MB decoded
    static let maxImageDimension = 1024

    /// Parse raw script output into structured menu items.
    /// Output format: header lines, then `---`, then body lines.
    /// Each line can have `| key=value key=value` parameters after a pipe.
    static func parse(_ output: String) -> [ParsedMenuItem] {
        let rawLines = output.components(separatedBy: "\n")
        var items: [ParsedMenuItem] = []
        var inBody = false

        for (index, rawLine) in rawLines.enumerated() {
            guard index < maxLineCount else { break }

            // Strip null bytes
            let line = rawLine.replacingOccurrences(of: "\0", with: "")

            // Enforce max line length
            let truncated = line.count > maxLineLength
                ? String(line.prefix(maxLineLength))
                : line

            // Skip empty trailing lines
            if truncated.isEmpty && index == rawLines.count - 1 { continue }

            // Separator detection
            if truncated == "---" {
                if !inBody {
                    inBody = true
                } else {
                    items.append(ParsedMenuItem(text: "", params: .empty, isSeparator: true))
                }
                continue
            }

            let parsed = parseLine(truncated)
            var item = parsed
            item.isHeader = !inBody
            items.append(item)
        }

        return items
    }

    /// Parse a single line into text + parameters.
    /// Format: `Display text | key=value key2=value2`
    static func parseLine(_ line: String) -> ParsedMenuItem {
        // Split on first ` | ` (space-pipe-space) to separate text from params
        let parts = line.split(separator: " | ", maxSplits: 1)

        let text: String
        let paramString: String?

        if parts.count == 2 {
            text = String(parts[0])
            paramString = String(parts[1])
        } else if let pipeRange = line.range(of: "|", options: .backwards),
                  line[line.startIndex..<pipeRange.lowerBound].contains(where: { !$0.isWhitespace }) {
            // Fallback: split on last `|` if no ` | ` found
            // But only if there's actual text before it
            text = String(line[line.startIndex..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            paramString = String(line[pipeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            text = line
            paramString = nil
        }

        let params = paramString.map { parseParams($0) } ?? .empty
        return ParsedMenuItem(text: text, params: params)
    }

    /// Parse key=value pairs from the parameter string.
    static func parseParams(_ str: String) -> MenuItemParams {
        var params = MenuItemParams()
        var bashParamsList: [(Int, String)] = []

        for token in tokenize(str) {
            guard let eqIndex = token.firstIndex(of: "=") else { continue }
            let key = String(token[token.startIndex..<eqIndex])
            let value = String(token[token.index(after: eqIndex)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))

            switch key {
            case "color":
                let colors = value.split(separator: ",", maxSplits: 1)
                params.color = String(colors[0])
                if colors.count > 1 {
                    params.colorDark = String(colors[1])
                }
            case "sfimage":
                params.sfimage = value
            case "href":
                params.href = value
            case "bash":
                params.bash = value
            case "refresh":
                params.refresh = value.lowercased() == "true"
            case "terminal":
                params.terminal = value.lowercased() == "true"
            case "font":
                params.font = value
            case "size":
                if let size = Double(value) {
                    params.size = CGFloat(max(1, min(size, 200)))
                }
            case "image":
                params.image = value
            case "templateImage":
                params.templateImage = value
            case "alwaysVisible":
                params.alwaysVisible = value.lowercased() == "true"
            default:
                // Handle param1= through param10=
                if key.hasPrefix("param") {
                    if let numStr = key.dropFirst(5).isEmpty ? nil : String(key.dropFirst(5)) as String?,
                       let num = Int(numStr) {
                        bashParamsList.append((num, value))
                    }
                }
            }
        }

        // Sort bash params by number and collect values
        if !bashParamsList.isEmpty {
            params.bashParams = bashParamsList.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }

        return params
    }

    /// Tokenize a parameter string, respecting quoted values.
    /// e.g. `color=red bash='/usr/bin/echo' param1="hello world"` → ["color=red", "bash='/usr/bin/echo'", "param1=\"hello world\""]
    private static func tokenize(_ str: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character?

        for char in str {
            if let q = inQuote {
                current.append(char)
                if char == q { inQuote = nil }
            } else if char == "'" || char == "\"" {
                current.append(char)
                inQuote = char
            } else if char == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
