import Foundation
import UserNotifications

/// Native delivery is opt-in and available only in the packaged app. Injected
/// operations keep tests away from permission dialogs and real notifications.
@MainActor
final class SystemNoticeDelivery: NSObject, UNUserNotificationCenterDelegate {
    typealias AuthorizationCompletion = @MainActor @Sendable (Bool) -> Void
    typealias Authorize = @MainActor (@escaping AuthorizationCompletion) -> Void
    private let authorize: Authorize
    private let post: (String) -> Void
    private var last: (message: String, time: Date)?
    var onOpen: (() -> Void)?

    init(authorize: @escaping Authorize, post: @escaping (String) -> Void) {
        self.authorize = authorize
        self.post = post
        super.init()
    }

    func requestAuthorization(completion: @escaping AuthorizationCompletion) { authorize(completion) }

    @discardableResult
    func deliver(_ message: String, enabled: Bool, windowVisible: Bool, now: Date = Date()) -> Bool {
        guard enabled, !windowVisible else { return false }
        if let last, last.message == message, now.timeIntervalSince(last.time) < 30 { return false }
        last = (message, now)
        post(message)
        return true
    }

    static func live() -> SystemNoticeDelivery {
        let packaged = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
        let delivery = SystemNoticeDelivery(authorize: { completion in
            guard packaged else { completion(false); return }
            Task { @MainActor in
                do { completion(try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) }
                catch { completion(false) }
            }
        }, post: { message in
            guard packaged else { return }
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = "Waple"
                content.body = message
                do {
                    try await center.add(UNNotificationRequest(identifier: "waple.background", content: content, trigger: nil))
                } catch { NSLog("%@", "[Waple] notification delivery failed: \(error)") }
            }
        })
        if packaged { UNUserNotificationCenter.current().delegate = delivery }
        return delivery
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await openApplication()
    }

    private func openApplication() { onOpen?() }
}
