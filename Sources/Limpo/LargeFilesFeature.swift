import SwiftUI
import AppKit

enum FileCategory: String, CaseIterable, Identifiable {
    case all, audio, video, image, documents, packages, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Todos os arquivos"
        case .audio: return "Áudio"
        case .video: return "Vídeo"
        case .image: return "Imagem"
        case .documents: return "Documentos"
        case .packages: return "Pacotes"
        case .other: return "Outros"
        }
    }

    var icon: String {
        switch self {
        case .all: return "doc.on.doc"
        case .audio: return "music.note"
        case .video: return "play.rectangle"
        case .image: return "photo"
        case .documents: return "doc.text"
        case .packages: return "shippingbox"
        case .other: return "square.stack.3d.up"
        }
    }

    static func of(path: String) -> FileCategory {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp3", "wav", "aac", "m4a", "flac", "aiff", "ogg": return .audio
        case "mp4", "mov", "mkv", "avi", "m4v", "webm", "wmv": return .video
        case "jpg", "jpeg", "png", "heic", "tiff", "psd", "raw", "gif", "webp", "svg": return .image
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "csv", "sql": return .documents
        case "zip", "dmg", "pkg", "mpkg", "iso", "xip", "rar", "7z", "tar", "gz", "tgz", "app": return .packages
        default: return .other
        }
    }
}

struct LargeFile: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let size: Int64
    let modified: Date?
    let category: FileCategory
}

private struct AnalyzeJSON: Decodable {
    struct Entry: Decodable {
        let name: String
        let path: String
        let size: Int64
    }
    let large_files: [Entry]?
}

@MainActor
@Observable
final class LargeFilesModel {
    enum Phase { case idle, scanning, results }
    enum Sort { case size, date }

    var phase: Phase = .idle
    var files: [LargeFile] = []
    var selected: Set<String> = []
    var category: FileCategory = .all
    var sort: Sort = .size
    var error: String?
    var failed: [String] = []
    var confirmTrash = false

    var visible: [LargeFile] {
        let list = category == .all ? files : files.filter { $0.category == category }
        switch sort {
        case .size: return list.sorted { $0.size > $1.size }
        case .date: return list.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var selectedBytes: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func bytes(in category: FileCategory) -> Int64 {
        category == .all ? totalBytes : files.filter { $0.category == category }.reduce(0) { $0 + $1.size }
    }

    func scan() async {
        phase = .scanning
        error = nil
        do {
            let result = try await MoleCLI.run(["analyze", "--json", MoleCLI.home])
            guard let data = result.output.jsonPayload(startingWith: "{") else {
                throw MoleError.failed("O mo analyze não devolveu JSON.")
            }
            let decoded = try JSONDecoder().decode(AnalyzeJSON.self, from: data)
            let fm = FileManager.default
            files = (decoded.large_files ?? [])
                .filter { fm.fileExists(atPath: $0.path) }
                .map { entry in
                    let date = (try? fm.attributesOfItem(atPath: entry.path))?[.modificationDate] as? Date
                    return LargeFile(
                        name: entry.name,
                        path: entry.path,
                        size: entry.size,
                        modified: date,
                        category: FileCategory.of(path: entry.path)
                    )
                }
            selected = []
            category = .all
            phase = .results
        } catch {
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    func toggle(_ file: LargeFile) {
        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
    }

    func toggleAllVisible() {
        let ids = Set(visible.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    func trashSelected() {
        var removed = Set<String>()
        failed = []
        for file in files where selected.contains(file.id) {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
                removed.insert(file.id)
            } catch {
                failed.append(file.name)
            }
        }
        files.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
    }

    func reset() {
        phase = .idle
        files = []
        selected = []
        failed = []
    }
}

struct LargeFilesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.large

        switch model.phase {
        case .idle:
            HeroView(
                icon: "folder",
                title: "Arquivos grandes",
                subtitle: "Encontra os maiores arquivos da sua pasta de usuário. Os itens removidos vão para o Lixo, então dá para desfazer.",
                button: "Analisar",
                error: model.error
            ) {
                Task { await model.scan() }
            }

        case .scanning:
            BusyView(title: "Procurando arquivos grandes…")

        case .results:
            VStack(spacing: 0) {
                TopBar(title: "Arquivos grandes") { model.reset() }
                HStack(alignment: .top, spacing: 0) {
                    FilterColumn {
                        ForEach(FileCategory.allCases) { category in
                            let bytes = model.bytes(in: category)
                            FilterRow(symbol: category.icon, title: category.title, value: bytes == 0 ? "—" : Bytes.str(bytes),
                                      active: model.category == category) {
                                model.category = category
                            }
                            .opacity(bytes == 0 && category != .all ? 0.5 : 1)
                        }
                    }
                    fileList(model)
                }
                BottomBar(
                    selected: model.selectedBytes,
                    total: model.totalBytes,
                    selectedLabel: "Selecionado",
                    button: "Mover para o Lixo",
                    enabled: !model.selected.isEmpty
                ) {
                    model.confirmTrash = true
                }
            }
            .alert("Mover \(model.selected.count) arquivo(s) para o Lixo?", isPresented: Binding(get: { model.confirmTrash }, set: { model.confirmTrash = $0 })) {
                Button("Cancelar", role: .cancel) {}
                Button("Mover para o Lixo", role: .destructive) { model.trashSelected() }
            } message: {
                Text("\(Bytes.str(model.selectedBytes)) serão movidos. Você pode recuperar pelo Lixo.")
            }
        }
    }

    private func fileList(_ model: LargeFilesModel) -> some View {
        let allOn = !model.visible.isEmpty && model.visible.allSatisfy { model.selected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            ListHeader(title: model.category.title, subtitle: "Os maiores arquivos da sua pasta de usuário.") {
                Button(allOn ? "Desmarcar todos" : "Marcar todos") { model.toggleAllVisible() }
                    .buttonStyle(LinkButtonStyle())
                Menu(model.sort == .size ? "Ordenar por tamanho" : "Ordenar por data") {
                    Button("Tamanho") { model.sort = .size }
                    Button("Data de modificação") { model.sort = .date }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.muted)
            }
            if !model.failed.isEmpty {
                Text("Não foi possível mover: \(model.failed.joined(separator: ", "))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }
            if model.visible.isEmpty {
                Text("Nenhum arquivo nesta categoria.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { file in
                            FileCheckRow(path: file.path, name: file.name, detail: Self.detail(file), size: file.size,
                                         selected: model.selected.contains(file.id)) {
                                model.toggle(file)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d 'de' MMM 'de' yyyy"
        return f
    }()

    private static func detail(_ file: LargeFile) -> String {
        let folder = FS.tilde((file.path as NSString).deletingLastPathComponent)
        guard let date = file.modified else { return folder }
        return "\(dateFormatter.string(from: date)) · \(folder)"
    }
}
