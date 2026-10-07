import CryptoKit
import Darwin
import XCTest
@testable import OpProxyCore

final class KernelSignatureTests: XCTestCase {
    /// Signed with a SHA-1 primary directory and a SHA-256 alternate; the kernel runs the
    /// alternate, which only the CMS's hash-agility attributes vouch for.
    static let multiHashBinary = "/usr/sbin/kextstat"
    static let multiHashRequirement = SigningRequirement(identifier: "com.apple.kextstat", team: "Apple Software")

    // MARK: Real signatures, as the kernel loaded them

    func testAlternateDirectoryVouchedForByHashAgility() throws {
        let loaded = try Loaded(Self.multiHashBinary)
        let signature = try XCTUnwrap(SignatureBlob(loaded.blob))
        XCTAssertEqual(signature.directories.map(\.slot), [0, 0x1000])
        XCTAssertEqual(signature.directories.map(\.hashType), [.sha1, .sha256])
        XCTAssertEqual(signature.directories[1].cdhash, loaded.cdhash, "the kernel runs the SHA-256 alternate")
        XCTAssertTrue(KernelSignature.verify(blob: loaded.blob, kernelCDHash: loaded.cdhash,
                                             requirement: Self.multiHashRequirement))
        XCTAssertTrue(KernelSignature.process(loaded.pid, satisfies: Self.multiHashRequirement))
    }

    func testAgilityAttributesListEveryDirectory() throws {
        let loaded = try Loaded(Self.multiHashBinary)
        let signature = try XCTUnwrap(SignatureBlob(loaded.blob))
        let signer = try XCTUnwrap(CMSSigner(cms: XCTUnwrap(signature.cms), content: XCTUnwrap(signature.primary).bytes))
        XCTAssertEqual(signer.agility.cdhashes, signature.directories.compactMap(\.cdhash))
        XCTAssertEqual(signer.agility.digests[4], signature.directories[0].digest)
        XCTAssertEqual(signer.agility.digests[192], signature.directories[1].digest)
        XCTAssertTrue(signer.isAnchoredAtAppleRoot)
        XCTAssertEqual(signer.leafOU, "Apple Software")
    }

    func testRequirementMustMatch() throws {
        let loaded = try Loaded(Self.multiHashBinary)
        for requirement in [SigningRequirement(identifier: "com.apple.kextstat", team: "Q6L2SF6YDW"),
                            SigningRequirement(identifier: "com.anthropic.claude-code", team: "Apple Software")] {
            XCTAssertFalse(KernelSignature.verify(blob: loaded.blob, kernelCDHash: loaded.cdhash, requirement: requirement),
                           requirement.text)
        }
    }

    func testTamperedAlternateDirectoryIsRejected() throws {
        // A kernel running an edited alternate directory: the CMS still verifies over the
        // primary, but the agility attributes don't list the edited directory's hash.
        let loaded = try Loaded(Self.multiHashBinary)
        let tampered = try flipLastByte(of: 0x1000, in: loaded.blob)
        let directory = try XCTUnwrap(SignatureBlob(tampered)?.directories.first { $0.slot == 0x1000 })
        XCTAssertEqual(directory.identifier, "com.apple.kextstat")
        let signature = try XCTUnwrap(SignatureBlob(tampered))
        let signer = try XCTUnwrap(CMSSigner(cms: XCTUnwrap(signature.cms), content: XCTUnwrap(signature.primary).bytes),
                                   "the primary is untouched, so the CMS still verifies")
        XCTAssertNil(KernelSignature.authenticated(signature.directories, kernelCDHash: try XCTUnwrap(directory.cdhash),
                                                   agility: signer.agility))
        XCTAssertFalse(KernelSignature.verify(blob: tampered, kernelCDHash: try XCTUnwrap(directory.cdhash),
                                              requirement: Self.multiHashRequirement))
    }

    func testTamperedPrimaryDirectoryIsRejected() throws {
        let loaded = try Loaded(Self.multiHashBinary)
        let tampered = try flipLastByte(of: 0, in: loaded.blob)
        let primary = try XCTUnwrap(SignatureBlob(tampered)?.primary)
        XCTAssertNil(CMSSigner(cms: try XCTUnwrap(SignatureBlob(tampered)?.cms), content: primary.bytes))
        XCTAssertFalse(KernelSignature.verify(blob: tampered, kernelCDHash: try XCTUnwrap(primary.cdhash),
                                              requirement: Self.multiHashRequirement))
    }

