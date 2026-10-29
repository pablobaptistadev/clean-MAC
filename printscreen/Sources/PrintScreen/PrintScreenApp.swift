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

        HotKey.shared.onPress = { [weak self] in self?.startCapture() }
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

    @objc private func openSettings() { showSettings() }

    @objc private func quit() { NSApp.terminate(nil) }

    func showSettings() {
        if settings == nil { settings = SettingsWindowController() }
        settings?.show()
    }

    func startCapture() {
        guard capture == nil else { return }
        guard ScreenCapture.hasPermission() else {
            ScreenCapture.askPermission()
            return
        }
        Task {
            do {
                let shots = try await ScreenCapture.captureAllScreens()
                guard !shots.isEmpty else { return }
                let controller = CaptureController(shots: shots) { self.capture = nil }
                capture = controller
                controller.show()
            } catch {
                ScreenCapture.askPermission(error: error)
            }
        }
    }
}
