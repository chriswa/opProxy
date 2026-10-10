import CloudKit
import FeedProtocol
import Foundation
import Security

/// The pairing secrets of sealed zones (`CloudFeed.sealedZonePrefix`), by zone name, in a
/// keychain group the notification extension shares, readable after the first unlock so it
/// can fill in a request on a locked phone.
enum PairingSecrets {
    private static let service = "opProxy pairing"
    private static let group = "7H2524M5TN.com.chriswa.opproxy.phone"

    private static func query(_ zone: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: zone, kSecAttrAccessGroup as String: group]
    }

    static func save(_ secret: Data, zone: String) -> Bool {
        delete(zone: zone)
        var item = query(zone)
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(zone: String) {
        SecItemDelete(query(zone) as CFDictionary)
    }

    /// The zone's pairing key: nil for an unsealed zone, or one with no secret stored.
    static func key(zone: String) -> PairingKey? {
        guard zone.hasPrefix(CloudFeed.sealedZonePrefix) else { return nil }
        var item = query(zone)
        item[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &out) == errSecSuccess, let secret = out as? Data else { return nil }
        return PairingKey(secret: secret)
    }

    /// A field the Mac wrote: as stored in an unsealed zone; in a sealed one, opened with its
    /// pairing key, else nil.
    static func macField(_ field: String, of record: CKRecord) -> String? {
        guard let value = record.encryptedValues[field] as? String else { return nil }
        let zone = record.recordID.zoneID.zoneName
        guard zone.hasPrefix(CloudFeed.sealedZonePrefix) else { return value }
        guard let key = key(zone: zone) else {
            print("opProxy: no pairing key for \(zone)")
            return nil
        }
        do {
            return try SealedField.open(value, with: key, recordType: record.recordType, field: field,
                                        recordName: record.recordID.recordName, from: .mac)
        } catch {
            print("opProxy: \(record.recordType).\(field) of \(record.recordID.recordName) didn't open: \(error)")
            return nil
        }
    }
}
