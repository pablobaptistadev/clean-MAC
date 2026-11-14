import AppKit

// MARK: - Ajustes salvos (UserDefaults)

@MainActor
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    /// Ferramenta que já vem escolhida ao abrir a captura (nil = nenhuma).
    static var startTool: Tool? {
        get { defaults.string(forKey: "startTool").flatMap(Tool.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue ?? "", forKey: "startTool") }
    }

    /// Ao capturar, já começar com a última área escolhida.
    static var rememberSelection: Bool {
        get { defaults.bool(forKey: "rememberSelection") }
        set { defaults.set(newValue, forKey: "rememberSelection") }
    }

    /// Tecla que, segurada, faz o arrastar mover a área.
    static var moveModifier: MoveModifier {
        get { defaults.string(forKey: "moveModifier").flatMap(MoveModifier.init(rawValue:)) ?? .option }
        set { defaults.set(newValue.rawValue, forKey: "moveModifier") }
    }

    /// Formato da área (livre, widescreen, quadrada): vale também para a próxima captura.
    static var selectionFormat: SelectionFormat {
        get { defaults.string(forKey: "selectionFormat").flatMap(SelectionFormat.init(rawValue:)) ?? .free }
        set { defaults.set(newValue.rawValue, forKey: "selectionFormat") }
    }

    /// Com um palco (Widescreen, Mobile, Quadrada), as alças e a área nova mantêm a proporção.
    static var keepRatio: Bool {
        get { defaults.object(forKey: "keepRatio") == nil ? true : defaults.bool(forKey: "keepRatio") }
        set { defaults.set(newValue, forKey: "keepRatio") }
    }

    /// Última área escolhida, em pontos da tela onde foi feita (origem em cima).
    static func lastSelection() -> (display: UInt32, rect: CGRect)? {
        guard let saved = defaults.dictionary(forKey: "lastSelection"),
              let display = saved["display"] as? Int,
              let x = saved["x"] as? Double, let y = saved["y"] as? Double,
              let w = saved["w"] as? Double, let h = saved["h"] as? Double, w >= 4, h >= 4 else { return nil }
        return (UInt32(display), CGRect(x: x, y: y, width: w, height: h))
    }

    static func saveSelection(_ rect: CGRect, on screen: NSScreen) {
        guard let display = displayID(of: screen) else { return }
        defaults.set(["display": Int(display), "x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height],
                     forKey: "lastSelection")
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
