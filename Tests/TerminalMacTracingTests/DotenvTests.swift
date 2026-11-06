import Foundation
import XCTest
@testable import TerminalMacTracing

final class DotenvTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testParsesQuotesCommentsExportsAndOnlyAllowedKeys() throws {
        let values = try LangfuseEnvironment.parse("""
        # comment
        export LANGFUSE_PUBLIC_KEY = "pk-test" # inline comment
        LANGFUSE_SECRET_KEY='sk-test=with#hash'
        LANGFUSE_BASE_URL=https://example.com # another comment
        LANGFUSE_SESSION_ID="literal${USER}$(command)"
        LANGFUSE_USER_ID="line\\nquote\\\"backslash\\\\"
        LANGFUSE_SAMPLE_RATE=0.5
        PATH=/must/not/be/loaded
        OPENAI_API_KEY="not-read"
        """)
        XCTAssertEqual(values["LANGFUSE_PUBLIC_KEY"], "pk-test")
        XCTAssertEqual(values["LANGFUSE_SECRET_KEY"], "sk-test=with#hash")
        XCTAssertEqual(values["LANGFUSE_BASE_URL"], "https://example.com")
        XCTAssertEqual(values["LANGFUSE_SESSION_ID"], "literal${USER}$(command)")
        XCTAssertEqual(values["LANGFUSE_USER_ID"], "line\nquote\"backslash\\")
        XCTAssertEqual(values["LANGFUSE_SAMPLE_RATE"], "0.5")
        XCTAssertNil(values["PATH"]); XCTAssertNil(values["OPENAI_API_KEY"])
    }

    func testBOMWindowsLineEndingsAndEmptyValues() throws {
        let values = try LangfuseEnvironment.parse("\u{feff}LANGFUSE_PUBLIC_KEY=pk-test\r\nLANGFUSE_SECRET_KEY=\r\nLANGFUSE_PUBLIC_KEY='replacement'\r\n")
        XCTAssertEqual(values["LANGFUSE_PUBLIC_KEY"], "replacement")
        XCTAssertEqual(values["LANGFUSE_SECRET_KEY"], "")
    }

    func testMalformedValuesNeverAppearInErrors() {
        for text in ["LANGFUSE_SECRET_KEY='SECRET", "LANGFUSE_SECRET_KEY=\"SECRET\" unexpected", "LANGFUSE_SECRET_KEY"] {
            XCTAssertThrowsError(try LangfuseEnvironment.parse(text)) { error in
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
                XCTAssertTrue(error.localizedDescription.contains("line 1"))
            }
        }
    }

    func testReadsDefaultFileAndPreservesProcessPrecedenceWithoutMutatingIt() throws {
        let directory = try temporary()
        try Data("LANGFUSE_PUBLIC_KEY=pk-file\nLANGFUSE_SECRET_KEY=sk-file\nLANGFUSE_SAMPLE_RATE=1\n".utf8)
            .write(to: directory.appendingPathComponent(".env"))
        let process = ["LANGFUSE_PUBLIC_KEY": "pk-process", "LANGFUSE_SAMPLE_RATE": "0", "UNRELATED": "ignored"]
        let result = try LangfuseEnvironment.load(process: process, directory: directory)
        XCTAssertEqual(result["LANGFUSE_PUBLIC_KEY"], "pk-process")
        XCTAssertEqual(result["LANGFUSE_SECRET_KEY"], "sk-file")
        XCTAssertEqual(result["LANGFUSE_SAMPLE_RATE"], "0")
        XCTAssertNil(result["UNRELATED"])
        XCTAssertNil(process["LANGFUSE_SECRET_KEY"])
    }

    func testExplicitFileWorksFromAnotherWorkingDirectory() throws {
        let directory = try temporary()
        let elsewhere = try temporary()
        let file = directory.appendingPathComponent("private.env")
        try Data("LANGFUSE_PUBLIC_KEY=pk-file\n".utf8).write(to: file)
        let result = try LangfuseEnvironment.load(process: ["TERMINAL_MAC_ENV_FILE": file.path], directory: elsewhere)
        XCTAssertEqual(result["LANGFUSE_PUBLIC_KEY"], "pk-file")
        XCTAssertNil(result["TERMINAL_MAC_ENV_FILE"])
    }

    func testProcessHostAliasOverridesFileBaseURL() throws {
        let directory = try temporary()
        try Data("LANGFUSE_BASE_URL=https://file.example.com\n".utf8).write(to: directory.appendingPathComponent(".env"))
        let result = try LangfuseEnvironment.load(process: ["LANGFUSE_HOST": "https://process.example.com"], directory: directory)
        XCTAssertNil(result["LANGFUSE_BASE_URL"])
        XCTAssertEqual(result["LANGFUSE_HOST"], "https://process.example.com")
    }

    func testMissingDefaultIsOptionalButMissingExplicitFileIsAnError() throws {
        let directory = try temporary()
        XCTAssertEqual(try LangfuseEnvironment.load(process: ["LANGFUSE_PUBLIC_KEY": "pk-process"], directory: directory),
                       ["LANGFUSE_PUBLIC_KEY": "pk-process"])
        XCTAssertThrowsError(try LangfuseEnvironment.load(process: ["TERMINAL_MAC_ENV_FILE": "missing.env"], directory: directory))
        XCTAssertEqual(try LangfuseEnvironment.load(process: ["LANGFUSE_TRACING_ENABLED": "false", "TERMINAL_MAC_ENV_FILE": "missing.env"], directory: directory),
                       ["LANGFUSE_TRACING_ENABLED": "false"])
    }

    func testRejectsSymlinkOversizedAndInvalidUTF8Files() throws {
        let directory = try temporary()
        let file = directory.appendingPathComponent(".env")
        let target = directory.appendingPathComponent("target")
        try Data("LANGFUSE_SECRET_KEY=secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try LangfuseEnvironment.load(process: [:], directory: directory))
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 65, count: 65_537).write(to: file)
        XCTAssertThrowsError(try LangfuseEnvironment.load(process: [:], directory: directory))
        try Data([0xff]).write(to: file)
        XCTAssertThrowsError(try LangfuseEnvironment.load(process: [:], directory: directory))
    }

    func testInternalHTTPRequiresExplicitOptInAndKeepsKeysOutOfErrors() throws {
        var env = ["LANGFUSE_BASE_URL": "http://internal.example.com", "LANGFUSE_PUBLIC_KEY": "pk-test", "LANGFUSE_SECRET_KEY": "sk-test"]
        XCTAssertThrowsError(try LangfuseConfiguration.load(env))
        env["LANGFUSE_ALLOW_INSECURE_HTTP"] = "true"
        XCTAssertEqual(try LangfuseConfiguration.load(env)?.endpoint.scheme, "http")
        env["LANGFUSE_BASE_URL"] = "ftp://internal.example.com"
        XCTAssertThrowsError(try LangfuseConfiguration.load(env))
    }
}
