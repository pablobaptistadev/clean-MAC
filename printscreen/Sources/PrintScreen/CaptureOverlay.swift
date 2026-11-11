import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Marcações (lápis, linha, seta, quadrado, círculo, texto, desfoque)

enum Tool: String, CaseIterable {
    case pencil, line, arrow, rect, ellipse, text, blur

    var symbol: String {
        switch self {
        case .pencil: return "pencil"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .blur: return "drop"
        }
    }

    var help: String {
        switch self {
        case .pencil: return "Lápis"
        case .line: return "Linha (Shift: retas a cada 45°)"
        case .arrow: return "Seta (Shift: retas a cada 45°)"
        case .rect: return "Quadrado (Shift: quadrado perfeito)"
        case .ellipse: return "Círculo (Shift: círculo perfeito)"
        case .text: return "Texto"
        case .blur: return "Desfocar área (a espessura define a intensidade)"
        }
    }
}

/// Uma marcação desenhada sobre a captura, em coordenadas da tela (origem no canto de cima).
struct Mark {
    let tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var text = ""
    /// Espessura do traço em pontos. No texto, define o tamanho da letra; no desfoque, a intensidade.
    var width: CGFloat = Mark.defaultWidth
    /// Desfoque: imagem já desfocada e onde ela é desenhada (a tela toda enquanto arrasta, só a área depois).
    var blur: NSImage?
    var blurFrame: CGRect = .zero

    static let defaultWidth: CGFloat = 3
    static let widthRange: ClosedRange<CGFloat> = 1...20
    static let minFontSize: CGFloat = 10
    static let maxFontSize: CGFloat = 200
    static func font(for width: CGFloat) -> NSFont {
        .systemFont(ofSize: min(max(16 + 2 * width, minFontSize), maxFontSize), weight: .semibold)
    }
    /// Raio do desfoque em pontos: forte o bastante para apagar texto já na espessura padrão.
    static func blurRadius(for width: CGFloat) -> CGFloat { 4 + width * 2 }

    var box: CGRect {
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
        case .line:
            guard let a = points.first, let b = points.last else { return }
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: a == b ? CGPoint(x: b.x + 0.1, y: b.y) : b)
            stroke(path)
        case .arrow:
            guard let a = points.first, let b = points.last, a != b else { return }
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(12, width * 3 + 7)
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
            (text as NSString).draw(at: origin, withAttributes: [.font: Mark.font(for: width), .foregroundColor: color])
        case .blur:
            guard let blur, box.width >= 1, box.height >= 1 else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: box).addClip()
            blur.draw(in: blurFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Com Shift: linha e seta em ângulos de 45°, quadrado e círculo perfeitos.
    static func constrained(_ tool: Tool, from a: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - a.x, dy = p.y - a.y
        switch tool {
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: a.x + length * cos(angle), y: a.y + length * sin(angle))
        case .rect, .ellipse, .blur:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
        default:
            return p
        }
    }

    private func stroke(_ path: NSBezierPath) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

// MARK: - Controle da captura: uma janela por tela

enum CaptureMode {
    /// Foto da área, com marcações.
    case screenshot
    /// Escolher a área do vídeo (sem marcações).
    case video
}

@MainActor
final class CaptureController {
    private var windows: [OverlayWindow] = []
    private let onClose: () -> Void
    private let onRecord: (NSScreen, CGRect?) -> Void
    private let onNewCapture: () -> Void

