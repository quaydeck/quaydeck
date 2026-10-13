import Darwin
import Foundation
import Security

/// Who vouches for a listener's executable, judged by its code signature.
///
/// Path alone misjudges apps that install helpers into the home folder. Figma's
/// font helper runs from `~/Library/Application Support/Figma/` and listens all day,
/// so on location alone it is "unrecognised". Its signature says Figma, Inc., issued
/// by Apple, and that is the better signal.
public protocol SignatureChecking: Sendable {
    /// The organisation a process's executable is signed by, when the signature is
    /// intact and chains to Apple: Apple's own software, the Mac App Store, or a
    /// Developer ID. Nil for ad-hoc, self-signed, broken or missing signatures.
    func trustedSigner(of pid: Int32) -> String?
}

public final class CodeSignatureChecker: SignatureChecking, @unchecked Sendable {
    /// Apple's own code, Mac App Store apps, and Developer ID apps (the leaf carries
    /// Apple's Developer ID extension and the intermediate is the Developer ID CA).
    static let requirement = "anchor apple"
        + " or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9])"
        + " or (anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13])"

    private let lock = NSLock()
    /// Keyed by pid and executable, so a reused pid running something else is
    /// checked afresh.
    private var cache: [String: String?] = [:]

    public init() {}

    public func trustedSigner(of pid: Int32) -> String? {
        guard pid > 1, let path = Self.executablePath(of: pid) else { return nil }
        let key = "\(pid):\(path)"

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let signer = Self.check(pid: pid)
        lock.lock()
        cache[key] = signer
        lock.unlock()
        return signer
    }

    /// The executable's path, straight from the kernel. Argument vectors are no use
    /// here: "Application Support" splits in two, and a process can rewrite its argv.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Asks the kernel about the running process rather than re-reading its file:
    /// macOS already validated every page it loaded, so this is quick, and a binary
    /// swapped on disk after launch cannot fool it. Uses no network, so there is no
    /// revocation lookup and nothing leaves the machine.
    static func check(pid: Int32) -> String? {
        var running: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &running) == errSecSuccess,
              let code = running else { return nil }

        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              SecCodeCheckValidity(code, [], compiled) == errSecSuccess else { return nil }

        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let onDisk = staticCode,
              SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String?
        else { return "Apple" }
        return organisation(fromSubject: summary)
    }

    /// "Developer ID Application: Figma, Inc. (T8RA8NE3B7)" -> "Figma, Inc."
    /// "Software Signing" (Apple's own) -> "Apple".
    static func organisation(fromSubject subject: String) -> String {
        var name = subject
        if let colon = name.firstIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        } else {
            return "Apple"
        }
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open])
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}

/// Canned signers per pid, for tests.
public struct StubSignatures: SignatureChecking {
    private let byPID: [Int32: String]

    public init(_ byPID: [Int32: String] = [:]) {
        self.byPID = byPID
    }

    public func trustedSigner(of pid: Int32) -> String? { byPID[pid] }
}
