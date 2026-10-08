// Writes a 20-minute App Store Connect API token to the path given, without printing it.
// Used by asc.sh; the key, ID and issuer are the "opProxy releases" team key (CLAUDE.md).
import CryptoKit
import Foundation
let keyPEM = try! String(contentsOfFile: NSString(string: "~/.appstoreconnect/private_keys/AuthKey_DFK3C9K7M4.p8").expandingTildeInPath, encoding: .utf8)
let key = try! P256.Signing.PrivateKey(pemRepresentation: keyPEM)
func b64(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
let header = b64(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "DFK3C9K7M4", "typ": "JWT"]))
let now = Int(Date().timeIntervalSince1970)
let payload = b64(try! JSONSerialization.data(withJSONObject: ["iss": "bb77b192-3592-48c2-9168-4ba2c99cf7d0", "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"]))
let signature = b64(try! key.signature(for: Data("\(header).\(payload)".utf8)).rawRepresentation)
FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: Data("\(header).\(payload).\(signature)".utf8), attributes: [.posixPermissions: 0o600])
