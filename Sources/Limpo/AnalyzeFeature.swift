import SwiftUI
import AppKit

// MARK: - Explorador de disco (`mo analyze --json <pasta>`)

struct DiskEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let size: Int64
    let is_dir: Bool
    let cleanable: Bool?
    let insight: Bool?
    let last_access: String?
    var id: String { path }
}

private struct AnalyzeListing: Decodable {
    let path: String?
    let entries: [DiskEntry]?
    let total_size: Int64?
}

@MainActor
@Observable
final class ExplorerModel {
    var stack: [String] = []
    var entries: [DiskEntry] = []
    var total: Int64 = 0
    var loading = false
    var error: String?
    var pendingTrash: DiskEntry?
    private var cache: [String: (entries: [DiskEntry], total: Int64)] = [:]

    var current: String? { stack.last }

    func start() async {
        guard stack.isEmpty else { return }
        await open("")   // "" = visão geral do `mo analyze` (Home, Library, Apps + espaço oculto)
    }

    func open(_ path: String) async {
        stack.append(path)
        await load(path)
    }

    func jump(to index: Int) async {
        guard index < stack.count else { return }
        stack = Array(stack.prefix(index + 1))
        await load(stack[index])
    }

    func back() async {
        guard stack.count > 1 else { return }
        stack.removeLast()
        await load(stack.last!)
    }

    func choose() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (current ?? "").isEmpty ? FS.home : current!)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stack = []
        await open(url.path)
    }

    static func volumes() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    func openRoot(_ path: String) async {
        stack = [""]
        await open(path)
    }

    func reload() async {
        guard let current else { return }
        cache[current] = nil
        await load(current)
    }

    func reset() {
        stack = []
        entries = []
        total = 0
        error = nil
    }

    private func load(_ path: String) async {
        if let cached = cache[path] {
            entries = cached.entries
            total = cached.total
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await MoleCLI.run(path.isEmpty ? ["analyze", "--json"] : ["analyze", "--json", path])
            guard let data = result.output.jsonPayload(startingWith: "{") else {
                throw MoleError.failed("O mo analyze não devolveu JSON para essa pasta.")
            }
            let listing = try JSONDecoder().decode(AnalyzeListing.self, from: data)
            let list = (listing.entries ?? []).sorted { $0.size > $1.size }
            let sum = listing.total_size ?? list.reduce(0) { $0 + $1.size }
            cache[path] = (list, sum)
            if current == path {
                entries = list
                total = sum
            }
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
    }

    func trash(_ entry: DiskEntry) async {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
            cache = [:]
            await reload()
        } catch {
            self.error = "Não foi possível mover \(entry.name): \(error.localizedDescription)"
        }
    }
}

enum AnalyzeMode: String, CaseIterable {
    case explorer, largeFiles
    var title: String { self == .explorer ? "Explorador" : "Arquivos grandes" }
}

struct AnalyzeTabView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            switch store.analyzeMode {
            case .explorer: ExplorerView()
            case .largeFiles: LargeFilesView()
            }
        }
    }
}

struct ExplorerView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.explorer

        Group {
            if model.stack.isEmpty {
                HeroView(
                    icon: "chart.pie",
                    title: "Espaço em disco",
                    subtitle: "Mostra o que ocupa espaço no seu Mac, pasta por pasta, e aponta o que pode ser limpo e o espaço que o macOS esconde.",
                    button: "Analisar",
                    error: model.error
                ) {
                    Task { await model.start() }
                }
            } else {
                VStack(spacing: 0) {
                    TopBar(title: "Espaço em disco") { model.reset() }
                    header(model)
                    if let error = model.error {
                        Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger).padding(.horizontal, 24).padding(.bottom, 6)
                    }
                    if model.loading && model.entries.isEmpty {
                        BusyView(title: "Medindo pastas…", subtitle: "A primeira análise de uma pasta grande demora; as próximas usam cache.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                                    row(entry, index: index, model: model)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                        .overlay(alignment: .top) {
                            if model.loading { ProgressView().controlSize(.small).padding(8) }
                        }
                    }
                }
            }
        }
        .alert(
            "Mover \(model.pendingTrash?.name ?? "") para o Lixo?",
            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } })
        ) {
            Button("Cancelar", role: .cancel) { model.pendingTrash = nil }
            Button("Mover para o Lixo", role: .destructive) {
                if let entry = model.pendingTrash { Task { await model.trash(entry) } }
                model.pendingTrash = nil
            }
        } message: {
            Text("\(Bytes.str(model.pendingTrash?.size ?? 0)). Dá para recuperar pelo Lixo.")
        }
    }

    private func title(_ path: String, index: Int, model: ExplorerModel) -> String {
        if path.isEmpty { return "Visão geral" }
        return (index == 0 || model.stack.first == "" && index == 1) ? FS.tilde(path) : (path as NSString).lastPathComponent
    }

    /// Nome da pasta atual, caminho clicável e controles (voltar, medir de novo, discos, escolher pasta).
    private func header(_ model: ExplorerModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { Task { await model.back() } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .disabled(model.stack.count < 2)
                    .opacity(model.stack.count < 2 ? 0.35 : 1)
                    .help("Pasta anterior")
                Text(title(model.current ?? "", index: model.stack.count - 1, model: model))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Bytes.str(model.total)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .help("Medir de novo")
                Menu("Discos") {
                    ForEach(ExplorerModel.volumes(), id: \.self) { volume in
                        Button(volume) { Task { await model.openRoot("/Volumes/" + volume) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.muted)
                Button("Escolher pasta…") { Task { await model.choose() } }
                    .buttonStyle(LinkButtonStyle())
            }
            if model.stack.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.stack.enumerated()), id: \.offset) { index, path in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.muted) }
                        Button { Task { await model.jump(to: index) } } label: {
                            Text(title(path, index: index, model: model))
                                .foregroundStyle(index == model.stack.count - 1 ? Theme.text : Theme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.system(size: 11.5))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func row(_ entry: DiskEntry, index: Int, model: ExplorerModel) -> some View {
        let fraction = Double(entry.size) / Double(max(model.entries.first?.size ?? 1, 1))
        let share = Double(entry.size) / Double(max(model.total, 1))
        let color = barColor(index: index, entry: entry)
        return HStack(spacing: 12) {
            FileIcon(path: entry.path, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    if entry.insight == true {
                        Chip(text: "Espaço oculto", strong: true)
                    } else if entry.cleanable == true {
                        Chip(text: "Pode limpar")
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.06))
                        Capsule()
                            .fill(color)
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
            Text(String(format: "%.1f%%", share * 100))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 54, alignment: .trailing)
            Text(Bytes.str(entry.size))
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Menu {
                if entry.is_dir {
                    Button { Task { await model.open(entry.path) } } label: { Label("Abrir", systemImage: "folder") }
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: {
                    Label("Mostrar no Finder", systemImage: "magnifyingglass")
                }
                Divider()
                Button { model.pendingTrash = entry } label: { Label("Mover para o Lixo…", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.is_dir ? Theme.muted : .clear)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.is_dir { Task { await model.open(entry.path) } }
        }
    }

    private func barColor(index: Int, entry: DiskEntry) -> Color {
        let colors = [Palette.disk, Palette.violet, Palette.network, Palette.cpu, Palette.memory, Palette.gpu]
        return entry.is_dir ? colors[index % colors.count] : Palette.memory
    }
}
