import AppKit

// MARK: - Janela do atalho: clica no botão e pressiona a combinação nova

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let recorder = NSButton(title: "", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")
    private var monitor: Any?

    override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 190),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "PrintScreen"
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

        let row = NSStackView(views: [recorder, reset])
        row.spacing = 10
        let stack = NSStackView(views: [title, hint, row, message])
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
            recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        window.contentView = content
        refresh()
    }

    func show() {
        refresh()
        message.stringValue = ""
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        recorder.title = Shortcut.load().display
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
