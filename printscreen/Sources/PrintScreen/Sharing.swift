import AppKit

// MARK: - Compartilhar a captura: Notas, Mail, WhatsApp e outros apps de conversa, Mensagens, AirDrop e "Mais apps"

@MainActor
enum Sharing {
    enum Target: Equatable {
        case notes, email, messages, airDrop
        case chat(ChatApp)
    }

    /// App de conversa sem extensão de compartilhamento no macOS (como o WhatsApp): a imagem abre nele,
    /// para escolher a conversa, e também fica copiada (se ele não mostrar a imagem, é só colar com ⌘V).
    struct ChatApp: Equatable {
        let name: String
        let bundleIDs: [String]

        var url: URL? {
            bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        }
    }

    static let chatApps = [
        ChatApp(name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        ChatApp(name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        ChatApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        ChatApp(name: "Discord", bundleIDs: ["com.hnc.Discord"]),
        ChatApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        ChatApp(name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"])
    ]

    /// Só os apps de conversa instalados neste Mac.
    static var installedChatApps: [ChatApp] { chatApps.filter { $0.url != nil } }

    /// Extensão de compartilhamento do Notas (a mesma do menu Compartilhar do macOS).
    private static let notesService = NSSharingService.Name("com.apple.Notes.SharingExtension")
    private static let presenter = Presenter()

    static func appIcon(bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(icon(forApp:))
    }

    static func icon(forApp url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// Ícone do serviço do sistema (o AirDrop não tem app de onde pegar o ícone).
    static func serviceIcon(_ target: Target) -> NSImage? {
        guard let image = service(for: target)?.image.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static func service(for target: Target) -> NSSharingService? {
        switch target {
        case .notes: return NSSharingService(named: notesService)
        case .email: return NSSharingService(named: .composeEmail)
        case .messages: return NSSharingService(named: .composeMessage)
        case .airDrop: return NSSharingService(named: .sendViaAirDrop)
        case .chat: return nil
        }
    }

    /// Salva o PNG com nome de captura (é o nome que aparece no anexo e na conversa).
    static func writeTemp(png: Data) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrintScreen", isDirectory: true)
        let url = folder.appendingPathComponent(CaptureView.fileName())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
            return url
        } catch {
            RecordingController.alert("Não foi possível preparar a imagem", error.localizedDescription)
            return nil
        }
    }

    static func share(png: Data, image: NSImage, to target: Target, window: NSWindow?) {
        guard let url = writeTemp(png: png) else { return }
        if case .chat(let app) = target {
            openInChat(app, file: url, png: png, image: image)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let service = service(for: target), service.canPerform(withItems: [url]) {
            if target == .email { service.subject = url.deletingPathExtension().lastPathComponent }
            service.delegate = presenter(for: window)
            service.perform(withItems: [url])
            return
        }
        // Sem o serviço: deixa a imagem copiada e abre o app para colar.
        copy(png: png, image: image)
        switch target {
        case .notes, .email:
            let bundleID = target == .notes ? "com.apple.Notes" : "com.apple.mail"
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
            RecordingController.alert("A imagem foi copiada",
                                      target == .notes ? "No Notas, crie uma nota e cole (⌘V)." : "No e-mail novo, cole a imagem (⌘V).")
        default:
            RecordingController.alert("Não deu para abrir o compartilhamento", "A imagem foi copiada: cole (⌘V) onde quiser.")
        }
    }

    /// Abre a imagem no app de conversa (ele pede a conversa) e deixa copiada para colar, se precisar.
    private static func openInChat(_ app: ChatApp, file: URL, png: Data, image: NSImage) {
        copy(png: png, image: image)
        guard let appURL = app.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: config)
        Toast.show("Imagem copiada", detail: "No \(app.name), escolha a conversa. Se a imagem não aparecer, cole com ⌘V.",
                   at: NSEvent.mouseLocation, seconds: 3.5)
    }

    static func copy(png: Data, image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    /// Diz ao macOS em qual janela mostrar o painel do serviço (no palco); no seletor, ele abre sozinho.
    static func presenter(for window: NSWindow?) -> NSSharingServiceDelegate {
        presenter.window = window
        return presenter
    }

    private final class Presenter: NSObject, NSSharingServiceDelegate {
        weak var window: NSWindow?

        func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                            sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
            window
        }
    }
}
