import AppKit

// MARK: - Palco: várias capturas em camadas (mover, redimensionar, mudar o tamanho do palco)

/// Uma captura indo para o palco: a imagem da área e as marcações feitas nela (em coordenadas da imagem).
struct StageItem {
    let image: NSImage
    let marks: [Mark]
    let scale: CGFloat
}

@MainActor
final class StageWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate, CaptureHost {
    let window: NSWindow
    let view: CaptureView
    var onAddCapture: (() -> Void)?
    var onClose: (() -> Void)?

    private let scroll = NSScrollView()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var unsaved = false

    init(first item: StageItem) {
        view = CaptureView.makeStage(size: item.image.size, scale: item.scale)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        view.host = self
        window.title = "Palco — PrintScreen"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = CGSize(width: 720, height: 480)
        build()
        view.addStageItem(item)
        fitWindow()
    }

    private func build() {
        let root = NSView()

        // Barra de cima: adicionar captura, tamanho do palco e copiar/salvar/compartilhar.
        let add = NSButton(title: " Adicionar captura", image: NSImage(systemSymbolName: "plus.viewfinder", accessibilityDescription: nil)!,
                           target: self, action: #selector(addCaptureClicked))
        add.bezelStyle = .rounded
        add.toolTip = "Tira outra captura e coloca neste palco"
        let sizeLabel = NSTextField(labelWithString: "Palco")
        sizeLabel.textColor = .secondaryLabelColor
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        let px = NSTextField(labelWithString: "px")
        px.textColor = .secondaryLabelColor
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 32
        formatter.maximum = 20000
        for field in [widthField, heightField] {
            field.formatter = formatter
            field.alignment = .center
            field.target = self
            field.action = #selector(applySize)
            field.delegate = self
            field.toolTip = "Tamanho do palco em pixels (Enter aplica)"
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        let fit = NSButton(title: " Ajustar ao conteúdo",
                           image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)!,
                           target: self, action: #selector(fitContent))
        fit.bezelStyle = .rounded
        fit.toolTip = "Deixa o palco do tamanho das capturas e marcações"
        let flexible = NSView()
        flexible.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [add, spacer(width: 12), sizeLabel, widthField, times, heightField, px, fit, flexible, view.actionBar])
        top.spacing = 8
        top.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        top.translatesAutoresizingMaskIntoConstraints = false

        // Ferramentas à esquerda; o palco no meio, com rolagem se for maior que a janela.
        let tools = view.toolBar
        tools.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = CenteringClipView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for v in [top, tools, scroll] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tools.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tools.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: tools.trailingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        updateFields()
    }

    private func spacer(width: CGFloat) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    /// Janela do tamanho do palco (sem passar de 90% da tela).
    private func fitWindow() {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let chrome = CGSize(width: view.toolBar.fittingSize.width + 20, height: 56)
        let want = CGSize(width: view.frame.width + chrome.width, height: view.frame.height + chrome.height)
        let size = CGSize(width: min(max(want.width, window.minSize.width), visible.width * 0.9),
                          height: min(max(want.height, window.minSize.height), visible.height * 0.9))
        window.setContentSize(size)
        window.center()
    }

    func add(_ item: StageItem) {
        view.addStageItem(item)
        updateFields()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func hide() {
        window.orderOut(nil)
    }

    private func updateFields() {
        let size = view.stageSize
        widthField.integerValue = Int((size.width * view.pixelScale).rounded())
        heightField.integerValue = Int((size.height * view.pixelScale).rounded())
    }

    @objc private func addCaptureClicked() { onAddCapture?() }

    @objc private func applySize() {
        let scale = view.pixelScale
        view.setStageSize(CGSize(width: CGFloat(widthField.integerValue) / scale, height: CGFloat(heightField.integerValue) / scale))
        window.makeFirstResponder(view)
    }

    @objc private func fitContent() { view.fitStageToContent() }

    // MARK: CaptureHost

    func close() { window.performClose(nil) }
    func addCapture() { onAddCapture?() }

    func contentChanged() {
        unsaved = true
        updateFields()
    }

    func exported() { unsaved = false }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard unsaved else { return true }
        let alert = NSAlert()
        alert.messageText = "Fechar o palco sem copiar nem salvar?"
        alert.informativeText = "As capturas e marcações deste palco serão perdidas. Para guardar, copie (⌘C), salve (⌘S) ou compartilhe antes."
        alert.addButton(withTitle: "Fechar sem salvar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Mantém o palco no meio quando ele é menor que a janela.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
