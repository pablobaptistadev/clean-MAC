import AppKit

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

        // Durante uma gravação, o mesmo atalho para e salva o vídeo.
        HotKey.shared.onPress = { [weak self] in
            guard let self else { return }
            if let recording = self.recording { recording.stop() } else { self.startCapture() }
        }
        if !HotKey.shared.register(Shortcut.load()) {
            showSettings()
        }
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
        let shortcut = NSMenuItem(title: "Atalho…", action: #selector(openSettings), keyEquivalent: ",")
        shortcut.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        menu.addItem(shortcut)
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
        guard capture == nil, recording == nil, !startingRecording else { return }
        guard ScreenCapture.hasPermission() else {
            ScreenCapture.askPermission()
            return
        }
        Task {
            do {
                let shots = try await ScreenCapture.captureAllScreens()
                guard !shots.isEmpty else { return }
                let controller = CaptureController(shots: shots, mode: mode,
                                                   onRecord: { screen, rect in self.startRecording(screen: screen, rect: rect) },
                                                   onClose: { self.capture = nil })
                capture = controller
                controller.show()
            } catch {
                ScreenCapture.askPermission(error: error)
            }
        }
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
