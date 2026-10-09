import CloudKit
import UserNotifications

/// The notifications shown for requests, each found by the request record its CloudKit push
/// names.
enum RequestNotifications {
    /// The request record a notification is for.
    static func recordID(of notification: UNNotification) -> CKRecord.ID? {
        (CKNotification(fromRemoteNotificationDictionary: notification.request.content.userInfo) as? CKQueryNotification)?.recordID
    }

    /// Takes down the delivered notifications `isOver` picks.
    static func remove(where isOver: (CKRecord.ID, UNNotification) -> Bool) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications().filter { note in
            recordID(of: note).map { isOver($0, note) } ?? false
        }.map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
}
