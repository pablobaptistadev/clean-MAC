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

    private static let requestedKey = "screenCaptureRequested"

    /// Na primeira vez mostra só o pedido do macOS. Nas seguintes não pede de novo (era o que virava loop):
    /// explica e oferece refazer a autorização, que costuma ficar presa a uma versão anterior do app.
    static func askPermission(error: Error? = nil) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: requestedKey) else {
            defaults.set(true, forKey: requestedKey)
            CGRequestScreenCaptureAccess()
            return
        }
        let alert = NSAlert()
        alert.messageText = "O PrintScreen ainda não pode ver a tela"
        alert.informativeText = """
            Se o PrintScreen já aparece ativado em Gravação de Tela e Áudio do Sistema, a autorização é de uma versão anterior do app \
            e o macOS não a aceita mais.

            Clique em Refazer autorização: a antiga é apagada, o macOS pede de novo e você ativa o PrintScreen. \
            Quando o macOS oferecer, clique em Sair e Reabrir.
            """ + (error.map { "\n\n(\($0.localizedDescription))" } ?? "")
        alert.addButton(withTitle: "Refazer autorização")
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora não")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if resetPermission() {
                CGRequestScreenCaptureAccess()
            } else {
                explainManualReset()
            }
        case .alertSecondButtonReturn:
            openSettings()
        default:
            break
        }
    }

    /// Apaga só a autorização de Gravação de Tela do próprio PrintScreen (o mesmo que o botão – nos Ajustes).
    private static func resetPermission() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", id]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func explainManualReset() {
        let alert = NSAlert()
        alert.messageText = "Remova o PrintScreen da lista"
        alert.informativeText = "Em Gravação de Tela e Áudio do Sistema, selecione o PrintScreen, clique em – e depois tire uma captura de novo para o macOS pedir a permissão."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora não")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    private static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
