import XCTest
import Foundation
@testable import TerminalMacCore

final class CodeIdentityTests: XCTestCase {
    func testMatchingIdentityAcceptedAndOtherIdentityRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func signed(_ name: String, identifier: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: url.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--force", "--sign", "-", "--identifier", identifier, url.path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return url
        }
        let trusted = try signed("trusted", identifier: "dev.test.trusted")
        let identity = try CodeIdentity(referenceURL: trusted)
        let matching = root.appendingPathComponent("matching")
        try FileManager.default.copyItem(at: trusted, to: matching)
        XCTAssertNoThrow(try identity.validate(matching))
        let other = try signed("other", identifier: "dev.test.other")
        XCTAssertThrowsError(try identity.validate(other))
        let malformed = root.appendingPathComponent("malformed")
        try Data("not code".utf8).write(to: malformed)
        XCTAssertThrowsError(try identity.validate(malformed))
        let handle = try FileHandle(forWritingTo: matching)
        try handle.seek(toOffset: 4096); try handle.write(contentsOf: Data([0xff])); try handle.close()
        XCTAssertThrowsError(try identity.validate(matching))
    }
}
