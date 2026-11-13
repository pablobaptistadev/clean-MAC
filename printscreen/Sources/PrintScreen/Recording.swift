import AppKit
import ScreenCaptureKit

// MARK: - Gravação em andamento: contorno da área, cronômetro com botão de parar e ícone na barra de menus

@MainActor
final class RecordingController: NSObject {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies", isDirectory: true)
        .appendingPathComponent("PrintScreen", isDirectory: true)

    private let recorder: ScreenRecorder
    private let statusItem: NSStatusItem
    private let savedMenu: NSMenu?
    private let hud: RecordingHUD
    private let border: AreaBorderWindow?
    private let startDate = Date()
    private var timer: Timer?
    private var stopping = false
    private let onFinish: () -> Void

    /// `rect` em pontos da tela, origem em cima; nil grava a tela inteira.
    static func start(screen: NSScreen, rect: CGRect?, statusItem: NSStatusItem,
                      onFinish: @escaping () -> Void) async throws -> RecordingController {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw RecorderError.display
        }
        let me = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName())
        let recorder = try ScreenRecorder(display: display, scale: screen.backingScaleFactor, rect: rect, excluding: me, url: url)
        try await recorder.start()
        return RecordingController(recorder: recorder, screen: screen, rect: rect, statusItem: statusItem, onFinish: onFinish)
    }

    private init(recorder: ScreenRecorder, screen: NSScreen, rect: CGRect?, statusItem: NSStatusItem, onFinish: @escaping () -> Void) {
        self.recorder = recorder
        self.statusItem = statusItem
        self.savedMenu = statusItem.menu
        self.onFinish = onFinish
        let area = rect.map { Self.cocoaRect($0, on: screen) }
        border = area.map { AreaBorderWindow(around: $0) }
        hud = RecordingHUD()
        super.init()

        hud.onStop = { [weak self] in self?.stop() }
        hud.place(near: area, on: screen)
        border?.orderFrontRegardless()
        hud.orderFrontRegardless()

        // Clicar no ícone da barra de menus também para.
        statusItem.menu = nil
        statusItem.length = NSStatusItem.variableLength
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Parar gravação")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(stopFromMenuBar)
            button.toolTip = "Parar e salvar o vídeo"
        }
        recorder.onInterrupt = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        tick()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let text = Self.elapsed(Date().timeIntervalSince(startDate))
        hud.time = text
        statusItem.button?.title = " " + text
    }

    @objc private func stopFromMenuBar() { stop() }

    func stop() {
        guard !stopping else { return }
        stopping = true
        timer?.invalidate()
        hud.saving()
        border?.orderOut(nil)
        Task {
            let result = await recorder.stop()
            hud.orderOut(nil)
            restoreStatusItem()
            switch result {
            case .success(let url): delivered(url)
            case .failure(let error): Self.alert("Não foi possível salvar o vídeo", error.localizedDescription)
            }
            onFinish()
        }
    }

    private func restoreStatusItem() {
        statusItem.length = NSStatusItem.squareLength
        if let button = statusItem.button {
            button.title = ""
            button.toolTip = nil
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PrintScreen")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.target = nil
            button.action = nil
        }
        statusItem.menu = savedMenu
    }

    /// Vídeo pronto: fica copiado (dá para colar no WhatsApp, Slack, e-mail) e aparece selecionado no Finder.
    private func delivered(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        NSSound(named: "Pop")?.play()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            Toast.show("Vídeo salvo e copiado", detail: "Cole com ⌘V ou veja em Filmes › PrintScreen",
                       at: CGPoint(x: visible.midX, y: visible.minY + 120), seconds: 2.2)
        }
    }

    // MARK: Ajudantes

    static func cocoaRect(_ r: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func fileName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        return "Gravação de tela \(f.string(from: date)).mp4"
    }

    static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Cronômetro flutuante (não aparece no vídeo)

@MainActor
final class RecordingHUD: NSPanel {
    var onStop: (() -> Void)?
    var time = "0:00" {
        didSet { label.stringValue = time }
    }

    private let bar = ToolbarView()
    private let label = NSTextField(labelWithString: "0:00")
    private let stopButton = ToolButton(symbol: "stop.fill", help: "Parar e salvar (atalho da captura)")

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 150, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Gravando")!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))!)
        dot.contentTintColor = .systemRed
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 22),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 58)
        ])
        stopButton.onClick = { [weak self] in self?.onStop?() }
        bar.add(dot)
        bar.add(label)
        bar.add(stopButton)
        let size = bar.fittingSize
        bar.frame = CGRect(origin: .zero, size: size)
        setContentSize(size)
        contentView = bar
    }

    override var canBecomeKey: Bool { false }

    /// Embaixo da área (ou em cima, ou dentro, se não couber). Sem área: embaixo, no meio da tela.
    func place(near area: CGRect?, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = frame.size
        let gap: CGFloat = 12
        var origin: CGPoint
        if let area {
            origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - gap - size.height)
            if origin.y < visible.minY + 4 { origin.y = area.maxY + gap }
            if origin.y + size.height > visible.maxY - 4 { origin.y = area.minY + gap }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 28)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        setFrameOrigin(origin)
    }

    func saving() {
        label.stringValue = "Salvando…"
        stopButton.isEnabled = false
        let size = bar.fittingSize
        setContentSize(size)
    }
}

// MARK: - Contorno tracejado em volta da área gravada (fica de fora do vídeo)

final class AreaBorderWindow: NSWindow {
    private static let inset: CGFloat = 3

    init(around area: CGRect) {
        super.init(contentRect: area.insetBy(dx: -Self.inset, dy: -Self.inset), styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = BorderView()
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.6).setStroke()
            path.stroke()
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            path.stroke()
        }
    }
}
