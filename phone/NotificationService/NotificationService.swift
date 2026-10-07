import CloudKit
import FeedProtocol
import UserNotifications

/// Turns CloudKit's generic "new request" push into the request itself: the push carries
/// only the record's ID, and its contents are encrypted values only this user's devices can
/// read.
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
            if let record = try? await db.record(for: id),
               let json = record.encryptedValues[CloudFeed.Item.item] as? String,
               let item = FeedItem.parse(json), let doc = item.parsed {
                content.title = doc.title
                content.subtitle = doc.subtitle ?? ""
                content.body = doc.confirm
                content.threadIdentifier = "requests"
                content.userInfo["itemId"] = item.id
            }
            finish()
        }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        guard let content, let deliver else { return }
        self.deliver = nil
        deliver(content)
    }
}
