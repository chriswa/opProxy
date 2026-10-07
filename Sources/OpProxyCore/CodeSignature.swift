import Foundation
import Security

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

/// Code-signature checks against the vendors' Team IDs. A same-user attacker can replace
/// files but can't sign as 1Password, Anthropic or OpenAI.
public enum CodeSignature {
    public static let onePasswordCLI = SigningRequirement(identifier: "com.1password.op", team: "2BUA8C4S2C").text

    /// Whether the file at `path` (symlinks resolved) is validly signed and meets `requirement`.
    public static func file(_ path: String, satisfies requirement: String) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath() as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req) == errSecSuccess
    }

    /// Whether the running process `pid` is validly signed and meets `requirement`. The
    /// Security framework re-reads the executable from disk, so when an upgrade has deleted or
    /// replaced it since the process started, the signature the kernel loaded decides.
    public static func process(_ pid: pid_t, satisfies requirement: SigningRequirement) -> Bool {
        processOnDisk(pid, satisfies: requirement.text) || KernelSignature.process(pid, satisfies: requirement)
    }

    private static func processOnDisk(_ pid: pid_t, satisfies requirement: String) -> Bool {
        var code: SecCode?
        var req: SecRequirement?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess
        else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    /// The code directory hash of the file at `path`.
    public static func cdhash(file path: String) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        return uniqueHash(code)
    }

    /// The code directory hash the kernel recorded when this process was exec'd. Asking the
    /// Security framework instead would re-read the file at our path, which may have been
    /// replaced since.
    public static func cdhashOfSelf() -> Data? { cdhash(pid: getpid()) }

    /// The code directory hash of what the kernel actually loaded into `pid`, provided its
    /// signature is still valid (CS_VALID). Nil for invalid or unsigned code.
    public static func cdhash(pid: pid_t) -> Data? {
        var status: UInt32 = 0
        guard csops(pid, 0 /* CS_OPS_STATUS */, &status, MemoryLayout<UInt32>.size) == 0,
              status & 0x1 /* CS_VALID */ != 0 else { return nil }
        var hash = [UInt8](repeating: 0, count: 20)
        guard csops(pid, 5 /* CS_OPS_CDHASH */, &hash, hash.count) == 0 else { return nil }
        return Data(hash)
    }

    private static func uniqueHash(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }
}

/// Re-verifies a file's signature only when its identity on disk changes; a replaced or
/// rewritten file changes inode, size, mtime or ctime. The file can still be swapped between
/// this check and exec, so callers must also compare the returned code hash with the running
/// process's (`CodeSignature.cdhash(pid:)`).
public final class VerifiedFile {
    public let requirement: String
    private let lock = NSLock()
    private var verified: [String: (stamp: FileStamp, cdhash: Data)] = [:]

    public init(requirement: String) { self.requirement = requirement }

    /// The code hash of the file at `path` if it meets the requirement.
    public func check(_ path: String) -> Data? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let stamp = FileStamp(resolved) else { return nil }
        if let hit = lock.withLock({ verified[resolved] }), hit.stamp == stamp { return hit.cdhash }
        guard CodeSignature.file(resolved, satisfies: requirement),
              let cdhash = CodeSignature.cdhash(file: resolved) else { return nil }
        lock.withLock { verified[resolved] = (stamp, cdhash) }
        return cdhash
    }
}

struct FileStamp: Equatable {
    let dev: dev_t, ino: ino_t, size: off_t
    let mtime: timespec, ctime: timespec

    init?(_ path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        (dev, ino, size, mtime, ctime) = (st.st_dev, st.st_ino, st.st_size, st.st_mtimespec, st.st_ctimespec)
    }

    static func == (a: FileStamp, b: FileStamp) -> Bool {
        a.dev == b.dev && a.ino == b.ino && a.size == b.size
            && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
            && a.ctime.tv_sec == b.ctime.tv_sec && a.ctime.tv_nsec == b.ctime.tv_nsec
    }
}