    init(shots: [ScreenShot], mode: CaptureMode, onRecord: @escaping (NSScreen, CGRect?) -> Void,
         onNewCapture: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.onRecord = onRecord
        self.onNewCapture = onNewCapture
        for shot in shots {
            let window = OverlayWindow(screen: shot.screen)
            let view = CaptureView(shot: shot, mode: mode, controller: self)
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
        NSCursor.crosshair.set()
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

    /// Fecha esta captura e tira outra da tela como ela está agora.
    func newCapture() {
        close()
        onNewCapture()
    }

    /// Fecha o seletor e grava a área (ou a tela inteira, se `rect` for nil).
    func record(screen: NSScreen, rect: CGRect?) {
        close()
        onRecord(screen, rect)
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
        acceptsMouseMovedEvents = true
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
        case moveMark(index: Int, start: CGPoint, original: Mark)
        case resizeMark(index: Int, handle: Int, original: Mark)
    }

    static let palette: [(name: String, color: NSColor)] = [
        ("Vermelho", .systemRed), ("Laranja", .systemOrange), ("Amarelo", .systemYellow), ("Verde", .systemGreen),
        ("Azul", .systemBlue), ("Roxo", .systemPurple), ("Branco", .white), ("Preto", .black)
    ]

    private let shot: ScreenShot
    private let mode: CaptureMode
    private let image: NSImage
    private weak var controller: CaptureController?

    private(set) var selection: CGRect?
    private var editing = false
    private var drag: Drag = .none
    private var tool: Tool?
    private var color: NSColor = .systemRed
    private(set) var marks: [Mark] = []
    /// Histórico: cada passo guarda as marcações como estavam antes da mudança.
    private var undoStack: [[Mark]] = []
    private var redoStack: [[Mark]] = []
    private var historyKey: String?
    private var historyTime = Date.distantPast
    /// Marcação selecionada (alças azuis): arrasta para mover, alças mudam o tamanho.
    private(set) var selectedMark: Int?
    private var editStart: [Mark]?
    private var markChanged = false
    private var current: Mark?
    private var lineWidth = CaptureView.savedLineWidth()
    private var scrollAccumulator: CGFloat = 0
    private var widthHint: CGPoint?
    private var hideHint: DispatchWorkItem?
    /// Captura inteira já desfocada na intensidade atual (uma por vez, para não pesar na memória).
    private var blurCache: (width: CGFloat, cg: CGImage, image: NSImage)?
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var textWidth = Mark.defaultWidth
    /// Texto existente aberto com duplo clique (volta para o lugar se cancelar).
    private var textEditing: (index: Int, original: Mark)?

    private let toolBar = ToolbarView()
    private let actionBar = ToolbarView()
    private var toolButtons: [Tool: ToolButton] = [:]
    private let colorButton = ToolButton(symbol: nil, help: "Cor")
    private let thickness = ThicknessControl()
    private let undoButton = ToolButton(symbol: "arrow.uturn.backward", help: "Desfazer (⌘Z)")
    private let redoButton = ToolButton(symbol: "arrow.uturn.forward", help: "Refazer (⇧⌘Z)")

    private static let lineWidthKey = "lineWidth"

    static func savedLineWidth() -> CGFloat {
        let saved = CGFloat(UserDefaults.standard.double(forKey: lineWidthKey))
        guard saved > 0 else { return Mark.defaultWidth }
        return min(max(saved, Mark.widthRange.lowerBound), Mark.widthRange.upperBound)
    }

    init(shot: ScreenShot, mode: CaptureMode = .screenshot, controller: CaptureController?) {
        self.shot = shot
        self.mode = mode
        self.image = NSImage(cgImage: shot.image, size: shot.screen.frame.size)
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        buildToolbars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    private func updateCursor(at p: CGPoint) {
        guard case .none = drag else { return }
        cursor(at: p).set()
    }

    /// Mãozinha onde dá para mover (marcações e a área), setas nas alças, cruz para desenhar ou escolher outra área.
    func cursor(at p: CGPoint) -> NSCursor {
        for bar in [toolBar, actionBar] where !bar.isHidden && bar.frame.contains(p) { return .arrow }
        if let field = textField, field.frame.contains(p) { return .iBeam }
        guard editing, let sel = selection else { return .crosshair }
        if mode == .screenshot, let i = selectedMark, marks.indices.contains(i),
           let handle = marks[i].handles.first(where: { hypot($0.point.x - p.x, $0.point.y - p.y) <= 8 }) {
            return handle.id >= Mark.startHandle ? .crosshair : Cursors.resize(handle: handle.id)
        }
        if let index = handles(of: sel).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 7 }) {
            return Cursors.resize(handle: index)
        }
        if mode == .screenshot, markIndex(at: p) != nil { return .openHand }
        guard sel.contains(p) else { return .crosshair }
        switch tool {
        case nil: return .openHand
        case .text?: return .iBeam
        default: return .crosshair
        }
    }

    // MARK: Barras de ferramentas

    private func buildToolbars() {
        for t in Tool.allCases {
            let button = ToolButton(symbol: t.symbol, help: t.help)
            button.onClick = { [weak self] in self?.choose(t) }
            toolButtons[t] = button
            toolBar.add(button)
        }
        toolBar.add(ToolbarSeparator())
        colorButton.onClick = { [weak self] in self?.showPalette() }
        toolBar.add(colorButton)
        thickness.value = lineWidth
        thickness.onChange = { [weak self] in self?.setLineWidth($0, fromSlider: true) }
        toolBar.add(thickness)
        toolBar.add(ToolbarSeparator())
        undoButton.onClick = { [weak self] in self?.undo() }
        redoButton.onClick = { [weak self] in self?.redo() }
        let newCapture = ToolButton(symbol: "plus.viewfinder", help: "Nova captura (⌘N)")
        newCapture.onClick = { [weak self] in self?.controller?.newCapture() }
        for button in [undoButton, redoButton, newCapture] { toolBar.add(button) }
        toolBar.vertical = true
        updateHistoryButtons()

        let copy = ToolButton(symbol: "doc.on.doc", help: "Copiar (⌘C)")
        copy.onClick = { [weak self] in self?.copyToClipboard() }
        let save = ToolButton(symbol: "square.and.arrow.down", help: "Salvar PNG (⌘S)")
        save.onClick = { [weak self] in self?.saveAsPNG() }
        let record = ToolButton(symbol: "record.circle", help: mode == .video ? "Gravar vídeo da área (Enter)" : "Gravar vídeo da área (⌘R)")
        record.onClick = { [weak self] in self?.startRecording() }
        let close = ToolButton(symbol: "xmark", help: "Fechar (Esc)")
        close.onClick = { [weak self] in self?.controller?.close() }
        if mode == .video {
            let start = LabelButton(symbol: "record.circle.fill", title: "Gravar", help: "Gravar vídeo da área (Enter)")
            start.onClick = { [weak self] in self?.startRecording() }
            actionBar.add(start)
            actionBar.add(close)
        } else {
            for b in [copy, save, record, close] { actionBar.add(b) }
        }

        for bar in [toolBar, actionBar] {
            bar.isHidden = true
            addSubview(bar)
        }
        updateColorButton()
    }

    private func choose(_ t: Tool) {
        commitText()
        selectMark(nil)
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
        applyColor(picked)
    }

    private func applyColor(_ picked: NSColor) {
        color = picked
        updateColorButton()
        textField?.textColor = picked
        if let i = selectedMark, marks.indices.contains(i), marks[i].tool != .blur {
            pushHistory(key: "cor-\(i)")
            marks[i].color = picked
            needsDisplay = true
        }
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
        applyColor(sender.color)
    }

    private func layoutToolbars() {
        guard editing, let sel = selection else {
            toolBar.isHidden = true
            actionBar.isHidden = true
            return
        }
        toolBar.isHidden = mode == .video
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
        if let current, current.tool == .blur {
            let outline = NSBezierPath(rect: current.box)
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.8).setStroke()
            outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let i = selectedMark, marks.indices.contains(i) { drawSelection(of: marks[i]) }

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
        if let widthHint { drawWidthHint(at: widthHint) }
    }

    /// Contorno tracejado e alças redondas (azul do sistema) da marcação selecionada.
    private func drawSelection(of mark: Mark) {
        let accent = NSColor.systemBlue
        if mark.tool != .line && mark.tool != .arrow {
            let outline = NSBezierPath(rect: mark.frame.insetBy(dx: -3, dy: -3))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            accent.setStroke()
            outline.stroke()
        }
        for handle in mark.handles {
            let dot = NSBezierPath(ovalIn: CGRect(x: handle.point.x - 5, y: handle.point.y - 5, width: 10, height: 10))
            NSColor.white.setFill()
            dot.fill()
            dot.lineWidth = 1.5
            accent.setStroke()
            dot.stroke()
        }
    }

    /// Bolinha do tamanho do traço junto do cursor, enquanto a roda do mouse muda a espessura.
    private func drawWidthHint(at p: CGPoint) {
        let d = max(lineWidth, 2)
        let dot = NSBezierPath(ovalIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
        color.setFill()
        dot.fill()
        dot.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        dot.stroke()
        let label: String
        switch selectedMark.flatMap({ marks.indices.contains($0) ? marks[$0].tool : nil }) ?? tool {
        case .text: label = "Texto \(Int(Mark.font(for: lineWidth).pointSize)) pt"
        case .blur: label = "Desfoque \(Int(lineWidth))"
        default: label = "\(Int(lineWidth)) px"
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        let box = CGRect(x: p.x + d / 2 + 8, y: p.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    private func drawHint() {
        let text = (mode == .video
            ? "Arraste para escolher a área do vídeo · Enter grava a tela inteira · Esc cancela"
            : "Arraste para escolher a área · ⌘R grava vídeo · Esc cancela") as NSString
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
            // 1) Alças da marcação selecionada: muda o tamanho.
            if mode == .screenshot, let i = selectedMark, marks.indices.contains(i),
               let handle = marks[i].handles.first(where: { hypot($0.point.x - p.x, $0.point.y - p.y) <= 8 }) {
                beginMarkEdit()
                drag = .resizeMark(index: i, handle: handle.id, original: marks[i])
                return
            }
            // 2) Alças da área.
            if let index = handles(of: sel).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 7 }) {
                drag = .resize(handle: index, original: sel)
                return
            }
            if mode == .screenshot {
                // 3) Clique numa marcação: seleciona e arrasta para mover. Duplo clique num texto edita.
                if let i = markIndex(at: p) {
                    if event.clickCount >= 2, marks[i].tool == .text {
                        editText(at: i)
                        return
                    }
                    selectMark(i)
                    beginMarkEdit()
                    drag = .moveMark(index: i, start: p, original: marks[i])
                    NSCursor.closedHand.set()
                    return
                }
                selectMark(nil)
            }
            // 4) Desenhar com a ferramenta escolhida.
            if mode == .screenshot, let tool, sel.contains(p) {
                if tool == .text {
                    beginText(at: p)
                } else {
                    var mark = Mark(tool: tool, points: [p, p], color: color, width: lineWidth)
                    if tool == .blur {
                        mark.blur = blurredScreen(for: lineWidth)
                        mark.blurFrame = bounds
                    }
                    current = mark
                    drag = .draw
                }
                return
            }
            // 5) Sem ferramenta: arrasta a área.
            if tool == nil, sel.contains(p) {
                drag = .move(offset: CGPoint(x: p.x - sel.minX, y: p.y - sel.minY))
                NSCursor.closedHand.set()
                return
            }
        }
        // Começa uma área nova (as marcações da anterior são descartadas).
        controller?.selectionStarted(in: self)
        marks = []
        resetHistory()
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
            if mark.tool == .pencil {
                mark.points.append(p)
            } else {
                mark.points[1] = event.modifierFlags.contains(.shift) ? clamp(Mark.constrained(mark.tool, from: mark.points[0], to: p)) : p
            }
            current = mark
        case .moveMark(let i, let start, let original):
            guard marks.indices.contains(i) else { return }
            marks[i] = previewBlur(original.moved(by: p.x - start.x, p.y - start.y))
            markChanged = true
        case .resizeMark(let i, let handle, let original):
            guard marks.indices.contains(i) else { return }
            marks[i] = previewBlur(original.resized(handle: handle, to: p))
            markChanged = true
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
            if var mark = current {
                if mark.tool == .blur {
                    if let crop = blurCrop(mark) { mark.blur = crop.image; mark.blurFrame = crop.frame; addMark(mark) }
                } else {
                    addMark(mark)
                }
            }
            current = nil
        case .moveMark(let i, _, _), .resizeMark(let i, _, _):
            finishMarkEdit(i)
        default:
            break
        }
        drag = .none
        layoutToolbars()
        needsDisplay = true
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Editar marcações

    /// Marcação sob o cursor (a de cima primeiro). A selecionada também pega cliques dentro do retângulo dela.
    private func markIndex(at p: CGPoint) -> Int? {
        if let i = selectedMark, marks.indices.contains(i), marks[i].tool != .line, marks[i].tool != .arrow,
           marks[i].frame.insetBy(dx: -6, dy: -6).contains(p) {
            return i
        }
        return marks.indices.reversed().first { marks[$0].contains(p) }
    }

    /// Seleciona (ou tira a seleção). A cor e a espessura da barra passam a ser as da marcação.
    private func selectMark(_ index: Int?) {
        selectedMark = index
        if let index, marks.indices.contains(index) {
            let mark = marks[index]
            if mark.tool != .blur {
                color = mark.color
                updateColorButton()
            }
            lineWidth = min(max(mark.width.rounded(), Mark.widthRange.lowerBound), Mark.widthRange.upperBound)
            thickness.value = lineWidth
        }
        needsDisplay = true
    }

    private func beginMarkEdit() {
        editStart = marks
        markChanged = false
    }

    private func finishMarkEdit(_ i: Int) {
        defer { editStart = nil }
        guard markChanged, let start = editStart, marks.indices.contains(i) else { return }
        pushHistory(start)
        if marks[i].tool == .blur, let crop = blurCrop(marks[i]) {
            marks[i].blur = crop.image
            marks[i].blurFrame = crop.frame
        }
    }

    /// Desfoque sendo movido ou redimensionado: usa a tela toda desfocada até soltar (aí recorta de novo).
    private func previewBlur(_ mark: Mark) -> Mark {
        guard mark.tool == .blur else { return mark }
        var mark = mark
        mark.blur = blurredScreen(for: mark.width)
        mark.blurFrame = bounds
        return mark
    }

    private func deleteSelectedMark() {
        guard let i = selectedMark, marks.indices.contains(i) else { return }
        pushHistory()
        marks.remove(at: i)
        selectedMark = nil
        updateHistoryButtons()
        needsDisplay = true
    }

    /// Setas do teclado empurram a marcação selecionada (com Shift, de 10 em 10).
    private func nudgeSelectedMark(dx: CGFloat, dy: CGFloat) {
        guard let i = selectedMark, marks.indices.contains(i) else { return }
        pushHistory(key: "empurrar-\(i)")
        var mark = marks[i].moved(by: dx, dy)
        if mark.tool == .blur, let crop = blurCrop(mark) {
            mark.blur = crop.image
            mark.blurFrame = crop.frame
        }
        marks[i] = mark
        needsDisplay = true
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func resized(_ r: CGRect, handle: Int, to p: CGPoint) -> CGRect {
        Mark.resize(r, handle: handle, to: p)
    }

    func clearSelection() {
        commitText()
        selection = nil
        editing = false
        marks = []
        resetHistory()
        layoutToolbars()
        needsDisplay = true
    }

    // MARK: Texto

    private func beginText(at p: CGPoint, text: String = "", color textColor: NSColor? = nil, width: CGFloat? = nil) {
        textWidth = width ?? lineWidth
        let font = Mark.font(for: textWidth)
        let field = NSTextField(frame: CGRect(x: p.x, y: p.y, width: 260, height: ceil(font.pointSize * 1.4)))
        field.font = font
        field.stringValue = text
        field.textColor = textColor ?? color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Digite o texto"
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldEnter(_:))
        addSubview(field)
        fitTextField(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = CGPoint(x: p.x + 2, y: p.y + 2)
    }

    /// Duplo clique num texto: abre para editar no mesmo lugar, com a mesma cor e tamanho.
    private func editText(at i: Int) {
        let mark = marks[i]
        guard let origin = mark.points.first else { return }
        pushHistory()
        marks.remove(at: i)
        selectedMark = nil
        textEditing = (i, mark)
        beginText(at: CGPoint(x: origin.x - 2, y: origin.y - 2), text: mark.text, color: mark.color, width: mark.width)
        needsDisplay = true
    }

    @objc private func textFieldEnter(_ sender: NSTextField) {
        commitText()
        window?.makeFirstResponder(self)
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = textField { fitTextField(field) }
    }

    private func fitTextField(_ field: NSTextField) {
        let font = field.font ?? Mark.font(for: textWidth)
        let width = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        field.frame.size = CGSize(width: max(260, width + 30), height: ceil(font.pointSize * 1.4))
    }

    private func commitText() {
        guard let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        textField = nil
        if let editing = textEditing {
            // Texto existente: volta para a mesma posição na pilha (apagar todo o texto remove a marcação).
            textEditing = nil
            if !text.isEmpty {
                var mark = editing.original
                mark.text = text
                mark.color = field.textColor ?? mark.color
                mark.width = textWidth
                marks.insert(mark, at: min(editing.index, marks.count))
            }
            updateHistoryButtons()
        } else if !text.isEmpty {
            addMark(Mark(tool: .text, points: [textOrigin], color: field.textColor ?? color, text: text, width: textWidth))
        }
        needsDisplay = true
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        if let editing = textEditing {
            textEditing = nil
            marks.insert(editing.original, at: min(editing.index, marks.count))
            if !undoStack.isEmpty { undoStack.removeLast() }
            updateHistoryButtons()
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Teclado

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Esc: cancela o texto, depois tira a seleção, depois fecha
            cancelOperation(nil)
            return
        }
        if selectedMark != nil, flags.intersection([.command, .control, .option]).isEmpty {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 51, 117: deleteSelectedMark(); return // Delete / Delete para a frente
            case 123: nudgeSelectedMark(dx: -step, dy: 0); return
            case 124: nudgeSelectedMark(dx: step, dy: 0); return
            case 125: nudgeSelectedMark(dx: 0, dy: step); return
            case 126: nudgeSelectedMark(dx: 0, dy: -step); return
            default: break
            }
        }
        if mode == .video, event.keyCode == 36 || event.keyCode == 76 { // Enter / Enter do teclado numérico
            startRecording()
            return
        }
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c" where mode == .screenshot: copyToClipboard(); return
            case "s" where mode == .screenshot: saveAsPNG(); return
            case "z":
                if flags.contains(.shift) { redo() } else { undo() }
                return
            case "n" where mode == .screenshot: controller?.newCapture(); return
            case "r": startRecording(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if textField != nil {
            cancelText()
        } else if selectedMark != nil {
            selectMark(nil)
        } else {
            controller?.close()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    // MARK: Desfoque

    /// A captura inteira desfocada (na resolução real), para a prévia enquanto arrasta.
    private func blurredScreen(for width: CGFloat) -> NSImage? {
        if let blurCache, blurCache.width == width { return blurCache.image }
        guard let cg = blurredCG(for: width) else { return nil }
        let image = NSImage(cgImage: cg, size: bounds.size)
        blurCache = (width, cg, image)
        return image
    }

    private func blurredCG(for width: CGFloat) -> CGImage? {
        if let blurCache, blurCache.width == width { return blurCache.cg }
        let scale = CGFloat(shot.image.width) / bounds.width
        let input = CIImage(cgImage: shot.image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(Mark.blurRadius(for: width) * scale, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cg = Self.ciContext.createCGImage(output, from: input.extent) else { return nil }
        return cg
    }

    /// Ao soltar, a marcação guarda só o pedaço desfocado da área (leve), alinhado aos pixels.
    private func blurCrop(_ mark: Mark) -> (image: NSImage, frame: CGRect)? {
        guard let full = blurredCG(for: mark.width) else { return nil }
        let scale = CGFloat(full.width) / bounds.width
        let box = mark.box
        let pixels = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard pixels.width >= 2, pixels.height >= 2, let crop = full.cropping(to: pixels) else { return nil }
        let frame = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
        return (NSImage(cgImage: crop, size: frame.size), frame)
    }

    // MARK: Desfazer / refazer

    /// Guarda as marcações de antes de uma mudança. Mudanças seguidas com a mesma `key` (roda do mouse, cor, setas)
    /// viram um passo só, para o ⌘Z não ter que voltar de um em um.
    private func pushHistory(_ snapshot: [Mark]? = nil, key: String? = nil) {
        let now = Date()
        if let key, key == historyKey, now.timeIntervalSince(historyTime) < 1.5 {
            historyTime = now
            return
        }
        historyKey = key
        historyTime = now
        undoStack.append(snapshot ?? marks)
        redoStack = []
        updateHistoryButtons()
    }

    private func resetHistory() {
        undoStack = []
        redoStack = []
        historyKey = nil
        selectedMark = nil
        updateHistoryButtons()
    }

    private func addMark(_ mark: Mark) {
        pushHistory()
        marks.append(mark)
        updateHistoryButtons()
    }

    private func undo() {
        if textField != nil { cancelText() }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(marks)
        marks = previous
        selectedMark = nil
        historyKey = nil
        updateHistoryButtons()
        needsDisplay = true
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(marks)
        marks = next
        selectedMark = nil
        historyKey = nil
        updateHistoryButtons()
        needsDisplay = true
    }

    private func updateHistoryButtons() {
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
    }

    // MARK: Espessura (barra e roda do mouse)

    private func setLineWidth(_ value: CGFloat, fromSlider: Bool = false) {
        let width = min(max(value.rounded(), Mark.widthRange.lowerBound), Mark.widthRange.upperBound)
        guard width != lineWidth else { return }
        lineWidth = width
        UserDefaults.standard.set(Double(width), forKey: Self.lineWidthKey)
        if !fromSlider { thickness.value = width }
        if let i = selectedMark, marks.indices.contains(i) {
            pushHistory(key: "espessura-\(i)")
            var mark = marks[i]
            mark.width = width
            if mark.tool == .blur, let crop = blurCrop(mark) {
                mark.blur = crop.image
                mark.blurFrame = crop.frame
            }
            marks[i] = mark
        }
        if var mark = current {
            mark.width = width
            if mark.tool == .blur { mark.blur = blurredScreen(for: width) }
            current = mark
        }
        if let field = textField {
            textWidth = width
            field.font = Mark.font(for: width)
            fitTextField(field)
        }
        needsDisplay = true
    }

    /// Com uma ferramenta ou marcação escolhida, a roda do mouse engrossa (para cima) ou afina (para baixo) o traço.
    override func scrollWheel(with event: NSEvent) {
        guard mode == .screenshot, editing, tool != nil || selectedMark != nil else { return super.scrollWheel(with: event) }
        // Sentido físico da roda, ignorando a "rolagem natural".
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        var steps: CGFloat = 0
        if event.hasPreciseScrollingDeltas {
            // Trackpad e Magic Mouse mandam muitos passos pequenos: um ponto de espessura a cada 8.
            scrollAccumulator += dy
            steps = (scrollAccumulator / 8).rounded(.towardZero)
            scrollAccumulator -= steps * 8
        } else if dy != 0 {
            steps = dy > 0 ? 1 : -1
        }
        guard steps != 0 else { return }
        setLineWidth(lineWidth + steps)
        showWidthHint(at: convert(event.locationInWindow, from: nil))
    }

    private func showWidthHint(at p: CGPoint) {
        widthHint = p
        hideHint?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.widthHint = nil
            self?.needsDisplay = true
        }
        hideHint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
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

    /// Grava a área escolhida; sem área, a tela inteira. As marcações não entram no vídeo.
    private func startRecording() {
        commitText()
        let rect = selection.flatMap { $0.width >= 8 && $0.height >= 8 ? $0.integral : nil }
        controller?.record(screen: shot.screen, rect: rect)
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
    func setForTesting(selection: CGRect, marks: [Mark], tool: Tool? = nil, lineWidth: CGFloat? = nil, hint: CGPoint? = nil) {
        self.selection = selection
        self.marks = marks
        resetHistory()
        if let lineWidth { self.lineWidth = lineWidth; thickness.value = lineWidth }
        widthHint = hint
        updateHistoryButtons()
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

/// Espessura do traço: barra vertical (em cima = mais grosso), entre uma bolinha grande e uma pequena.
final class ThicknessControl: NSView {
    var onChange: ((CGFloat) -> Void)?
    var value: CGFloat {
        get { CGFloat(slider.doubleValue) }
        set {
            slider.doubleValue = Double(newValue)
            updateHelp()
        }
    }

    private let slider = NSSlider(value: Double(Mark.defaultWidth), minValue: Double(Mark.widthRange.lowerBound),
                                  maxValue: Double(Mark.widthRange.upperBound), target: nil, action: nil)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 32, height: 120))
        translatesAutoresizingMaskIntoConstraints = false
        slider.isVertical = true
        slider.controlSize = .small
        slider.trackFillColor = .systemBlue
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        let big = Self.dot(10), small = Self.dot(4)
        for view in [big, slider, small] { addSubview(view) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 120),
            big.centerXAnchor.constraint(equalTo: centerXAnchor),
            big.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            slider.centerXAnchor.constraint(equalTo: centerXAnchor),
            slider.topAnchor.constraint(equalTo: big.bottomAnchor, constant: 4),
            slider.bottomAnchor.constraint(equalTo: small.topAnchor, constant: -4),
            small.centerXAnchor.constraint(equalTo: centerXAnchor),
            small.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        updateHelp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func changed() {
        updateHelp()
        onChange?(value)
    }

    private func updateHelp() {
        toolTip = "Espessura: \(Int(value.rounded())) px · com uma ferramenta escolhida, a roda do mouse também muda"
    }

    private static func dot(_ size: CGFloat) -> NSView {
        let view = NSImageView(image: NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        })
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

/// Linha fina entre os grupos da barra.
final class ToolbarSeparator: NSView {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 1))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }
}

/// Botão principal com texto (azul do sistema), como o "Gravar" do modo vídeo.
final class LabelButton: NSButton {
    var onClick: (() -> Void)?

    init(symbol: String, title: String, help: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white
        ])
        contentTintColor = .white
        isBordered = false
        toolTip = help
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(equalToConstant: intrinsicContentSize.width + 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    // Responde já no primeiro clique, mesmo com o PrintScreen em segundo plano (cronômetro da gravação).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { onClick?() }
}

final class ToolButton: NSButton {
    var onClick: (() -> Void)?
    var isActive = false {
        didSet { layer?.backgroundColor = isActive ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
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

    // Responde já no primeiro clique, mesmo com o PrintScreen em segundo plano (cronômetro da gravação).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { onClick?() }
}
