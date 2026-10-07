import CryptoKit
import Darwin
import Foundation
import Security

/// Verifies a running process from the code signature the kernel loaded when it was exec'd,
/// for when the executable on disk has been deleted or replaced since (an agent upgraded
/// under a running session). The Security framework's process check re-reads the file, so
/// it fails then.
///
/// The kernel keeps the signature's CodeDirectories and CMS blob, chose one CodeDirectory
/// (its cdhash), and while the process is `CS_VALID` every page it ran matched that
/// directory. So authenticating that directory authenticates the running code:
/// - the CMS signs the primary (slot 0) CodeDirectory, and its signer chains to Apple Root CA;
/// - any other directory is vouched for by the CMS's signed hash-agility attributes, which
///   list each directory's hash. Signatures with SHA-1 and SHA-256 directories put SHA-1 in
///   slot 0 and the kernel runs the SHA-256 one, so this is the usual case for them.
enum KernelSignature {
    static func process(_ pid: pid_t, satisfies requirement: SigningRequirement) -> Bool {
        guard let cdhash = CodeSignature.cdhash(pid: pid), let blob = blob(pid) else { return false }
        return verify(blob: blob, kernelCDHash: cdhash, requirement: requirement)
    }

    static func verify(blob: Data, kernelCDHash: Data, requirement: SigningRequirement) -> Bool {
        guard let signature = SignatureBlob(blob), let primary = signature.primary, let cms = signature.cms,
              let signer = CMSSigner(cms: cms, content: primary.bytes),
              let running = authenticated(signature.directories, kernelCDHash: kernelCDHash, agility: signer.agility)
        else { return false }
        return running.identifier == requirement.identifier && signer.leafOU == requirement.team
            && signer.isAnchoredAtAppleRoot
    }

    /// The directory the kernel runs, if the signature vouches for it.
    static func authenticated(_ directories: [CodeDirectory], kernelCDHash: Data,
                              agility: HashAgility) -> CodeDirectory? {
        guard let running = directories.first(where: { $0.cdhash == kernelCDHash }) else { return nil }
        if running.slot == CodeDirectory.primarySlot { return running }
        if let cdhash = running.cdhash, agility.cdhashes.contains(cdhash) { return running }
        if let digest = running.digest, let tag = running.hashType.agilityTag, agility.digests[tag] == digest {
            return running
        }
        return nil
    }

    /// The kernel's copy of `pid`'s embedded signature (a SuperBlob).
    static func blob(_ pid: pid_t) -> Data? {
        // Asked with too small a buffer, the kernel fails with ERANGE and writes a header
        // whose second word is the size it needs.
        var header = [UInt8](repeating: 0, count: 8)
        guard csops(pid, CS_OPS_BLOB, &header, header.count) == -1, errno == ERANGE else { return nil }
        let size = Int(BigEndian.u32(header, 4))
        guard size > 8, size <= 64 << 20 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard csops(pid, CS_OPS_BLOB, &buffer, buffer.count) == 0 else { return nil }
        return Data(buffer)
    }
}

private let CS_OPS_BLOB: UInt32 = 10

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

/// A code signature requirement of the form opProxy uses for vendors: Apple-anchored, this
/// signing identifier, and this leaf certificate OU (a Developer ID certificate's Team ID).
public struct SigningRequirement: Equatable {
    public let identifier: String
    public let team: String

    public init(identifier: String, team: String) {
        self.identifier = identifier
        self.team = team
    }

    /// The same requirement in Apple's requirement language.
    public var text: String {
        #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)""#
    }
}

// MARK: Parsing

