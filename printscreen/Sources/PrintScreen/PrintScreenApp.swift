import AppKit
import CoreServices

// MARK: - App: ícone na barra de menus + atalho global

@main
enum PrintScreenMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var capture: CaptureController?
    private var settings: SettingsWindowController?
    private var recording: RecordingController?
    private var startingRecording = false
    /// Uma captura está começando (fotografando a tela): outro toque no atalho não abre uma segunda por cima.
    private var startingCapture = false
    private var stage: StageWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PrintScreen")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        HotKey.shared.onPress = { [weak self] in self?.shortcutPressed() }
        if !HotKey.shared.register(Shortcut.load()) {
            showSettings()
        }
        // Abrir o PrintScreen (Finder, Spotlight ou uma tecla do teclado que "abre aplicativo") já tira o print.
        if Self.openedByUser(notification) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.shortcutPressed() }
        }
    }

    /// Abrir de novo com o app já rodando (ex.: Logi Options+ › Abrir aplicativo) também tira o print.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shortcutPressed()
        return false
    }

    /// Atalho, tecla do teclado ou reabrir: captura; durante uma gravação, para e salva o vídeo.
    private func shortcutPressed() {
        if let recording { recording.stop() } else { startCapture() }
    }

    /// Aberto pela pessoa. Não conta: início de sessão, reabertura automática do macOS e o script de instalação (--background).
    static func openedByUser(_ notification: Notification) -> Bool {
        if CommandLine.arguments.contains("--background") { return false }
        if let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool, !isDefault { return false }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return false
        }
        return true
    }

    // O menu é montado na hora de abrir, para mostrar o atalho atual.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let capture = NSMenuItem(title: "Capturar tela   \(Shortcut.load().display)", action: #selector(captureFromMenu), keyEquivalent: "")
        capture.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        menu.addItem(capture)
        let video = NSMenuItem(title: "Gravar vídeo…", action: #selector(recordFromMenu), keyEquivalent: "")
        video.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        menu.addItem(video)
        let folder = NSMenuItem(title: "Abrir pasta dos vídeos", action: #selector(openVideosFolder), keyEquivalent: "")
        folder.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)
        menu.addItem(folder)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "PrintScreen \(AppInfo.version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Encerrar PrintScreen", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
    }

    @objc private func captureFromMenu() {
        // Espera o menu sumir para ele não sair na captura.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.startCapture() }
    }

    @objc private func recordFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.startCapture(mode: .video) }
    }

    @objc private func openVideosFolder() {
        let folder = RecordingController.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func openSettings() { showSettings() }

    @objc private func quit() { NSApp.terminate(nil) }

    func showSettings() {
        if settings == nil { settings = SettingsWindowController() }
        settings?.show()
    }

    func startCapture(mode: CaptureMode = .screenshot) {
        guard capture == nil, !startingCapture, recording == nil, !startingRecording else { return }
        guard ScreenCapture.hasPermission() else {
            if mode == .addToStage { stage?.show() }
            ScreenCapture.askPermission()
            return
        }
        startingCapture = true
        Task {
            defer { startingCapture = false }
            do {
                let shots = try await ScreenCapture.captureAllScreens()
                guard !shots.isEmpty else {
                    if mode == .addToStage { stage?.show() }
                    return
                }
                let controller = CaptureController(shots: shots, mode: mode,
                                                   onRecord: { screen, rect in self.startRecording(screen: screen, rect: rect) },
                                                   onSendToStage: { item, captureAgain in self.addToStage(item, captureAgain: captureAgain) },
                                                   onClose: {
                                                       self.capture = nil
                                                       // Esc ao escolher mais uma captura: volta para o palco.
                                                       if mode == .addToStage { self.stage?.show() }
                                                   })
                capture = controller
                controller.show()
            } catch {
                if mode == .addToStage { stage?.show() }
                ScreenCapture.askPermission(error: error)
            }
        }
    }

    // MARK: Palco

    /// Uma captura vai para o palco (abre o palco se ainda não existe). `captureAgain`: já escolhe a próxima.
    private func addToStage(_ item: StageItem, captureAgain: Bool) {
        if let stage {
            stage.add(item)
        } else {
            let stage = StageWindowController(first: item)
            stage.onAddCapture = { [weak self] in self?.captureForStage() }
            stage.onClose = { [weak self] in self?.stage = nil }
            self.stage = stage
        }
        if captureAgain { captureForStage() } else { stage?.show() }
    }

    /// Esconde o palco (para ele não sair na foto) e abre o seletor de mais uma captura.
    private func captureForStage() {
        stage?.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.startCapture(mode: .addToStage) }
    }

    func startRecording(screen: NSScreen, rect: CGRect?) {
        guard recording == nil, !startingRecording, let statusItem else { return }
        startingRecording = true
        Task {
            defer { startingRecording = false }
            do {
                recording = try await RecordingController.start(screen: screen, rect: rect, statusItem: statusItem) {
                    self.recording = nil
                }
            } catch {
                RecordingController.alert("Não foi possível começar a gravar", error.localizedDescription)
            }
        }
    }
}
