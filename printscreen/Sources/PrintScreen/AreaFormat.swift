import AppKit

// MARK: - Palcos prontos da área (widescreen 16:9, mobile 9:16, quadrada 1:1, tela inteira) e a tecla que move a área

enum SelectionFormat: String, CaseIterable {
    case free, widescreen, mobile, square

    var title: String {
        switch self {
        case .free: return "Livre"
        case .widescreen: return "Widescreen"
        case .mobile: return "Mobile"
        case .square: return "Quadrada"
        }
    }

    /// Proporção em números inteiros (16 por 9, 1 por 1); nil = livre.
    var parts: (w: CGFloat, h: CGFloat)? {
        switch self {
        case .free: return nil
        case .widescreen: return (16, 9)
        case .mobile: return (9, 16)
        case .square: return (1, 1)
        }
    }

    /// Largura ÷ altura (nil = livre).
    var ratio: CGFloat? { parts.map { $0.w / $0.h } }

    var ratioLabel: String? {
        switch self {
        case .free: return nil
        case .widescreen: return "16:9"
        case .mobile: return "9:16"
        case .square: return "1:1"
        }
    }

    /// Tamanho do palco pronto, em pixels (Full HD e o quadrado das redes sociais).
    var presetPixels: CGSize? {
        switch self {
        case .free: return nil
        case .widescreen: return CGSize(width: 1920, height: 1080)
        case .mobile: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }

    var help: String {
        switch self {
        case .free: return "Área livre, do tamanho que você arrastar"
        case .widescreen: return "Palco widescreen 16:9 (1920 × 1080) no meio da tela"
        case .mobile: return "Palco vertical 9:16 (1080 × 1920), como a tela do celular, no meio da tela"
        case .square: return "Palco quadrado 1:1 (1080 × 1080) no meio da tela"
        }
    }

    var icon: NSImage? {
        switch self {
        case .free: return nil
        case .widescreen: return AreaIcon.widescreen
        case .mobile: return AreaIcon.mobile
        case .square: return AreaIcon.square
        }
    }

    /// O palco pronto no meio da tela (menor, com a mesma proporção, se a tela for menor que ele).
    func centered(in bounds: CGRect, scale: CGFloat) -> CGRect? {
        guard let px = presetPixels else { return nil }
        let s = max(scale, 1)
        let size = CGSize(width: px.width / s, height: px.height / s)
        let r = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        return snap(r, keepCenter: true, in: bounds, scale: scale)
    }

    /// Acerta a área em pixels inteiros com a proporção exata (1920 × 1080, não 1919 × 1080), dentro de `bounds`.
    /// `keepCenter`: cresce ou encolhe pelo meio; senão, o canto de cima à esquerda fica onde está.
    func snap(_ r: CGRect, keepCenter: Bool = false, in bounds: CGRect, scale: CGFloat) -> CGRect {
        guard let parts else { return r }
        let s = max(scale, 1)
        var k = max(1, (r.width * s / parts.w).rounded())
        while k > 1, k * parts.w / s > bounds.width || k * parts.h / s > bounds.height { k -= 1 }
        let w = k * parts.w / s, h = k * parts.h / s
        let x = ((keepCenter ? r.midX - w / 2 : r.minX) * s).rounded() / s
        let y = ((keepCenter ? r.midY - h / 2 : r.minY) * s).rounded() / s
        return CGRect(x: min(max(x, bounds.minX), bounds.maxX - w), y: min(max(y, bounds.minY), bounds.maxY - h), width: w, height: h)
    }

    /// Arrastar de `anchor` até `p` com a proporção travada (área nova ou canto puxado). O lado maior manda.
    static func corner(from anchor: CGPoint, to p: CGPoint, ratio: CGFloat, in bounds: CGRect) -> CGRect {
        let sx: CGFloat = p.x >= anchor.x ? 1 : -1, sy: CGFloat = p.y >= anchor.y ? 1 : -1
        let maxW = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let maxH = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        let w = min(max(abs(p.x - anchor.x), abs(p.y - anchor.y) * ratio), maxW, maxH * ratio)
        let h = w / ratio
        return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    /// A alça `handle` (0…7, a partir do canto de cima à esquerda, em sentido horário) puxada até `p`, mantendo a proporção.
    /// Nos cantos, o canto oposto fica parado; nos lados, a área cresce igual para os dois lados.
    static func resize(_ r: CGRect, handle: Int, to p: CGPoint, ratio: CGFloat, in bounds: CGRect) -> CGRect {
        switch handle {
        case 0: return corner(from: CGPoint(x: r.maxX, y: r.maxY), to: p, ratio: ratio, in: bounds)
        case 2: return corner(from: CGPoint(x: r.minX, y: r.maxY), to: p, ratio: ratio, in: bounds)
        case 4: return corner(from: CGPoint(x: r.minX, y: r.minY), to: p, ratio: ratio, in: bounds)
        case 6: return corner(from: CGPoint(x: r.maxX, y: r.minY), to: p, ratio: ratio, in: bounds)
        case 3, 7:
            let anchorX = handle == 3 ? r.minX : r.maxX
            let sx: CGFloat = p.x >= anchorX ? 1 : -1
            let maxW = sx > 0 ? bounds.maxX - anchorX : anchorX - bounds.minX
            let maxH = 2 * min(r.midY - bounds.minY, bounds.maxY - r.midY)
            let w = min(abs(p.x - anchorX), maxW, maxH * ratio)
            let h = w / ratio
            return CGRect(x: sx > 0 ? anchorX : anchorX - w, y: r.midY - h / 2, width: w, height: h)
        default:
            let anchorY = handle == 5 ? r.minY : r.maxY
            let sy: CGFloat = p.y >= anchorY ? 1 : -1
            let maxH = sy > 0 ? bounds.maxY - anchorY : anchorY - bounds.minY
            let maxW = 2 * min(r.midX - bounds.minX, bounds.maxX - r.midX)
            let h = min(abs(p.y - anchorY), maxH, maxW / ratio)
            let w = h * ratio
            return CGRect(x: r.midX - w / 2, y: sy > 0 ? anchorY : anchorY - h, width: w, height: h)
        }
    }
}

/// Tecla que, segurada, faz o arrastar mover a área (mesmo com uma ferramenta escolhida).
enum MoveModifier: String, CaseIterable {
    case option, command, control

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command: return .command
        case .control: return .control
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        }
    }

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        }
    }
}