    func testKernelHashMatchingNoDirectoryIsRejected() throws {
        let loaded = try Loaded(Self.multiHashBinary)
        XCTAssertFalse(KernelSignature.verify(blob: loaded.blob, kernelCDHash: Data(repeating: 0, count: 20),
                                              requirement: Self.multiHashRequirement))
    }

    func testDeveloperIDAgentVerifies() throws {
        // Single SHA-256 directory, Developer ID chain, timestamped.
        guard let claude = ["/opt/homebrew/bin/claude", NSHomeDirectory() + "/.local/bin/claude"]
            .first(where: FileManager.default.isExecutableFile) else { throw XCTSkip("Claude Code not installed") }
        let loaded = try Loaded(URL(fileURLWithPath: claude).resolvingSymlinksInPath().path)
        XCTAssertEqual(SignatureBlob(loaded.blob)?.directories.map(\.hashType), [.sha256])
        XCTAssertTrue(KernelSignature.process(loaded.pid, satisfies: AgentKind.claude.signingRequirement))
        XCTAssertFalse(KernelSignature.process(loaded.pid, satisfies: AgentKind.codex.signingRequirement))
    }

    func testAdHocMultiHashSignatureIsRejected() throws {
        // Anyone can ad-hoc sign with any identifier; there is no CMS signer to trust.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kernelsig-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("claude").path
        try FileManager.default.copyItem(atPath: Self.multiHashBinary, toPath: copy)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", "--digest-algorithm=sha1,sha256", "-i", "com.anthropic.claude-code", copy]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)

        let loaded = try Loaded(copy)
        let signature = try XCTUnwrap(SignatureBlob(loaded.blob))
        XCTAssertEqual(signature.directories.map(\.hashType), [.sha1, .sha256])
        XCTAssertEqual(signature.directories.map(\.identifier), ["com.anthropic.claude-code", "com.anthropic.claude-code"])
        XCTAssertEqual(signature.cms, Data(), "ad-hoc signatures carry an empty CMS blob")
        XCTAssertFalse(KernelSignature.process(loaded.pid, satisfies: AgentKind.claude.signingRequirement))
    }

    // MARK: Which directory the signature vouches for

    let primary = directory(slot: 0, .sha1, "primary")
    let alternate = directory(slot: 0x1000, .sha256, "alternate")
    let sha384 = directory(slot: 0x1001, .sha384, "sha384")
    var directories: [CodeDirectory] { [primary, alternate, sha384] }

    func testPrimaryNeedsNoAgility() {
        XCTAssertEqual(KernelSignature.authenticated(directories, kernelCDHash: primary.cdhash!, agility: HashAgility()),
                       primary)
    }

    func testAlternateNeedsAgility() {
        XCTAssertNil(KernelSignature.authenticated(directories, kernelCDHash: alternate.cdhash!, agility: HashAgility()))
    }

    func testAgilityV1ListsCDHashes() {
        let agility = HashAgility(cdhashes: [primary.cdhash!, alternate.cdhash!])
        XCTAssertEqual(KernelSignature.authenticated(directories, kernelCDHash: alternate.cdhash!, agility: agility), alternate)
        XCTAssertNil(KernelSignature.authenticated(directories, kernelCDHash: sha384.cdhash!, agility: agility),
                     "a directory the list leaves out")
    }

    func testAgilityV2MapsAlgorithmToFullDigest() {
        let agility = HashAgility(digests: [4: primary.digest!, 192: alternate.digest!])
        XCTAssertEqual(KernelSignature.authenticated(directories, kernelCDHash: alternate.cdhash!, agility: agility), alternate)
        let wrongAlgorithm = HashAgility(digests: [4: alternate.digest!])
        XCTAssertNil(KernelSignature.authenticated(directories, kernelCDHash: alternate.cdhash!, agility: wrongAlgorithm))
        let truncated = HashAgility(digests: [192: alternate.cdhash!])
        XCTAssertNil(KernelSignature.authenticated(directories, kernelCDHash: alternate.cdhash!, agility: truncated),
                     "V2 holds full digests")
    }

    func testSHA384AlternateViaV1() {
        XCTAssertEqual(sha384.digest?.count, 48)
        let agility = HashAgility(cdhashes: [sha384.cdhash!])
        XCTAssertEqual(KernelSignature.authenticated(directories, kernelCDHash: sha384.cdhash!, agility: agility), sha384)
    }

