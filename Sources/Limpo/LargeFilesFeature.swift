import SwiftUI
import AppKit

enum FileCategory: String, CaseIterable, Identifiable {
    case all, audio, video, image, documents, packages, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Todos os Arquivos"
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
        case .all: return "doc.text.fill"
        case .audio: return "music.note"
        case .video: return "play.rectangle.fill"
        case .image: return "photo.fill"
        case .documents: return "folder.fill"
        case .packages: return "shippingbox.fill"
        case .other: return "square.stack.3d.up.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .all: return [Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.2, green: 0.42, blue: 0.95)]
        case .audio: return [Color(red: 1, green: 0.45, blue: 0.55), Color(red: 0.9, green: 0.25, blue: 0.4)]
        case .video: return [Color(red: 0.7, green: 0.5, blue: 1), Color(red: 0.5, green: 0.3, blue: 0.95)]
        case .image: return [Color(red: 1, green: 0.6, blue: 0.4), Color(red: 0.95, green: 0.4, blue: 0.3)]
        case .documents: return [Color(red: 0.4, green: 0.85, blue: 0.55), Color(red: 0.2, green: 0.7, blue: 0.4)]
        case .packages: return [Color(red: 0.4, green: 0.55, blue: 1), Color(red: 0.25, green: 0.35, blue: 0.85)]
        case .other: return [Color(red: 0.35, green: 0.85, blue: 0.75), Color(red: 0.15, green: 0.65, blue: 0.6)]
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
                icon: "folder.fill",
                colors: [Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.2, green: 0.42, blue: 0.95)],
                title: "Arquivos Grandes",
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
                TopBar(title: "Arquivos Grandes") { model.reset() }
                HStack(alignment: .top, spacing: 26) {
                    categoryList(model)
                    fileList(model)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
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

    private func categoryList(_ model: LargeFilesModel) -> some View {
        VStack(spacing: 4) {
            ForEach(FileCategory.allCases) { category in
                let bytes = model.bytes(in: category)
                Button {
                    model.category = category
                } label: {
                    HStack(spacing: 14) {
                        IconTile(icon: category.icon, colors: category.colors, size: 38)
                        Text(category.title).font(.system(size: 15))
                        Spacer()
                        Text(bytes == 0 ? "0 bytes" : Bytes.str(bytes))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 62)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(model.category == category ? Color.white.opacity(0.09) : .clear)
                    )
                    .opacity(bytes == 0 && category != .all ? 0.55 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(width: 380)
    }

    private func fileList(_ model: LargeFilesModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.category.title)
                .font(.system(size: 24, weight: .semibold))
            Text("Maiores arquivos encontrados na sua pasta de usuário.")
                .foregroundStyle(Theme.muted)

            HStack {
                Button(model.visible.allSatisfy { model.selected.contains($0.id) } && !model.visible.isEmpty
                       ? "Desmarcar todos" : "Selecionar todos") {
                    model.toggleAllVisible()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentLight)
                Spacer()
                Menu {
                    Button("Tamanho") { model.sort = .size }
                    Button("Data de modificação") { model.sort = .date }
                } label: {
                    Text(model.sort == .size ? "Ordenar por Tamanho" : "Ordenar por Data")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.top, 14)

            if !model.failed.isEmpty {
                Text("Não foi possível mover: \(model.failed.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }

            if model.visible.isEmpty {
                Text("Nenhum arquivo nesta categoria.")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.visible) { file in
                            FileRow(file: file, selected: model.selected.contains(file.id)) {
                                model.toggle(file)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FileRow: View {
    let file: LargeFile
    let selected: Bool
    let toggle: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d 'de' MMM. 'de' yyyy"
        return f
    }()

    var body: some View {
        HStack(spacing: 14) {
            CheckBox(on: selected)
            FileIcon(path: file.path, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(Bytes.str(file.size))
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Mostrar no Finder")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var subtitle: String {
        let folder = (file.path as NSString).deletingLastPathComponent
            .replacingOccurrences(of: MoleCLI.home, with: "~")
        guard let date = file.modified else { return folder }
        return "\(Self.dateFormatter.string(from: date)) · \(folder)"
    }
}
