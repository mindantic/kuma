import AppKit
import KumaCore

enum SingleInstance {
    static let showNotification = Notification.Name("com.mindantic.kuma.show")
    private static var lockDescriptor: Int32 = -1

    static func claim() -> Bool {
        KumaPaths.ensure()
        let path = KumaPaths.appSupport.appendingPathComponent("kuma.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockDescriptor = fd
        return true
    }

    static func handOffAndExit() -> Never {
        DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }

    static func observe(_ handler: @escaping () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: showNotification, object: nil, queue: .main) { _ in handler() }
    }
}
