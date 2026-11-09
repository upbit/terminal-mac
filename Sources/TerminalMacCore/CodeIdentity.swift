import Foundation
import Security

/// Pins guest updates to the running helper's designated code requirement.
public struct CodeIdentity {
    private let requirement: SecRequirement
    public init(referenceURL: URL? = nil) throws {
        var reference: SecStaticCode?
        if let referenceURL {
            guard SecStaticCodeCreateWithPath(referenceURL as CFURL, [], &reference) == errSecSuccess else {
                throw Failure("Cannot inspect trusted helper")
            }
        } else {
            var running: SecCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                  SecCodeCopyStaticCode(running, [], &reference) == errSecSuccess else {
                throw Failure("Cannot inspect running helper identity")
            }
        }
        var designated: SecRequirement?
        guard let reference,
              SecStaticCodeCheckValidity(reference, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(reference, [], &designated) == errSecSuccess, let designated else {
            throw Failure("Trusted helper has no valid code identity")
        }
        requirement = designated
    }
    public func validate(_ candidate: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw Failure("Guest helper update is invalid or has a different signing identity")
        }
    }
}
