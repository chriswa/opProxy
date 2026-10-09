---
name: notification-filtering
description: Use if the developer wants to fix stale or unwanted iPhone notifications for requests already answered on the Mac.
---

# Hiding notifications for requests that are over

## The problem

The phone takes down a request's notification once the request is answered, denied or timed out, but only best effort:

- The Mac's update or deletion of a `FeedItem` reaches the phone as a silent push (the `changed-requests-<zone>` subscription in `phone/App/FeedModel.swift`). iOS throttles silent pushes, and doesn't deliver them at all to an app the user force-quit or that has Background App Refresh off. Then the notification stays until the app opens or the next request's push runs the notification extension.
- A request answered on the Mac within a second or two still buzzes the phone: the new-request push was already sent, and the extension has to show something.

## The fix

Apple's notification filtering entitlement, `com.apple.developer.usernotifications.filtering`, lets a notification service extension hide a push by passing an empty `UNNotificationContent()` to its content handler. With it:

1. In `NotificationService`, when the request's record already has a `note`, or is gone, or has expired, deliver empty content instead of the request.
2. Optionally make `changed-requests-<zone>` a visible, mutable-content push the extension always hides after taking down the request's notification. Visible pushes aren't throttled like silent ones and reach a force-quit app.

The entitlement has to be requested from Apple with a form (search for "notification service extension filtering entitlement request"); it isn't self-serve. Approval isn't guaranteed. Ask the developer whether it's been granted before writing code that needs it.

## Footguns

- The entitlement goes on the extension, `com.chriswa.opproxy.phone.notifications`, not the app. Add it to that target's `entitlements` in `phone/project.yml`; a build signed with a profile that lacks it fails to provision.
- Without the entitlement, empty content doesn't hide anything: iOS shows the push's original alert. Same if the extension crashes, runs out of time or memory, or can't reach iCloud. Every push the extension handles needs alert text that's acceptable to show on its own, because sometimes it will be.
- iOS only runs the extension for a push with an alert, so a visible `changed-requests` push must keep `title`/`alertBody` and `shouldSendMutableContent`. Don't also leave `shouldSendContentAvailable` on, or the app wakes for the same change as well.
- `serviceExtensionTimeWillExpire` delivers whatever content is ready. For a push meant to be hidden, start from empty content so a timeout hides it rather than showing the fallback text.
- Subscriptions are saved by ID on every launch, so changing one's options keeps its ID and replaces it; a renamed ID leaves the old subscription on existing phones until it's deleted with `modifySubscriptions(saving:deleting:)`.
- The Mac deletes and rewrites records "written under an earlier membership" (`CloudTransport`). That fires the creation subscription again, so filtering on "record already has a `note`" also covers a rewritten answered request; don't filter on record age instead.
