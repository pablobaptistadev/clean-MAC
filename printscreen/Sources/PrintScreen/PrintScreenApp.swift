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
                                                   onNewCapture: {
                                                       // Espera as janelas do seletor sumirem para elas não saírem na foto nova.
                                                       DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startCapture(mode: mode) }
                                                   },
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
