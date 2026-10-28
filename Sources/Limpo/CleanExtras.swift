import SwiftUI
import AppKit

// MARK: - Proteções (whitelist) do Mole

enum Whitelist {
    static let cleanFile = FS.home + "/.config/mole/whitelist"
    static let optimizeFile = FS.home + "/.config/mole/whitelist_optimize"

    /// Padrões que o Mole protege quando ainda não existe arquivo de proteções.
    /// Um arquivo salvo substitui esses padrões, então ele é criado já com eles.
    static let cleanDefaults = [
        "~/Library/Caches/ms-playwright*",
        "~/.gradle/caches/*",
        "~/.gradle/daemon/*",
        "~/.ollama/models/*",
        "~/Library/Caches/com.nssurge.surge-mac/*",
        "~/Library/Application Support/com.nssurge.surge-mac/*",
        "~/Library/Caches/org.R-project.R/R/renv/*",
        "~/Library/Caches/JetBrains*",
        "~/Library/Caches/com.jetbrains.toolbox*",
        "~/Library/Caches/tealdeer/tldr-pages",
        "~/Library/Application Support/JetBrains*",
        "~/Library/Caches/com.apple.finder",
        "~/Library/Mobile Documents*",
        "FINDER_METADATA"
    ]

    static func lines(_ file: String) -> [String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func write(_ file: String, _ entries: [String]) {
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let body = "# Gerenciado pelo Limpo e pelo Mole — um padrão por linha\n" + entries.joined(separator: "\n") + "\n"
        try? body.write(toFile: file, atomically: true, encoding: .utf8)
    }

    static func cleanEntries() -> [String] {
        FileManager.default.fileExists(atPath: cleanFile) ? lines(cleanFile) : cleanDefaults
    }

    static func isProtected(_ path: String) -> Bool {
        let tilde = FS.tilde(path)
        return cleanEntries().contains { $0 == path || $0 == tilde }
    }

    static func protect(_ path: String) {
        var entries = cleanEntries()
        let tilde = FS.tilde(path)
        guard !entries.contains(tilde), !entries.contains(path) else { return }
        entries.append(tilde)
        write(cleanFile, entries)
    }

    static func unprotect(_ path: String) {
        let tilde = FS.tilde(path)
        write(cleanFile, cleanEntries().filter { $0 != tilde && $0 != path })
    }

    private static let temporaryKey = "cleanTemporaryWhitelist"
    private static let temporaryCreatedKey = "cleanTemporaryWhitelistCreatedFile"

    /// Protege só durante uma limpeza o que o usuário desmarcou. O que foi acrescentado fica anotado
    /// para `removeTemporary()` desfazer depois, mesmo se o app fechar no meio da limpeza.
    static func protectTemporarily(_ paths: [String]) {
        removeTemporary()
        let entries = cleanEntries()
        let added = Array(Set(paths.map(FS.tilde))).filter { !entries.contains($0) }
        guard !added.isEmpty else { return }
        UserDefaults.standard.set(added, forKey: temporaryKey)
        UserDefaults.standard.set(!FileManager.default.fileExists(atPath: cleanFile), forKey: temporaryCreatedKey)
        write(cleanFile, entries + added)
    }

    static func removeTemporary() {
        guard let added = UserDefaults.standard.stringArray(forKey: temporaryKey), !added.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: temporaryCreatedKey) {
            // O arquivo não existia antes: apagar devolve o Mole aos padrões dele.
            try? FileManager.default.removeItem(atPath: cleanFile)
        } else {
            write(cleanFile, cleanEntries().filter { !added.contains($0) })
        }
        UserDefaults.standard.removeObject(forKey: temporaryKey)
        UserDefaults.standard.removeObject(forKey: temporaryCreatedKey)
    }

    // Otimização: uma linha por tarefa que deve ser pulada
    static func skippedTasks() -> Set<String> { Set(lines(optimizeFile)) }

    static func setTask(_ id: String, skipped: Bool) {
        var set = skippedTasks()
        if skipped { set.insert(id) } else { set.remove(id) }
        write(optimizeFile, set.sorted())
    }
}

// MARK: - Caminhos da prévia (`~/.config/mole/clean-list.txt`, gerado pelo `mo clean --dry-run`)

struct CleanPath: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let note: String
}