enum BigEndian {
    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        b[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// The SuperBlob of an embedded signature: its CodeDirectories and CMS signature.
struct SignatureBlob {
    let directories: [CodeDirectory]
    let cms: Data?

    var primary: CodeDirectory? { directories.first { $0.slot == CodeDirectory.primarySlot } }

    static let magic: UInt32 = 0xfade0cc0
    static let cmsSlot: UInt32 = 0x10000
    static let cmsMagic: UInt32 = 0xfade0b01

    /// Nil for anything malformed, including a slot that appears twice.
    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 12, BigEndian.u32(b, 0) == Self.magic else { return nil }
        let length = Int(BigEndian.u32(b, 4)), count = Int(BigEndian.u32(b, 8))
        guard length <= b.count, count <= 64, 12 + count * 8 <= length else { return nil }
        var directories: [CodeDirectory] = [], cms: Data?, seen: Set<UInt32> = []
        for i in 0..<count {
            let slot = BigEndian.u32(b, 12 + i * 8), offset = Int(BigEndian.u32(b, 16 + i * 8))
            guard seen.insert(slot).inserted, offset + 8 <= length else { return nil }
            let blobLength = Int(BigEndian.u32(b, offset + 4))
            guard blobLength >= 8, offset + blobLength <= length else { return nil }
            let bytes = Array(b[offset..<offset + blobLength])
            if CodeDirectory.slots.contains(slot) {
                guard let directory = CodeDirectory(slot: slot, bytes: bytes) else { return nil }
                directories.append(directory)
            } else if slot == Self.cmsSlot {
                guard BigEndian.u32(bytes, 0) == Self.cmsMagic else { return nil }
                cms = Data(bytes.dropFirst(8))
            }
        }
        self.directories = directories
        self.cms = cms
    }
}

struct CodeDirectory: Equatable {
    static let primarySlot: UInt32 = 0
    /// The primary slot and the alternate-directory slots.
    static let slots: Set<UInt32> = [primarySlot, 0x1000, 0x1001, 0x1002, 0x1003, 0x1004]
    static let magic: UInt32 = 0xfade0c02

    enum HashType: UInt8 {
        case sha1 = 1, sha256 = 2, sha256Truncated = 3, sha384 = 4

        /// The SECOidTag the CMS hash-agility V2 attribute keys this algorithm's digest by.
        var agilityTag: Int? {
            switch self {
            case .sha1: return 4
            case .sha256: return 192
            case .sha256Truncated, .sha384: return nil
            }
        }
    }

    let slot: UInt32
    /// The whole directory blob, as hashed and as the CMS signs it.
    let bytes: [UInt8]
    let hashType: HashType
    let identifier: String

    init?(slot: UInt32, bytes: [UInt8]) {
        // Fields to the hash type end at 38; the identifier offset is at 20.
        guard bytes.count >= 38, BigEndian.u32(bytes, 0) == Self.magic,
              Int(BigEndian.u32(bytes, 4)) == bytes.count,
              let hashType = HashType(rawValue: bytes[37]) else { return nil }
        let identOffset = Int(BigEndian.u32(bytes, 20))
        guard identOffset < bytes.count, let end = bytes[identOffset...].firstIndex(of: 0) else { return nil }
        self.slot = slot
        self.bytes = bytes
        self.hashType = hashType
        self.identifier = String(decoding: bytes[identOffset..<end], as: UTF8.self)
    }

    /// The directory's full hash in its own algorithm.
    var digest: Data? {
        switch hashType {
        case .sha1: return Data(Insecure.SHA1.hash(data: bytes))
        case .sha256: return Data(SHA256.hash(data: bytes))
        case .sha256Truncated: return Data(SHA256.hash(data: bytes).prefix(20))
        case .sha384: return Data(SHA384.hash(data: bytes))
        }
    }

    /// The 20-byte hash the kernel identifies code by.
    var cdhash: Data? { digest.map { Data($0.prefix(20)) } }
}

// MARK: CMS

/// The CMS signature's hash-agility attributes: V1 lists every directory's cdhash; V2 maps
/// a digest algorithm (SECOidTag) to that directory's full hash.
struct HashAgility: Equatable {
    var cdhashes: [Data] = []
    var digests: [Int: Data] = [:]
}

/// A CMS signature with exactly one signer, whose signature over `content` is valid and whose
/// certificate is trusted for code signing.
struct CMSSigner {
    let chain: [SecCertificate]
    let agility: HashAgility