    func testCDHashIsTheDigestTruncated() {
        XCTAssertEqual(primary.cdhash, Data(Insecure.SHA1.hash(data: primary.bytes)))
        XCTAssertEqual(alternate.cdhash, Data(SHA256.hash(data: alternate.bytes).prefix(20)))
        XCTAssertEqual(sha384.cdhash, Data(SHA384.hash(data: sha384.bytes).prefix(20)))
    }

    // MARK: Parsing

    func testParsesSlotsAndCMS() throws {
        let blob = superBlob([(0, primary.bytes), (0x1000, alternate.bytes), (0x10000, cmsWrapper([1, 2, 3]))])
        let signature = try XCTUnwrap(SignatureBlob(blob))
        XCTAssertEqual(signature.directories, [primary, alternate])
        XCTAssertEqual(signature.primary, primary)
        XCTAssertEqual(signature.cms, Data([1, 2, 3]))
        XCTAssertEqual(signature.directories.map(\.identifier), ["primary", "alternate"])
    }

    func testRejectsMalformedBlobs() {
        let good = superBlob([(0, primary.bytes)])
        XCTAssertNotNil(SignatureBlob(good))
        XCTAssertNil(SignatureBlob(good.prefix(good.count - 1)), "truncated")
        XCTAssertNil(SignatureBlob(superBlob([(0, primary.bytes), (0, alternate.bytes)])), "duplicate slot")
        XCTAssertNil(SignatureBlob(superBlob([(0, Array(primary.bytes.dropLast()))])), "directory length mismatch")
        var badMagic = [UInt8](good)
        badMagic[0] = 0
        XCTAssertNil(SignatureBlob(Data(badMagic)))
        var unknownHash = primary.bytes
        unknownHash[37] = 9
        XCTAssertNil(SignatureBlob(superBlob([(0, unknownHash)])), "unknown hash type")
    }

    func testRequirementText() {
        XCTAssertEqual(CodeSignature.onePasswordCLI,
                       #"anchor apple generic and identifier "com.1password.op" and certificate leaf[subject.OU] = "2BUA8C4S2C""#)
    }

    // MARK: Helpers

    /// `path` exec'd but suspended before it runs, with the signature the kernel loaded.
    struct Loaded {
        let pid: pid_t
        let blob: Data
        let cdhash: Data

        init(_ path: String) throws {
            guard FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("\(path) not present") }
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED))
            var pid: pid_t = 0
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
            defer { argv.forEach { free($0) } }
            guard posix_spawn(&pid, path, nil, &attributes, argv, nil) == 0 else { throw XCTSkip("couldn't spawn \(path)") }
            self.pid = pid
            Loaded.spawned.append(pid)
            blob = try XCTUnwrap(KernelSignature.blob(pid))
            cdhash = try XCTUnwrap(CodeSignature.cdhash(pid: pid))
        }

        static var spawned: [pid_t] = []
    }

    override func tearDown() {
        for pid in Loaded.spawned {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        Loaded.spawned = []
    }

    func flipLastByte(of slot: UInt32, in blob: Data) throws -> Data {
        var b = [UInt8](blob)
        let count = Int(BigEndian.u32(b, 8))
        let index = try XCTUnwrap((0..<count).first { BigEndian.u32(b, 12 + $0 * 8) == slot })
        let offset = Int(BigEndian.u32(b, 16 + index * 8))
        b[offset + Int(BigEndian.u32(b, offset + 4)) - 1] ^= 0xff
        return Data(b)
    }
}

private func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }

private func directory(slot: UInt32, _ hashType: CodeDirectory.HashType, _ identifier: String) -> CodeDirectory {
    var header = be32(Int(CodeDirectory.magic)) + be32(0) + be32(0x20400) + be32(0) + be32(0) + be32(44)
    header += [UInt8](repeating: 0, count: 12) + [0, hashType.rawValue] + [UInt8](repeating: 0, count: 6)
    var bytes = header + Array(identifier.utf8) + [0]
    bytes.replaceSubrange(4..<8, with: be32(bytes.count))
    return CodeDirectory(slot: slot, bytes: bytes)!
}

private func cmsWrapper(_ payload: [UInt8]) -> [UInt8] {
    be32(Int(SignatureBlob.cmsMagic)) + be32(8 + payload.count) + payload
}

private func superBlob(_ entries: [(UInt32, [UInt8])]) -> Data {
    var offset = 12 + entries.count * 8
    var index: [UInt8] = [], body: [UInt8] = []
    for (slot, bytes) in entries {
        index += be32(Int(slot)) + be32(offset)
        body += bytes
        offset += bytes.count
    }
    return Data(be32(Int(SignatureBlob.magic)) + be32(offset) + be32(entries.count) + index + body)
}
