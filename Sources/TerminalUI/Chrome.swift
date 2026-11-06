import Foundation

/// A run of text with one style. Widths count characters, so keep to single-width glyphs.
public struct Span {
    private var displayText: String
    public var text: String {
        get { displayText }
        set { displayText = TerminalText.escaped(newValue) }
    }
    /// Only application-owned terminal sequences belong in style, never external text.
    public var style: String = ""
    public init(_ text: String, _ style: String = "") { displayText = TerminalText.escaped(text); self.style = style }
}

extension Array where Element == Span {
    public var width: Int { reduce(0) { $0 + $1.text.count } }
    public func truncated(_ limit: Int) -> [Span] {
        var result: [Span] = [], remaining = Swift.max(0, limit)
        for span in self where remaining > 0 {
            if span.text.count <= remaining { result.append(span); remaining -= span.text.count }
            else { result.append(Span(String(span.text.prefix(Swift.max(0, remaining - 1))) + "…", span.style)); remaining = 0 }
        }
        return result
    }
    public var rendered: String { map { $0.style.isEmpty ? $0.text : $0.style + $0.text + Theme.reset }.joined() }
}

/// Tokyo Night-flavoured palette. Respects NO_COLOR (https://no-color.org).
public enum Theme {
    public static let color = ProcessInfo.processInfo.environment["NO_COLOR"].map(\.isEmpty) ?? true
    public static let reset = "\u{1b}[0m"
    public static func fg(_ hex: UInt32) -> String { color ? "\u{1b}[38;2;\(hex >> 16 & 255);\(hex >> 8 & 255);\(hex & 255)m" : "" }
    public static func bg(_ hex: UInt32) -> String { color ? "\u{1b}[48;2;\(hex >> 16 & 255);\(hex >> 8 & 255);\(hex & 255)m" : "" }
    public static let bold = "\u{1b}[1m"

    public static let text = fg(0xc0caf5), muted = fg(0x737aa2), faint = fg(0x545c7e), border = fg(0x3b4261)
    public static let accent = fg(0x7aa2f7), green = fg(0x9ece6a), yellow = fg(0xe0af68), red = fg(0xf7768e), magenta = fg(0xbb9af7), cyan = fg(0x7dcfff)
    public static let badge = bold + fg(0x1a1b26) + bg(0x7aa2f7)
    public static let key = bold + fg(0x7dcfff) + bg(0x24283b)
    public static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
}

public enum Box {
    /// A rounded box with an optional title in its top edge. The interior is not cleared.
    public static func frame(column: Int, row: Int, width: Int, height: Int, title: [Span] = [], color: String = Theme.border) -> String {
        guard width >= 2, height >= 2 else { return "" }
        var output = "\u{1b}[\(row);\(column)H"
        let label = title.isEmpty ? [] : [Span("─ ", color)] + title.truncated(width - 6) + [Span(" ", color)]
        output += [Span("╭", color)].rendered + label.rendered + [Span(String(repeating: "─", count: max(0, width - 2 - label.width)) + "╮", color)].rendered
        for offset in 1..<(height - 1) {
            output += "\u{1b}[\(row + offset);\(column)H" + [Span("│", color)].rendered + "\u{1b}[\(row + offset);\(column + width - 1)H" + [Span("│", color)].rendered
        }
        output += "\u{1b}[\(row + height - 1);\(column)H" + [Span("╰" + String(repeating: "─", count: width - 2) + "╯", color)].rendered
        return output
    }
    /// Writes `spans` at a position, padding with spaces to `width` so stale text is erased.
    public static func line(column: Int, row: Int, width: Int, _ spans: [Span]) -> String {
        let fitted = spans.truncated(width)
        return "\u{1b}[\(row);\(column)H" + fitted.rendered + String(repeating: " ", count: max(0, width - fitted.width))
    }
}

