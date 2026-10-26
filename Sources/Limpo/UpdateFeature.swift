import SwiftUI
import AppKit

// MARK: - Atualização do Limpo (GitHub Releases)

/// Última Release publicada em github.com/pablobaptistadev/clean-MAC (tag vX.Y.Z com o Limpo-X.Y.Z.dmg anexado).
struct LimpoRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browser_download_url: String
    }

    let tag_name: String
    let html_url: String
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Updater {
    static let bundleID = "br.com.pablobaptista.limpo"

    /// `defaults write br.com.pablobaptista.limpo updateFeedURL <url>` troca a fonte (para testar uma versão falsa).
    static var feedURL: URL {
        UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/pablobaptistadev/clean-MAC/releases/latest")!
    }

    static func fetchLatest() async throws -> LimpoRelease {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Limpo/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("o GitHub respondeu \(http.statusCode)")
        }
        return try JSONDecoder().decode(LimpoRelease.self, from: data)
    }

    /// Compara versões numéricas (1.10.0 > 1.9.2).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Motivo para não conseguir trocar o app onde ele está, ou nil se dá.
    static func installProblem(_ target: URL) -> String? {
        let path = target.path
        if target.pathExtension != "app" { return "A atualização só funciona no Limpo.app instalado." }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Arraste o Limpo para a pasta Aplicativos antes de atualizar."
        }
        let parent = target.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) || !FileManager.default.isWritableFile(atPath: path) {
            return "Sem permissão para trocar o app em \(parent). Baixe o .dmg pela página da versão."
        }
        return nil
    }

    /// Baixa o .dmg, copia o Limpo.app de dentro dele para uma pasta temporária e confere
    /// se é mesmo o Limpo na versão esperada, com a assinatura íntegra.
    static func stage(_ release: LimpoRelease) async throws -> URL {
        guard let asset = release.dmg, let url = URL(string: asset.browser_download_url) else {
            throw UpdateError("a versão \(release.version) não tem .dmg anexado")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("limpo-update-\(release.version)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let (downloaded, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("o download respondeu \(http.statusCode)")
        }
        let dmg = dir.appendingPathComponent(asset.name)
        try fm.moveItem(at: downloaded, to: dmg)

        let mount = dir.appendingPathComponent("volume")
        let staged = dir.appendingPathComponent("Limpo.app")
        try await exec("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        var copyError: Error?
        do {
            try await exec("/usr/bin/ditto", [mount.appendingPathComponent("Limpo.app").path, staged.path])
        } catch {
            copyError = error
        }
        _ = try? await exec("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        if let copyError { throw copyError }

        guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError("o .dmg baixado não contém o Limpo")
        }
        guard info["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("o .dmg baixado não é da versão \(release.version)")
        }
        try await exec("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        return staged
    }

    /// Script que espera o Limpo atual fechar, troca o app no lugar e abre a versão nova.
    /// Se a troca falhar, devolve o app antigo e abre ele.
    static func swapScript(target: URL, staged: URL, pid: Int32) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/bash
        # Gerado pelo Limpo: troca o app pela versão nova depois que ele fechar.
        PID=\(pid)
        TARGET=\(q(target.path))
        NEW=\(q(staged.path))
        OLD="$TARGET.old"
        for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        rm -rf "$OLD"
        if mv "$TARGET" "$OLD"; then
          if mv "$NEW" "$TARGET" || /usr/bin/ditto "$NEW" "$TARGET"; then
            rm -rf "$OLD"
          else
            rm -rf "$TARGET"
            mv "$OLD" "$TARGET"
          fi
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1
        /usr/bin/open "$TARGET"
        rm -rf "$(dirname "$NEW")"
        """
    }

    /// Roda o script de troca solto do app (ele continua depois que o Limpo fecha).
    static func launchSwap(target: URL, staged: URL, pid: Int32) throws {
        let script = staged.deletingLastPathComponent().appendingPathComponent("install.sh")
        try swapScript(target: target, staged: staged, pid: pid).write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    @discardableResult
    static func exec(_ path: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0 else {
                throw UpdateError("\((path as NSString).lastPathComponent) falhou: \(text.suffix(200))")
            }
            return text
        }.value
    }
}

@MainActor
@Observable
final class UpdateModel {
    enum Phase { case idle, checking, upToDate, available, installing }

    var phase: Phase = .idle
    var release: LimpoRelease?
    var error: String?
    /// Avisa quando a procura automática acha uma versão nova (notificação do macOS).
    var onFound: ((LimpoRelease) -> Void)?

    private var loop: Task<Void, Never>?

    var autoCheck: Bool {
        get { access(keyPath: \.autoCheck); return UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true }
        set { withMutation(keyPath: \.autoCheck) { UserDefaults.standard.set(newValue, forKey: "updateAutoCheck") } }
    }
    /// Versão que o usuário mandou para "Depois": o aviso some até sair outra ou ele procurar de novo.
    var dismissed: String? {
        get { access(keyPath: \.dismissed); return UserDefaults.standard.string(forKey: "updateDismissedVersion") }
        set { withMutation(keyPath: \.dismissed) { UserDefaults.standard.set(newValue, forKey: "updateDismissedVersion") } }
    }

    var bannerVisible: Bool {
        guard let release else { return false }
        return phase == .installing || (phase == .available && release.version != dismissed)
    }

    var statusText: String {
        if let error { return error }
        switch phase {
        case .idle: return autoCheck ? "Procura uma vez por dia no GitHub" : "Procura automática desligada"
        case .checking: return "Procurando…"
        case .upToDate: return "Você está na versão mais recente (\(AppInfo.version))"
        case .available: return "Versão \(release?.version ?? "") disponível · você está na \(AppInfo.version)"
        case .installing: return "Baixando e instalando…"
        }
    }

    /// Procura ao abrir o app e depois a cada 24 h.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                if self?.autoCheck == true { await self?.check(manual: false) }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check(manual: Bool) async {
        guard phase != .checking, phase != .installing else { return }
        phase = .checking
        error = nil
        do {
            let latest = try await Updater.fetchLatest()
            guard Updater.isNewer(latest.version, than: AppInfo.version) else {
                release = nil
                phase = .upToDate
                return
            }
            release = latest
            phase = .available
            if manual {
                dismissed = nil
            } else if UserDefaults.standard.string(forKey: "updateNotifiedVersion") != latest.version {
                UserDefaults.standard.set(latest.version, forKey: "updateNotifiedVersion")
                onFound?(latest)
            }
        } catch {
            phase = .idle
            self.error = "Não foi possível procurar atualizações: \(error.localizedDescription)"
        }
    }

    func install() async {
        guard let release, phase == .available else { return }
        let target = Bundle.main.bundleURL
        if let problem = Updater.installProblem(target) {
            error = problem
            return
        }
        phase = .installing
        error = nil
        do {
            let staged = try await Updater.stage(release)
            try Updater.launchSwap(target: target, staged: staged, pid: getpid())
            NSApp.terminate(nil)
        } catch {
            phase = .available
            self.error = "A atualização falhou: \(error.localizedDescription)"
        }
    }

    func openReleasePage() {
        guard let url = URL(string: release?.html_url ?? "https://github.com/pablobaptistadev/clean-MAC/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Aviso na janela principal

struct UpdateBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.updates
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Palette.cpu)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nova versão do Limpo: \(model.release?.version ?? "")")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(model.error ?? "Você está na \(AppInfo.version). Atualizar baixa a versão nova, troca o app e reabre o Limpo.")
                    .font(.system(size: 12))
                    .foregroundStyle(model.error == nil ? Theme.muted : Palette.warm)
                    .lineLimit(2)
            }
            Spacer()
            if model.phase == .installing {
                ProgressView().controlSize(.small)
                Text("Atualizando…").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            } else {
                Button("Novidades") { model.openReleasePage() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentLight)
                Button("Depois") { model.dismissed = model.release?.version }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                Button {
                    Task { await model.install() }
                } label: {
                    Text("Atualizar")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(Capsule().fill(Color(white: 0.96)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12.5))
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cpu.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cpu.opacity(0.30), lineWidth: 1))
    }
}
