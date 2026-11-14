import AppKit

// MARK: - Ajustes: atalho (clica no botão e pressiona a combinação nova) e como a captura abre

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let recorder = NSButton(title: "", target: nil, action: nil)
    /// Aviso do atalho; some quando está vazio, para não deixar buraco na janela.
    private let message = MessageLabel(labelWithString: "")
    private let special = NSTextField(wrappingLabelWithString: "")
    private let toolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rememberBox = NSButton(checkboxWithTitle: "Começar com a última área escolhida", target: nil, action: nil)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let movePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let moveHint = NSTextField(wrappingLabelWithString: "")
    private let ratioSwitch = NSSwitch()
    private var monitor: Any?

    override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Ajustes do PrintScreen"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: "Atalho para capturar a tela")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Clique no botão e pressione a combinação nova. Use ⌘, ⌥ ou ⌃ com uma tecla, ou uma tecla F sozinha.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        recorder.bezelStyle = .rounded
        recorder.controlSize = .large
        recorder.font = .systemFont(ofSize: 15, weight: .medium)
        recorder.target = self
        recorder.action = #selector(record)
        let reset = NSButton(title: "Restaurar padrão (\(Shortcut.standard.display))", target: self, action: #selector(restore))
        reset.bezelStyle = .rounded
        message.font = .systemFont(ofSize: 12)
        message.textColor = .systemOrange
        special.font = .systemFont(ofSize: 11)
        special.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [recorder, reset])
        row.spacing = 10

        // Como a captura abre
        let openTitle = NSTextField(labelWithString: "Ao abrir a captura")
        openTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let toolLabel = NSTextField(labelWithString: "Ferramenta já escolhida:")
        toolPopup.addItem(withTitle: "Nenhuma (escolho na hora)")
        for tool in Tool.drawing {
            toolPopup.addItem(withTitle: tool.name)
            toolPopup.lastItem?.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            toolPopup.lastItem?.representedObject = tool.rawValue
        }
        toolPopup.target = self
        toolPopup.action = #selector(toolChanged)
        let toolRow = NSStackView(views: [toolLabel, toolPopup])
        toolRow.spacing = 8
        let formatLabel = NSTextField(labelWithString: "Palco da área:")
        for format in SelectionFormat.allCases {
            formatPopup.addItem(withTitle: format.ratioLabel.map { "\(format.title) (\($0))" } ?? format.title)
            formatPopup.lastItem?.representedObject = format.rawValue
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        let formatRow = NSStackView(views: [formatLabel, formatPopup])
        formatRow.spacing = 8
        let ratioLabel = NSTextField(labelWithString: "Manter a proporção do palco")
        ratioSwitch.target = self
        ratioSwitch.action = #selector(ratioChanged)
        let ratioRow = NSStackView(views: [ratioLabel, ratioSwitch])
        ratioRow.spacing = 10
        let ratioHint = NSTextField(wrappingLabelWithString: "Ligado, Widescreen, Mobile e Quadrada não perdem a proporção ao puxar as alças. Desligado, o palco só põe a área no meio da tela e o tamanho fica livre. Também dá para trocar na barra da captura.")
        ratioHint.font = .systemFont(ofSize: 11)
        ratioHint.textColor = .secondaryLabelColor
        rememberBox.target = self
        rememberBox.action = #selector(rememberChanged)
        let rememberHint = NSTextField(wrappingLabelWithString: "Ao apertar o atalho, a área da última captura já aparece marcada: dá para copiar na hora (⌘C), desenhar ou ajustar.")
        rememberHint.font = .systemFont(ofSize: 11)
        rememberHint.textColor = .secondaryLabelColor
        let line = NSBox()
        line.boxType = .separator

        // Mover a área sem largar a ferramenta
        let moveTitle = NSTextField(labelWithString: "Mover a área")
        moveTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let moveLabel = NSTextField(labelWithString: "Segure")
        for key in MoveModifier.allCases {
            movePopup.addItem(withTitle: key.title)
            movePopup.lastItem?.representedObject = key.rawValue
        }
        movePopup.target = self
        movePopup.action = #selector(moveKeyChanged)
        let moveLabelEnd = NSTextField(labelWithString: "e arraste")
        let moveRow = NSStackView(views: [moveLabel, movePopup, moveLabelEnd])
        moveRow.spacing = 8
        moveHint.font = .systemFont(ofSize: 11)
        moveHint.textColor = .secondaryLabelColor
        let line2 = NSBox()
        line2.boxType = .separator

        let stack = NSStackView(views: [title, hint, row, message, special, line, openTitle, toolRow, formatRow, ratioRow, ratioHint, rememberBox, rememberHint,
                                        line2, moveTitle, moveRow, moveHint])
        stack.setCustomSpacing(18, after: special)
        stack.setCustomSpacing(18, after: line)
        stack.setCustomSpacing(4, after: rememberBox)
        stack.setCustomSpacing(4, after: ratioRow)
        stack.setCustomSpacing(18, after: rememberHint)
        stack.setCustomSpacing(18, after: line2)
        stack.setCustomSpacing(6, after: moveRow)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            hint.widthAnchor.constraint(equalToConstant: 372),
            special.widthAnchor.constraint(equalToConstant: 372),
            rememberHint.widthAnchor.constraint(equalToConstant: 352),
            line.widthAnchor.constraint(equalToConstant: 372),
            line2.widthAnchor.constraint(equalToConstant: 372),
            moveHint.widthAnchor.constraint(equalToConstant: 372),
            ratioHint.widthAnchor.constraint(equalToConstant: 372),
            recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        window.contentView = content
        refresh()
        // A janela do tamanho do conteúdo (as seções cresceram).
        window.setContentSize(CGSize(width: 420, height: ceil(stack.fittingSize.height)))
    }

    func show() {
        refresh()
        message.stringValue = ""
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toolChanged() {
        Preferences.startTool = (toolPopup.selectedItem?.representedObject as? String).flatMap(Tool.init(rawValue:))
    }

    @objc private func formatChanged() {
        Preferences.selectionFormat = (formatPopup.selectedItem?.representedObject as? String).flatMap(SelectionFormat.init(rawValue:)) ?? .free
    }

    @objc private func ratioChanged() {
        Preferences.keepRatio = ratioSwitch.state == .on
    }

    @objc private func moveKeyChanged() {
        Preferences.moveModifier = (movePopup.selectedItem?.representedObject as? String).flatMap(MoveModifier.init(rawValue:)) ?? .option
        refresh()
    }

    @objc private func rememberChanged() {
        Preferences.rememberSelection = rememberBox.state == .on
    }

    private func refresh() {
        recorder.title = Shortcut.load().display
        if let tool = Preferences.startTool, let index = Tool.drawing.firstIndex(of: tool) {
            toolPopup.selectItem(at: index + 1)
        } else {
            toolPopup.selectItem(at: 0)
        }
        rememberBox.state = Preferences.rememberSelection ? .on : .off
        formatPopup.selectItem(at: SelectionFormat.allCases.firstIndex(of: Preferences.selectionFormat) ?? 0)
        ratioSwitch.state = Preferences.keepRatio ? .on : .off
        let key = Preferences.moveModifier
        movePopup.selectItem(at: MoveModifier.allCases.firstIndex(of: key) ?? 0)
        moveHint.stringValue = """
            Com a tecla \(key.symbol) segurada, arrastar move a área da captura, mesmo com a seta ou outra ferramenta \
            escolhida. O botão de mãozinha da barra (ou a tecla M) liga o mesmo modo sem precisar segurar nada.
            """
        special.stringValue = """
            Teclas especiais (como a de print dos teclados Logitech) não chegam aqui. No Logi Options+, ponha na tecla \
            Atalho de teclado \(Shortcut.load().display) ou Abrir aplicativo › PrintScreen: as duas tiram o print.
            """
    }

    @objc private func record() {
        stopRecording()
        recorder.title = "Pressione o atalho…"
        message.stringValue = "Esc cancela."
        message.textColor = .secondaryLabelColor
        // Enquanto grava, o atalho atual não dispara a captura.
        HotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc
            stopRecording()
            HotKey.shared.register(Shortcut.load())
            refresh()
            message.stringValue = ""
            return
        }
        guard let shortcut = Shortcut.from(event) else {
            message.stringValue = "Use ⌘, ⌥ ou ⌃ junto com a tecla (ou uma tecla F)."
            message.textColor = .systemOrange
            return
        }
        stopRecording()
        apply(shortcut)
    }

    private func apply(_ shortcut: Shortcut) {
        if HotKey.shared.register(shortcut) {
            shortcut.save()
            message.stringValue = "Pronto: \(shortcut.display) captura a tela."
            message.textColor = .systemGreen
        } else {
            HotKey.shared.register(Shortcut.load())
            message.stringValue = "\(shortcut.display) já é usado por outro app. Escolha outra combinação."
            message.textColor = .systemOrange
        }
        refresh()
    }

    @objc private func restore() {
        stopRecording()
        apply(.standard)
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func windowWillClose(_ notification: Notification) {
        if monitor != nil {
            stopRecording()
            HotKey.shared.register(Shortcut.load())
        }
    }
}

final class MessageLabel: NSTextField {
    override var stringValue: String {
        didSet { isHidden = stringValue.isEmpty }
    }
}
