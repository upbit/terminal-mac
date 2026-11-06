import Foundation
import XCTest
import TerminalMacCore
import TerminalUI

final class TerminalTextTests: XCTestCase {
    private func assertPlainText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }, file: file, line: line)
    }

    func testEveryC0AndC1ControlIsEscaped() {
        for value in Array(0...0x1f) + Array(0x7f...0x9f) {
            let result = TerminalText.escaped(String(UnicodeScalar(value)!))
            XCTAssertEqual(result, "\\u{\(String(value, radix: 16))}")
            assertPlainText(result)
        }
    }

    func testTerminalSequencesIncludingIncompleteOnesBecomePlainText() {
        let payloads = [
            "\u{1b}]52;c;VEVTVA==\u{7}",
            "\u{1b}]0;fake title\u{1b}\\",
            "\u{1b}[2J\u{1b}[H", "\u{1b}Pdata\u{1b}\\", "\u{1b}_Gdata\u{1b}\\",
            "\u{9d}52;c;VEVTVA==\u{9c}", "\u{9b}2J",
            "\rforged\nline\t\u{8}\u{7}", "\u{1b}", "\u{1b}]52;"
        ]
        for payload in payloads {
            let escaped = TerminalText.escaped(payload)
            assertPlainText(escaped)
            XCTAssertEqual(TerminalText.escaped(escaped), escaped)
            XCTAssertEqual([Span(payload)].rendered, escaped)
        }
    }

    func testOrdinaryUnicodeAndLiteralBackslashesAreUnchanged() {
        let text = "Hello \u{4e2d}\u{6587} \u{1f30d} \u{1f469}\u{200d}\u{1f4bb} e\u{301} \\u{1b}"
        XCTAssertEqual(TerminalText.escaped(text), text)
        XCTAssertEqual(Span(text).text, text)
    }

    func testSpanMutationAndTruncationUseEscapedWidth() {
        var span = Span("initial")
        span.text = "a\u{1b}]52;c;VEVTVA==\u{7}b"
        let expected = "a\\u{1b}]52;c;VEVTVA==\\u{7}b"
        XCTAssertEqual(span.text, expected)
        XCTAssertEqual([span].width, expected.count)
        for limit in 0...40 {
            let fitted = [span].truncated(limit)
            XCTAssertLessThanOrEqual(fitted.width, limit)
            assertPlainText(fitted.rendered)
        }
    }

    func testApplicationStyleAndCursorSequencesStillWork() {
        let style = "\u{1b}[31m"
        let span = Span("x\u{1b}[2J", style)
        XCTAssertEqual([span].rendered, style + "x\\u{1b}[2J" + Theme.reset)
        XCTAssertEqual(Box.line(column: 2, row: 3, width: [span].width + 2, [span]),
                       "\u{1b}[3;2H" + style + "x\\u{1b}[2J" + Theme.reset + "  ")
        let split = [Span("\u{1b}"), Span("]52;c;VEVTVA=="), Span("\u{7}")]
        assertPlainText(split.rendered)
    }

    func testMailboxPayloadUnchangedButErrorDisplayIsEscaped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-text-test-\(UUID().uuidString)")
        let mailbox = try Mailbox(directory, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = "literal\ttext\n\u{1b}]52;c;VEVTVA==\u{7}"
        let request = Request(action: "type", arguments: ["text": payload], timeout: 5)
        let task = Task { try await mailbox.call(request) }
        defer { task.cancel() }
        var received: Request?
        for _ in 0..<200 {
            received = try mailbox.requests().first
            if received != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(received?.arguments["text"], payload)
        try mailbox.respond(Reply(id: request.id, error: payload))
        do {
            _ = try await task.value
            XCTFail("Expected guest error")
        } catch {
            XCTAssertEqual(error.localizedDescription, payload)
            let rendered = Box.line(column: 1, row: 1, width: 100, [Span(error.localizedDescription)])
            XCTAssertTrue(rendered.contains("\\u{1b}]52;c;VEVTVA==\\u{7}"))
            assertPlainText(String(rendered.dropFirst("\u{1b}[1;1H".count)))
        }
    }
}
