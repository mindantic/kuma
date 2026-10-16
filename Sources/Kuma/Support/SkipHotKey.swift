import AppKit
import Carbon.HIToolbox
import Foundation

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let `default` = HotKey(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey), key: "esc")

    var symbols: [String] {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(key)
        return parts
    }

    var label: String { symbols.joined() }

    static func from(_ event: NSEvent) -> HotKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers & ~UInt32(shiftKey) != 0 else { return nil }
        return HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: name(for: event))
    }

    private static func name(for event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Escape: "esc", kVK_Space: "space", kVK_Return: "return", kVK_Tab: "tab",
            kVK_Delete: "delete", kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "home", kVK_End: "end",
            kVK_PageUp: "page up", kVK_PageDown: "page down",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return characters.isEmpty ? "key \(event.keyCode)" : characters.uppercased()
    }
}

final class SkipHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registeredKey: HotKey?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    var isRegistered: Bool { hotKeyRef != nil }

    func update(active: Bool, key: HotKey) {
        if !active || registeredKey != key { unregister() }
        if active { register(key) }
    }

    func register(_ key: HotKey) {
        guard hotKeyRef == nil else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4B554D41), id: 1)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            registeredKey = key
        } else {
            hotKeyRef = nil
        }
    }

    func unregister() {
        registeredKey = nil
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
