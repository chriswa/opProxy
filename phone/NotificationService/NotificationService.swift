import CloudKit
import FeedProtocol
import UserNotifications

/// Turns CloudKit's generic "new request" push into the request itself: the push carries
/// only the record's ID, and its contents are encrypted values only this user's devices can
/// read. Meanwhile it takes down the notifications of earlier requests that are over, in case
/// the silent pushes that would have woken the app for them didn't arrive.
final class NotificationService: UNNotificationServiceExtension {
    private var content: UNMutableNotificationContent?
    private var deliver: ((UNNotificationContent) -> Void)?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.interruptionLevel = .timeSensitive
        self.content = content
        deliver = contentHandler
        guard let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification,
              let id = note.recordID
        else { return contentHandler(content) }
        Task {
            let db = CKContainer(identifier: CloudFeed.container).privateCloudDatabase
            async let cleared: Void = Self.clearOverRequests(in: db, except: id)
            if let record = try? await db.record(for: id),
               let json = record.encryptedValues[CloudFeed.Item.item] as? String,
               let item = FeedItem.parse(json), let doc = item.parsed {
                content.title = doc.title
                content.subtitle = doc.subtitle ?? ""
                // Which Mac, for a phone paired with several: its name is in the zone's hello.
                if let hello = try? await db.record(for: CKRecord.ID(recordName: CloudFeed.State.hello, zoneID: id.zoneID)),
                   let json = hello.encryptedValues[CloudFeed.State.message] as? String,
                   let message = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                   let name = (message["mac"] as? [String: Any])?["name"] as? String {
                    content.subtitle = [content.subtitle, "on \(name)"].filter { !$0.isEmpty }.joined(separator: " · ")
                }
                content.body = doc.confirm
                content.threadIdentifier = "requests"
            }
            await cleared
            finish()
        }
    }

    /// Takes down the notifications of requests that were answered, timed out or deleted.
    private static func clearOverRequests(in db: CKDatabase, except current: CKRecord.ID) async {
        let ids = await UNUserNotificationCenter.current().deliveredNotifications()
            .compactMap(RequestNotifications.recordID).filter { $0 != current }
        guard !ids.isEmpty,
              let results = try? await db.records(for: ids, desiredKeys: [CloudFeed.Item.item, CloudFeed.Item.note])
        else { return }
        let over = Set(results.compactMap { id, result -> CKRecord.ID? in
            switch result {
            case .success(let record):
                let expires = (record.encryptedValues[CloudFeed.Item.item] as? String).flatMap(FeedItem.parse)?.expires
                return record.encryptedValues[CloudFeed.Item.note] != nil || (expires.map { $0 < Date() } ?? false) ? id : nil
            case .failure(let error):
                return (error as? CKError)?.code == .unknownItem ? id : nil
            }
        })
        await RequestNotifications.remove { id, _ in over.contains(id) }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        guard let content, let deliver else { return }
        self.deliver = nil
        deliver(content)
    }
}
