import AppKit

// MARK: - Compartilhar a captura: nota no Notas ou e-mail no Mail

@MainActor
enum Sharing {
    enum Target {
        case notes, email
    }

    /// Extensão de compartilhamento do Notas (a mesma do menu Compartilhar do macOS).
    private static let notesService = NSSharingService.Name("com.apple.Notes.SharingExtension")
    private static let presenter = Presenter()

    static func appIcon(bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// Salva o PNG com nome de captura (é o nome que aparece no anexo) e abre o Notas ou o Mail com ele.
    static func share(png: Data, image: NSImage, to target: Target, window: NSWindow?) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrintScreen", isDirectory: true)
        let url = folder.appendingPathComponent(CaptureView.fileName())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            RecordingController.alert("Não foi possível preparar a imagem", error.localizedDescription)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let service = target == .notes ? NSSharingService(named: notesService) : NSSharingService(named: .composeEmail)
        if let service, service.canPerform(withItems: [url]) {
            if target == .email { service.subject = url.deletingPathExtension().lastPathComponent }
            presenter.window = window
            service.delegate = presenter
            service.perform(withItems: [url])
            return
        }
        // Sem o serviço: deixa a imagem copiada e abre o app para colar.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        let bundleID = target == .notes ? "com.apple.Notes" : "com.apple.mail"
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        RecordingController.alert("A imagem foi copiada",
                                  target == .notes ? "No Notas, crie uma nota e cole (⌘V)." : "No e-mail novo, cole a imagem (⌘V).")
    }

    /// Diz ao macOS em qual janela mostrar o painel do Notas (no palco); no seletor, ele abre sozinho.
    private final class Presenter: NSObject, NSSharingServiceDelegate {
        weak var window: NSWindow?

        func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                            sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
            window
        }
    }
}
