import Carbon.HIToolbox
import Foundation

final class SkipHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    var isRegistered: Bool { hotKeyRef != nil }

    func register() {
        guard hotKeyRef == nil else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4B554D41), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    fileprivate func fire() {
        DispatchQueue.main.async { [onPress] in onPress() }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<SkipHotKey>.fromOpaque(userData).takeUnretainedValue().fire()
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
