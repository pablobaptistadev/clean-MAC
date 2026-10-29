import AppKit
import ScreenCaptureKit

// MARK: - Captura de todas as telas (ScreenCaptureKit) antes de mostrar o seletor

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
}

@MainActor
enum ScreenCapture {
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Fotografa cada tela na resolução real dela (Retina incluída), sem o cursor.
    static func captureAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(screen: screen, image: image))
        }
        return shots
    }

    /// Pede a permissão de Gravação de Tela (o macOS mostra o pedido uma vez) e explica onde ativar.
    static func askPermission(error: Error? = nil) {
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "O PrintScreen precisa de permissão para ver a tela"
        alert.informativeText = "Abra Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema, ative o PrintScreen e tente de novo."
            + (error.map { "\n\n(\($0.localizedDescription))" } ?? "")
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora não")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
