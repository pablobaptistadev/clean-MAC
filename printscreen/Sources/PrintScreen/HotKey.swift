import AppKit
import Carbon.HIToolbox

// MARK: - Atalho global (Carbon RegisterEventHotKey: não precisa de permissão de Acessibilidade)

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Modificadores no formato do Carbon (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32
    var key: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), key: "2")
    private static let defaultsKey = "shortcut"

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    static func load() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data) else { return standard }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    static let functionKeys: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16"
    ]

    /// Atalho a partir de uma tecla pressionada. Exige ⌘, ⌥ ou ⌃ — menos nas teclas F, que podem ir sozinhas.
    static func from(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        let function = functionKeys[event.keyCode]
        guard function != nil || flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return nil }
        let key: String
        if let function {
            key = function
        } else if event.keyCode == UInt16(kVK_Space) {
            key = "Espaço"
        } else {
            key = (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, key: key)
    }
}

@MainActor
final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    /// Registra o atalho. Devolve false se outro app já usa essa combinação.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5052_5453), id: 1) // "PRTS"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
