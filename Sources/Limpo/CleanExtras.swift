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
            VStack(spacing: 18) {
                IconTile(icon: "externaldrive.fill", size: 100).padding(.bottom, 8)
                Text("Disco externo").font(.system(size: 32, weight: .semibold))
                Text("Remove metadados que o macOS espalha em pen drives e HDs externos (.DS_Store, arquivos ._, .Trashes, .Spotlight, .fseventsd). Seus arquivos não são tocados.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                if volumes.isEmpty {
                    Text("Nenhum disco externo conectado.").foregroundStyle(Theme.muted).padding(.top, 30)
                } else {
                    VStack(spacing: 8) {
                        ForEach(volumes, id: \.self) { volume in
                            Button {
                                Task { await model.preview(volume) }
                            } label: {
                                HStack(spacing: 12) {
                                    FileIcon(path: volume, size: 30)
                                    Text((volume as NSString).lastPathComponent).font(.system(size: 15, weight: .medium))
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                                }
                                .padding(.horizontal, 16)
                                .frame(width: 420, height: 52)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .scanning:
            BusyView(title: "Analisando \((model.volume.map { ($0 as NSString).lastPathComponent }) ?? "disco")…", subtitle: "")

        case .running:
            BusyView(title: "Limpando o disco…", subtitle: "Não desconecte o disco.")

        case .preview, .done:
            VStack(spacing: 0) {
                TopBar(title: model.volume.map { ($0 as NSString).lastPathComponent } ?? "Disco externo") { model.reset() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let error = model.error { Text(error).foregroundStyle(Theme.danger) }
                        if model.sections.isEmpty {
                            Text(model.phase == .done ? "Pronto." : "Nada para limpar neste disco.").foregroundStyle(Theme.muted)
                        }
                        ForEach(model.sections) { OutputSectionCard(section: $0) }
                        ForEach(model.summary, id: \.self) { Text($0).foregroundStyle(Theme.muted) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                }
                HStack {
                    Spacer()
                    if model.phase == .preview {
                        Button("Limpar disco") { Task { await model.run() } }
                            .buttonStyle(PillButtonStyle(width: 260))
                    } else {
                        Button("Ejetar") {
                            if let v = model.volume { try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: v)) }
                            model.reset()
                        }
                        .buttonStyle(PillButtonStyle(width: 260))
                    }
                }
                .padding(.horizontal, 28)
                .frame(height: 84)
                .background(Theme.bar)
            }
        }
    }
}