    init?(cms: Data, content: [UInt8]) {
        var decoderOut: CMSDecoder?
        guard CMSDecoderCreate(&decoderOut) == errSecSuccess, let decoder = decoderOut else { return nil }
        let updated = cms.withUnsafeBytes { raw in
            raw.baseAddress.map { CMSDecoderUpdateMessage(decoder, $0, raw.count) } ?? errSecParam
        }
        var signers = 0
        guard updated == errSecSuccess,
              CMSDecoderSetDetachedContent(decoder, Data(content) as CFData) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers == 1
        else { return nil }
        // Trust is evaluated below, at the signing timestamp: Developer ID certificates
        // expire, and signatures stay valid past that when timestamped.
        var status = CMSSignerStatus.unsigned
        var trustOut: SecTrust?
        let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil)
        guard let policy,
              CMSDecoderCopySignerStatus(decoder, 0, policy, false, &status, &trustOut, nil) == errSecSuccess,
              status == .valid, let trust = trustOut
        else { return nil }
        var timestamp: CFAbsoluteTime = 0
        if CMSDecoderCopySignerTimestamp(decoder, 0, &timestamp) == errSecSuccess {
            SecTrustSetVerifyDate(trust, Date(timeIntervalSinceReferenceDate: timestamp) as CFDate)
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        guard SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !chain.isEmpty
        else { return nil }
        self.chain = chain
        self.agility = Self.agility(decoder)
    }

    /// Apple Root CA, by SHA-256 fingerprint: what `anchor apple generic` requires.
    static let appleRootCA = Data([
        0xB0, 0xB1, 0x73, 0x0E, 0xCB, 0xC7, 0xFF, 0x45, 0x05, 0x14, 0x2C, 0x49, 0xF1, 0x29, 0x5E, 0x6E,
        0xDA, 0x6B, 0xCA, 0xED, 0x7E, 0x2C, 0x68, 0xC5, 0xBE, 0x91, 0xB5, 0xA1, 0x10, 0x01, 0xF0, 0x24,
    ])

    var isAnchoredAtAppleRoot: Bool {
        chain.last.map { Data(SHA256.hash(data: SecCertificateCopyData($0) as Data)) } == Self.appleRootCA
    }

    /// The leaf certificate's first subject OU, as `certificate leaf[subject.OU]` reads it.
    var leafOU: String? {
        let values = SecCertificateCopyValues(chain[0], [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any]
        let subject = values?[kSecOIDX509V1SubjectName as String] as? [String: Any]
        let fields = subject?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        return fields.first { $0[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String }?[
            kSecPropertyKeyValue as String] as? String
    }

    /// Security.framework exports these readers but declares them only in private headers.
    private typealias CopyV1 = @convention(c) (OpaquePointer, Int, UnsafeMutablePointer<Unmanaged<CFData>?>) -> OSStatus
    private typealias CopyV2 = @convention(c) (OpaquePointer, Int, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> OSStatus
    private static let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)
    private static let copyV1 = dlsym(security, "CMSDecoderCopySignerAppleCodesigningHashAgility")
        .map { unsafeBitCast($0, to: CopyV1.self) }
    private static let copyV2 = dlsym(security, "CMSDecoderCopySignerAppleCodesigningHashAgilityV2")
        .map { unsafeBitCast($0, to: CopyV2.self) }

    private static func agility(_ decoder: CMSDecoder) -> HashAgility {
        let ref = OpaquePointer(Unmanaged.passUnretained(decoder).toOpaque())
        var agility = HashAgility()
        var v1: Unmanaged<CFData>?
        if copyV1?(ref, 0, &v1) == errSecSuccess, let data = v1?.takeRetainedValue() as Data?,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            agility.cdhashes = plist["cdhashes"] as? [Data] ?? []
        }
        var v2: Unmanaged<CFDictionary>?
        if copyV2?(ref, 0, &v2) == errSecSuccess, let dict = v2?.takeRetainedValue() as? [Int: Data] {
            agility.digests = dict
        }
        return agility
    }
}
