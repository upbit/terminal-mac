public enum TerminalText {
    /// Escape plain display text, never action arguments or trusted terminal protocol bytes.
    public static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0...0x1f, 0x7f...0x9f:
                result += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
