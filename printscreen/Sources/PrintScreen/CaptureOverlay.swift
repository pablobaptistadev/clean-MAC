import AppKit
import UniformTypeIdentifiers

// MARK: - Marcações (seta, lápis, quadrado, círculo, texto)

enum Tool: String, CaseIterable {
    case pencil, arrow, rect, ellipse, text

    var symbol: String {
        switch self {
        case .pencil: return "pencil"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }

    var help: String {
        switch self {
        case .pencil: return "Lápis"
        case .arrow: return "Seta"
        case .rect: return "Quadrado"
        case .ellipse: return "Círculo"
        case .text: return "Texto"
        }
    }
}

/// Uma marcação desenhada sobre a captura, em coordenadas da tela (origem no canto de cima).
struct Mark {
    let tool: Tool
    var points: [CGPoint]
    let color: NSColor
    var text = ""

    static let lineWidth: CGFloat = 3
    static let font = NSFont.systemFont(ofSize: 22, weight: .semibold)

    private var box: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Desenha no contexto atual, que precisa estar com a origem em cima (flipped).
    func draw() {
        color.setStroke()
        color.setFill()
        switch tool {
        case .pencil:
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for p in points.dropFirst() { path.line(to: p) }
            if points.count == 1 { path.line(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            stroke(path)
        case .arrow:
            guard let a = points.first, let b = points.last, a != b else { return }
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head: CGFloat = 16
            let left = CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7))
            let right = CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7))
            let shaft = NSBezierPath()
            shaft.move(to: a)
            shaft.line(to: CGPoint(x: b.x - head * 0.7 * cos(angle), y: b.y - head * 0.7 * sin(angle)))
            stroke(shaft)
            let tip = NSBezierPath()
            tip.move(to: b)
            tip.line(to: left)
            tip.line(to: right)
            tip.close()
            tip.fill()
        case .rect:
            stroke(NSBezierPath(rect: box))
        case .ellipse:
            stroke(NSBezierPath(ovalIn: box))
        case .text:
            guard let origin = points.first else { return }
            (text as NSString).draw(at: origin, withAttributes: [.font: Mark.font, .foregroundColor: color])
        }
    }

    private func stroke(_ path: NSBezierPath) {
        path.lineWidth = Mark.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

// MARK: - Controle da captura: uma janela por tela

@MainActor
final class CaptureController {
    private var windows: [OverlayWindow] = []
    private let onClose: () -> Void

    init(shots: [ScreenShot], onClose: @escaping () -> Void) {
        self.onClose = onClose
        for shot in shots {
            let window = OverlayWindow(screen: shot.screen)
            let view = CaptureView(shot: shot, controller: self)
            window.contentView = view
            windows.append(window)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        // A tela onde está o mouse recebe o teclado (Esc, ⌘C, ⌘S…).
        let mouse = NSEvent.mouseLocation
        let main = windows.first { $0.frame.contains(mouse) } ?? windows.first
        main?.makeKey()
        main?.makeFirstResponder(main?.contentView)
    }

    /// Só uma tela tem seleção por vez.
    func selectionStarted(in view: CaptureView) {
        for window in windows {
            guard let other = window.contentView as? CaptureView, other !== view else { continue }
            other.clearSelection()
        }
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
    }

    func close() {
        for window in windows { window.orderOut(nil) }
        windows = []
        onClose()
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Acima da barra de menus e do Dock, mas abaixo dos menus (a paleta de cores abre por cima).
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Seletor com ferramentas

@MainActor
final class CaptureView: NSView, NSTextFieldDelegate {
    enum Drag {
        case none
        case select(start: CGPoint)
        case move(offset: CGPoint)
        case resize(handle: Int, original: CGRect)
        case draw
    }

    static let palette: [(name: String, color: NSColor)] = [
        ("Vermelho", .systemRed), ("Laranja", .systemOrange), ("Amarelo", .systemYellow), ("Verde", .systemGreen),
        ("Azul", .systemBlue), ("Roxo", .systemPurple), ("Branco", .white), ("Preto", .black)
    ]

    private let shot: ScreenShot
    private let image: NSImage
    private weak var controller: CaptureController?

    private(set) var selection: CGRect?
    private var editing = false
    private var drag: Drag = .none
    private var tool: Tool?
    private var color: NSColor = .systemRed
    private(set) var marks: [Mark] = []
    private var current: Mark?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero

    private let toolBar = ToolbarView()
    private let actionBar = ToolbarView()
    private var toolButtons: [Tool: ToolButton] = [:]
    private let colorButton = ToolButton(symbol: nil, help: "Cor")

    init(shot: ScreenShot, controller: CaptureController?) {
        self.shot = shot
        self.image = NSImage(cgImage: shot.image, size: shot.screen.frame.size)
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        buildToolbars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Barras de ferramentas

    private func buildToolbars() {
        for t in Tool.allCases {
            let button = ToolButton(symbol: t.symbol, help: t.help)
            button.onClick = { [weak self] in self?.choose(t) }
            toolButtons[t] = button
            toolBar.add(button)
        }
        colorButton.onClick = { [weak self] in self?.showPalette() }
        toolBar.add(colorButton)
        let undo = ToolButton(symbol: "arrow.uturn.backward", help: "Desfazer (⌘Z)")
        undo.onClick = { [weak self] in self?.undo() }
        toolBar.add(undo)
        toolBar.vertical = true

        let copy = ToolButton(symbol: "doc.on.doc", help: "Copiar (⌘C)")
        copy.onClick = { [weak self] in self?.copyToClipboard() }
        let save = ToolButton(symbol: "square.and.arrow.down", help: "Salvar PNG (⌘S)")
        save.onClick = { [weak self] in self?.saveAsPNG() }
        let close = ToolButton(symbol: "xmark", help: "Fechar (Esc)")
        close.onClick = { [weak self] in self?.controller?.close() }
        for b in [copy, save, close] { actionBar.add(b) }

        for bar in [toolBar, actionBar] {
            bar.isHidden = true
            addSubview(bar)
        }
        updateColorButton()
    }

    private func choose(_ t: Tool) {
        commitText()
        tool = tool == t ? nil : t
        for (k, b) in toolButtons { b.isActive = k == tool }
    }

    private func updateColorButton() {
        colorButton.image = Self.swatch(color, size: 18)
    }

    static func swatch(_ color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            ring.stroke()
            return true
        }
    }

    private func showPalette() {
        let menu = NSMenu()
        for entry in Self.palette {
            let item = NSMenuItem(title: entry.name, action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.image = Self.swatch(entry.color, size: 16)
            item.representedObject = entry.color
            item.state = entry.color == color ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let more = NSMenuItem(title: "Mais cores…", action: #selector(openColorPanel), keyEquivalent: "")
        more.target = self
        menu.addItem(more)
        let corner = CGPoint(x: colorButton.bounds.maxX + 8, y: colorButton.isFlipped ? 0 : colorButton.bounds.maxY)
        menu.popUp(positioning: nil, at: corner, in: colorButton)
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let picked = sender.representedObject as? NSColor else { return }
        color = picked
        updateColorButton()
    }

    @objc private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = color
        panel.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1)
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        color = sender.color
        updateColorButton()
    }

    private func layoutToolbars() {
        guard editing, let sel = selection else {
            toolBar.isHidden = true
            actionBar.isHidden = true
            return
        }
        toolBar.isHidden = false
        actionBar.isHidden = false
        let gap: CGFloat = 8
        let ts = toolBar.fittingSize
        var x = sel.maxX + gap
        if x + ts.width > bounds.maxX - 4 { x = sel.minX - gap - ts.width }
        if x < 4 { x = sel.maxX - ts.width - gap }
        let y = max(4, min(sel.maxY - ts.height, bounds.maxY - ts.height - 4))
        toolBar.frame = CGRect(x: x, y: y, width: ts.width, height: ts.height)

        let asz = actionBar.fittingSize
        let ax = max(4, min(sel.maxX - asz.width, bounds.maxX - asz.width - 4))
        var ay = sel.maxY + gap
        if ay + asz.height > bounds.maxY - 4 { ay = sel.minY - gap - asz.height }
        if ay < 4 { ay = sel.maxY - asz.height - gap }
        actionBar.frame = CGRect(x: ax, y: ay, width: asz.width, height: asz.height)
    }

    // MARK: Desenho

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.45).setFill()
        guard let sel = selection else {
            bounds.fill()
            drawHint()
            return
        }
        let dim = NSBezierPath(rect: bounds)
        dim.appendRect(sel)
        dim.windingRule = .evenOdd
        dim.fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sel).setClip()
        for mark in marks { mark.draw() }
        current?.draw()
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.black.withAlphaComponent(0.6).setStroke()
        border.stroke()
        border.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        border.stroke()

        if editing {
            for handle in handles(of: sel) {
                let r = CGRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8)
                NSColor.white.setFill()
                r.fill()
                NSColor.black.withAlphaComponent(0.6).setStroke()
                NSBezierPath(rect: r).stroke()
            }
        }
        drawSizeLabel(sel)
    }

    private func drawHint() {
        let text = "Arraste para escolher a área · Esc cancela" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let box = CGRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 10, width: size.width + 32, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 10), withAttributes: attrs)
    }

    private func drawSizeLabel(_ sel: CGRect) {
        let scale = CGFloat(shot.image.width) / bounds.width
        let text = "\(Int((sel.width * scale).rounded())) × \(Int((sel.height * scale).rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        var y = sel.minY - size.height - 12
        if y < 4 { y = sel.minY + 6 }
        let box = CGRect(x: sel.minX, y: y, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3), withAttributes: attrs)
    }

    private func handles(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        commitText()
        if editing, let sel = selection {
            if let index = handles(of: sel).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 7 }) {
                drag = .resize(handle: index, original: sel)
                return
            }
            if let tool, sel.contains(p) {
                if tool == .text {
                    beginText(at: p)
                } else {
                    current = Mark(tool: tool, points: [p, p], color: color)
                    drag = .draw
                }
                return
            }
            if tool == nil, sel.contains(p) {
                drag = .move(offset: CGPoint(x: p.x - sel.minX, y: p.y - sel.minY))
                return
            }
        }
        // Começa uma área nova (as marcações da anterior são descartadas).
        controller?.selectionStarted(in: self)
        marks = []
        editing = false
        selection = CGRect(origin: p, size: .zero)
        drag = .select(start: p)
        layoutToolbars()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        switch drag {
        case .select(let start):
            selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .move(let offset):
            guard var sel = selection else { return }
            sel.origin = CGPoint(x: min(max(0, p.x - offset.x), bounds.width - sel.width),
                                 y: min(max(0, p.y - offset.y), bounds.height - sel.height))
            selection = sel
            layoutToolbars()
        case .resize(let handle, let original):
            selection = resized(original, handle: handle, to: p)
            layoutToolbars()
        case .draw:
            guard var mark = current else { return }
            if mark.tool == .pencil { mark.points.append(p) } else { mark.points[1] = p }
            current = mark
        case .none:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .select:
            if let sel = selection, sel.width >= 4, sel.height >= 4 {
                editing = true
            } else {
                selection = nil
            }
        case .draw:
            if let current { marks.append(current) }
            current = nil
        default:
            break
        }
        drag = .none
        layoutToolbars()
        needsDisplay = true
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func resized(_ r: CGRect, handle: Int, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case 0: minX = p.x; minY = p.y
        case 1: minY = p.y
        case 2: maxX = p.x; minY = p.y
        case 3: maxX = p.x
        case 4: maxX = p.x; maxY = p.y
        case 5: maxY = p.y
        case 6: minX = p.x; maxY = p.y
        default: minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 4), height: max(abs(maxY - minY), 4))
    }

    func clearSelection() {
        commitText()
        selection = nil
        editing = false
        marks = []
        layoutToolbars()
        needsDisplay = true
    }

    // MARK: Texto

    private func beginText(at p: CGPoint) {
        let field = NSTextField(frame: CGRect(x: p.x, y: p.y, width: 260, height: 30))
        field.font = Mark.font
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Digite o texto"
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldEnter(_:))
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = CGPoint(x: p.x + 2, y: p.y + 2)
    }

    @objc private func textFieldEnter(_ sender: NSTextField) {
        commitText()
        window?.makeFirstResponder(self)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let width = (field.stringValue as NSString).size(withAttributes: [.font: Mark.font]).width
        field.frame.size.width = max(260, width + 30)
    }

    private func commitText() {
        guard let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { marks.append(Mark(tool: .text, points: [textOrigin], color: field.textColor ?? color, text: text)) }
        field.removeFromSuperview()
        textField = nil
        needsDisplay = true
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
    }

    // MARK: Teclado

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Esc
            if textField != nil { cancelText() } else { controller?.close() }
            return
        }
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copyToClipboard(); return
            case "s": saveAsPNG(); return
            case "z": undo(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if textField != nil { cancelText() } else { controller?.close() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    private func undo() {
        guard !marks.isEmpty else { return }
        marks.removeLast()
        needsDisplay = true
    }

    // MARK: Resultado

    /// A área escolhida na resolução real da tela, com as marcações por cima.
    func renderImage() -> (image: NSImage, png: Data)? {
        commitText()
        guard let sel = selection?.integral, sel.width >= 1, sel.height >= 1 else { return nil }
        let scale = CGFloat(shot.image.width) / bounds.width
        let pixelRect = CGRect(x: sel.minX * scale, y: sel.minY * scale, width: sel.width * scale, height: sel.height * scale).integral
        guard let crop = shot.image.cropping(to: pixelRect),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: crop.width, pixelsHigh: crop.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        // Marcações: mesma escala da tela e origem em cima, como no seletor.
        cg.translateBy(x: 0, y: CGFloat(crop.height))
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -sel.minX, y: -sel.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        for mark in marks { mark.draw() }
        NSGraphicsContext.restoreGraphicsState()
        rep.size = sel.size
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let image = NSImage(size: sel.size)
        image.addRepresentation(rep)
        return (image, png)
    }

    private func copyToClipboard() {
        guard let result = renderImage() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(result.png, forType: .png)
        if let tiff = result.image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        NSSound(named: "Pop")?.play()
        controller?.close()
    }

    private func saveAsPNG() {
        guard let result = renderImage() else { return }
        controller?.close()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName()
        let lastFolder = UserDefaults.standard.string(forKey: "saveFolder")
        panel.directoryURL = URL(fileURLWithPath: lastFolder ?? (NSHomeDirectory() + "/Desktop"))
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "saveFolder")
        do {
            try result.png.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Não foi possível salvar"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func fileName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        return "Captura de tela \(f.string(from: date)).png"
    }

    // Usado pelos testes de renderização.
    func setForTesting(selection: CGRect, marks: [Mark], tool: Tool? = nil) {
        self.selection = selection
        self.marks = marks
        self.editing = true
        self.tool = tool
        for (k, b) in toolButtons { b.isActive = k == tool }
        layoutToolbars()
        needsDisplay = true
    }
}

// MARK: - Barra de ferramentas (vidro escuro, ícones brancos, ativo em azul)

final class ToolbarView: NSVisualEffectView {
    private let stack = NSStackView()
    var vertical = false {
        didSet { stack.orientation = vertical ? .vertical : .horizontal }
    }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    func add(_ view: NSView) { stack.addArrangedSubview(view) }

    override var fittingSize: NSSize { stack.fittingSize }
}

final class ToolButton: NSButton {
    var onClick: (() -> Void)?
    var isActive = false {
        didSet { layer?.backgroundColor = isActive ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor }
    }

    init(symbol: String?, help: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        }
        toolTip = help
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 7
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    @objc private func clicked() { onClick?() }
}