enum CleanListFile {
    static let path = FS.home + "/.config/mole/clean-list.txt"

    static func read() -> [String: [CleanPath]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: [CleanPath]] = [:]
        var section = "Geral"
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("===") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "  # ")
            let p = parts[0].trimmingCharacters(in: .whitespaces)
            let note = parts.count > 1 ? parts[1] : ""
            result[section, default: []].append(CleanPath(path: p, note: note))
        }
        return result
    }
}

// MARK: - Disco externo (`mo clean --external /Volumes/X`)

@MainActor
@Observable
final class ExternalCleanModel {
    enum Phase { case pick, scanning, preview, running, done }

    var phase: Phase = .pick
    var volume: String?
    var sections: [OutputSection] = []
    var summary: [String] = []
    var error: String?

    static func externalVolumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsRootFileSystem != true, v?.volumeIsInternal != true, url.path.hasPrefix("/Volumes/") else { return nil }
            return url.path
        }
    }

    func preview(_ volume: String) async {
        self.volume = volume
        phase = .scanning
        await execute(["clean", "--external", volume, "--dry-run"])
        phase = .preview
    }

    func run() async {
        guard let volume else { return }
        phase = .running
        await execute(["clean", "--external", volume])
        phase = .done
    }

    private func execute(_ args: [String]) async {
        do {
            let result = try await MoleCLI.run(args, mergeStderr: true)
            let parsed = OutputParser.parse(result.output)
            sections = parsed.sections
            summary = parsed.summary
            error = result.status == 0 ? nil : ANSI.strip(result.output).components(separatedBy: "\n").last { !$0.isEmpty }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset() {
        phase = .pick
        sections = []
        summary = []
        error = nil
    }
}

struct ExternalCleanView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.external

        switch model.phase {
        case .pick:
            let volumes = ExternalCleanModel.externalVolumes()
            ZStack {
                Image(systemName: "externaldrive")
                    .font(.system(size: 300))
                    .foregroundStyle(Color.white.opacity(0.045))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .offset(x: 110)
                    .allowsHitTesting(false)
                VStack(spacing: 14) {
                    Text("Disco externo").font(.system(size: 30))
                    Text("Remove os metadados que o macOS espalha em pen drives e HDs externos (.DS_Store, arquivos ._, .Trashes, .Spotlight, .fseventsd). Seus arquivos não são tocados.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 460)
                    if volumes.isEmpty {
                        Text("Nenhum disco externo conectado.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 30)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(volumes, id: \.self) { volume in
                                Button {
                                    Task { await model.preview(volume) }
                                } label: {
                                    HStack(spacing: 12) {
                                        FileIcon(path: volume, size: 26)
                                        Text((volume as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                                        Spacer()
                                        Text("Analisar").font(.system(size: 12)).foregroundStyle(Theme.accentLight)
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(width: 420, height: 44)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 30)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

        case .scanning:
            BusyView(title: "Analisando \((model.volume.map { ($0 as NSString).lastPathComponent }) ?? "disco")…", subtitle: "")

        case .running:
            BusyView(title: "Limpando o disco…", subtitle: "Não desconecte o disco.")

        case .preview, .done:
            let name = model.volume.map { ($0 as NSString).lastPathComponent } ?? "Disco externo"
            VStack(spacing: 0) {
                ResultHeader(
                    title: model.phase == .done ? "\(name) limpo" : "Pronto para limpar \(name)",
                    subtitle: "Metadados do macOS que podem sair do disco",
                    onClose: { model.reset() }
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                        if model.sections.isEmpty {
                            Text(model.phase == .done ? "Pronto." : "Nada para limpar neste disco.").foregroundStyle(Theme.muted)
                        }
                        ForEach(model.sections) { OutputSectionCard(section: $0) }
                        ForEach(model.summary, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
                if model.phase == .preview {
                    ActionBar(button: "Limpar disco", enabled: !model.sections.isEmpty, action: { Task { await model.run() } }) {
                        Text(name).font(.system(size: 12, weight: .medium))
                    }
                } else {
                    ActionBar(button: "Ejetar", action: {
                        if let v = model.volume { try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: v)) }
                        model.reset()
                    }) {
                        Text("Pode desconectar o disco depois de ejetar.").foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}