// MARK: - Ícones vetoriais dos palcos (desenhados em código, nítidos em qualquer tela, como um SVG)

enum AreaIcon {
    private static let canvas = NSSize(width: 20, height: 16)

    static let widescreen = icon { drawFrame(CGRect(x: 1, y: 2.9, width: 18, height: 10.2), radius: 2.6) }
    static let square = icon { drawFrame(CGRect(x: 3.5, y: 1.5, width: 13, height: 13), radius: 2.6) }
    static let mobile = icon {
        // Celular em pé, com a ilha no alto da tela.
        drawFrame(CGRect(x: 5.8, y: 0.6, width: 8.4, height: 14.8), radius: 2.6)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: CGRect(x: 8.6, y: 12.3, width: 2.8, height: 1.1), xRadius: 0.55, yRadius: 0.55).fill()
    }
    static let fullScreen = icon {
        // Monitor: tela com vidro por dentro, pescoço e pé.
        drawFrame(CGRect(x: 1, y: 4.6, width: 18, height: 10.9), radius: 2.2)
        NSColor.black.setFill()
        NSBezierPath(rect: CGRect(x: 9.2, y: 2, width: 1.6, height: 2.8)).fill()
        NSBezierPath(roundedRect: CGRect(x: 6, y: 0.6, width: 8, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
    }

    /// Contorno arredondado com um vidro translúcido por dentro, no estilo dos símbolos do sistema.
    private static func drawFrame(_ rect: CGRect, radius: CGFloat) {
        NSColor.black.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        outline.lineWidth = 1.5
        outline.stroke()
        NSColor.black.withAlphaComponent(0.32).setFill()
        let inner = max(radius - 1.6, 0.6)
        NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: inner, yRadius: inner).fill()
    }

    /// Imagem modelo: a barra pinta de branco (ou da cor do botão).
    private static func icon(_ draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        return image
    }
}
