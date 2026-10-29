import SwiftUI
import AppKit

// MARK: - Lista genérica "escanear → selecionar → mover para a Lixeira"
// Usada por Projetos (artefatos de build, como o `mo purge`) e Instaladores (como o `mo installer`).

struct TrashItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let group: String
    let detail: String
    let size: Int64
    let modified: Date?
    let preselected: Bool
}

@MainActor
@Observable
final class ScanListModel {
    enum Phase { case idle, scanning, results }

    let scanner: @Sendable () async -> [TrashItem]
    var phase: Phase = .idle
    var items: [TrashItem] = []
    var selected: Set<String> = []
    var failed: [String] = []
    var confirm = false
    var progress = ""
    /// Grupo escolhido na coluna da esquerda (nil = todos).
    var group: String?

    init(scanner: @escaping @Sendable () async -> [TrashItem]) {
        self.scanner = scanner
    }

    var groups: [(name: String, items: [TrashItem])] {
        let dict = Dictionary(grouping: items, by: \.group)
        return dict.map { ($0.key, $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.items.reduce(0) { $0 + $1.size } > $1.items.reduce(0) { $0 + $1.size } }
    }

    var visibleItems: [TrashItem] {
        (group.map { g in items.filter { $0.group == g } } ?? items).sorted { $0.size > $1.size }
    }

    func toggleVisible() {
        let ids = Set(visibleItems.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() async {
        phase = .scanning
        let found = await scanner()
        items = found
        selected = Set(found.filter(\.preselected).map(\.id))
        failed = []
        group = nil
        phase = .results
    }

    func toggle(_ item: TrashItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func trashSelected() {
        var removed = Set<String>()
        failed = []
        for item in items where selected.contains(item.id) {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                removed.insert(item.id)
            } catch {
                failed.append(item.name)
            }
        }
        items.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
    }

    func reset() {
        phase = .idle
        items = []
        selected = []
    }
}

struct ScanListView: View {
    let model: ScanListModel
    let icon: String
    let title: String
    let subtitle: String
    let busy: String
    let empty: String
    /// Ícone de cada grupo na coluna da esquerda (pasta do projeto, local do instalador).
    var groupIcon = "folder"
    var listSubtitle = ""

    var body: some View {
        switch model.phase {
        case .idle:
            HeroView(icon: icon, title: title, subtitle: subtitle, button: "Analisar") {
                Task { await model.scan() }
            }
        case .scanning:
            BusyView(title: busy)
        case .results:
            VStack(spacing: 0) {
                TopBar(title: title) { model.reset() }
                if model.items.isEmpty {
                    EmptyResult(title: empty)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        FilterColumn {
                            FilterRow(symbol: "square.grid.2x2", title: "Todos", value: Bytes.str(model.total), active: model.group == nil) {
                                model.group = nil
                            }
                            ForEach(model.groups, id: \.name) { group in
                                FilterRow(symbol: groupIcon, title: group.name, value: Bytes.str(group.items.reduce(0) { $0 + $1.size }),
                                          active: model.group == group.name) {
                                    model.group = group.name
                                }
                            }
                        }
                        list
                    }
                }
                BottomBar(
                    selected: model.selectedBytes,
                    total: model.total,
                    selectedLabel: "Selecionado",
                    button: "Mover para a Lixeira",
                    enabled: !model.selected.isEmpty
                ) {
                    model.confirm = true
                }
            }
            .alert("Mover \(model.selected.count) item(ns) para a Lixeira?", isPresented: Binding(get: { model.confirm }, set: { model.confirm = $0 })) {
                Button("Cancelar", role: .cancel) {}
                Button("Mover para a Lixeira", role: .destructive) { model.trashSelected() }
            } message: {
                Text("\(Bytes.str(model.selectedBytes)) serão movidos. Dá para recuperar pela Lixeira.")
            }
        }
    }

    private var list: some View {
        let visible = model.visibleItems
        let allOn = !visible.isEmpty && Set(visible.map(\.id)).isSubset(of: model.selected)
        return VStack(alignment: .leading, spacing: 0) {
            ListHeader(title: model.group ?? "Todos", subtitle: listSubtitle) {
                Button(allOn ? "Desmarcar todos" : "Marcar todos") { model.toggleVisible() }
                    .buttonStyle(LinkButtonStyle())
            }
            if !model.failed.isEmpty {
                Text("Não foi possível mover: \(model.failed.joined(separator: ", "))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { item in
                        FileCheckRow(path: item.path, name: item.name,
                                     detail: model.group == nil ? "\(item.group) · \(item.detail)" : item.detail,
                                     size: item.size, selected: model.selected.contains(item.id)) {
                            model.toggle(item)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Utilitários de varredura

enum FS {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func tilde(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Tamanho de pasta via `du -sk` (rápido e conta blocos reais).
    static func duSize(_ path: String) async -> Int64 {
        guard let out = try? await Shell.run("/usr/bin/du", ["-sk", path]) else { return 0 }
        let kb = Int64(out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "0") ?? 0
        return kb * 1024
    }

    static func sizes(of paths: [String]) async -> [String: Int64] {
        await withTaskGroup(of: (String, Int64).self) { group in
            var result: [String: Int64] = [:]
            var iterator = paths.makeIterator()
            for _ in 0..<min(8, paths.count) {
                if let next = iterator.next() { group.addTask { (next, await duSize(next)) } }
            }
            while let (path, size) = await group.next() {
                result[path] = size
                if let next = iterator.next() { group.addTask { (next, await duSize(next)) } }
            }
            return result
        }
    }

    static func readConfigLines(_ file: String) -> [String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
    }
}

// MARK: - Projetos (equivalente ao `mo purge`)

enum PurgeScanner {
    static let configFile = FS.home + "/.config/mole/purge_paths"

    static let defaultRoots = ["www", "dev", "Projects", "GitHub", "Code", "Workspace", "Repos", "Development", "Developer", "Sites", "Local Sites"]
        .map { FS.home + "/" + $0 } + [FS.home + "/.codex/worktrees", FS.home + "/.claude/worktrees"]

    static let alwaysTargets: Set<String> = [
        "node_modules", "venv", ".venv", ".pytest_cache", ".mypy_cache", ".tox", ".nox", ".ruff_cache",
        ".gradle", ".terragrunt-cache", "__pycache__", ".next", ".nuxt", ".turbo", ".parcel-cache",
        ".dart_tool", ".zig-cache", "zig-out", ".angular", ".svelte-kit", ".astro", "DerivedData", ".cxx", ".expo", ".build"
    ]
    static let guardedTargets: Set<String> = ["target", "build", "dist", ".output", "coverage", "out", "vendor", "bin", "obj", "Pods"]

    static let projectIndicators = [
        "package.json", "Cargo.toml", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "CMakeLists.txt",
        "Makefile", "pyproject.toml", "setup.py", "Package.swift", "pubspec.yaml", "go.mod", "composer.json", "angular.json",
        "nuxt.config.ts", "vite.config.ts", "Podfile", "Gemfile"
    ]

    static var roots: [String] {
        let custom = FS.readConfigLines(configFile)
        let list = custom.isEmpty ? defaultRoots : custom
        return list.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func scan() async -> [TrashItem] {
        let found = await Task.detached(priority: .userInitiated) { () -> [String] in
            var results: [String] = []
            for root in roots { walk(root, depth: 0, into: &results) }
            return results
        }.value

        let sizes = await FS.sizes(of: found)
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        return found.compactMap { path in
            let size = sizes[path] ?? 0
            guard size > 1024 * 1024 else { return nil }
            let project = (path as NSString).deletingLastPathComponent
            let modified = FS.modified(path)
            let recent = (modified ?? .distantPast) > weekAgo
            let date = modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? ""
            return TrashItem(
                path: path,
                name: (path as NSString).lastPathComponent,
                group: FS.tilde(project),
                detail: recent ? "Usado nos últimos 7 dias · \(date)" : "Modificado em \(date)",
                size: size,
                modified: modified,
                preselected: !recent
            )
        }
    }

    private static func walk(_ dir: String, depth: Int, into results: inout [String]) {
        guard depth <= 6 else { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let childSet = Set(children)
        for name in children {
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { continue }

            if alwaysTargets.contains(name) || (guardedTargets.contains(name) && guardPasses(name, siblings: childSet)) {
                results.append(path)
                continue
            }
            if name.hasPrefix(".") || name.hasSuffix(".app") || name == "Library" { continue }
            walk(path, depth: depth + 1, into: &results)
        }
    }

    private static func guardPasses(_ name: String, siblings: Set<String>) -> Bool {
        switch name {
        case "vendor": return siblings.contains("composer.json") || siblings.contains("go.mod") || siblings.contains("Gemfile")
        case "bin", "obj": return siblings.contains { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix(".sln") }
        case "Pods": return siblings.contains("Podfile")
        default: return projectIndicators.contains { siblings.contains($0) }
        }
    }
}

// MARK: - Instaladores (equivalente ao `mo installer`)

enum InstallerScanner {
    static let locations: [(label: String, path: String)] = [
        ("Downloads", FS.home + "/Downloads"),
        ("Mesa", FS.home + "/Desktop"),
        ("Documentos", FS.home + "/Documents"),
        ("Público", FS.home + "/Public"),
        ("Downloads (Library)", FS.home + "/Library/Downloads"),
        ("Compartilhado", "/Users/Shared"),
        ("Homebrew", FS.home + "/Library/Caches/Homebrew"),
        ("iCloud Drive", FS.home + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads"),
        ("Mail", FS.home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
        ("Telegram", FS.home + "/Library/Application Support/Telegram Desktop"),
        ("Telegram", FS.home + "/Downloads/Telegram Desktop")
    ]
    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    static func scan() async -> [TrashItem] {
        await Task.detached(priority: .userInitiated) { () -> [TrashItem] in
            var items: [TrashItem] = []
            var seen = Set<String>()
            let fm = FileManager.default
            for location in locations where fm.fileExists(atPath: location.path) {
                guard let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: location.path),
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                while let url = enumerator.nextObject() as? URL {
                    if enumerator.level > 2 { enumerator.skipDescendants(); continue }
                    let ext = url.pathExtension.lowercased()
                    guard extensions.contains(ext) || (ext == "zip" && zipHasInstaller(url.path)) else { continue }
                    let path = url.path
                    guard !seen.contains(path) else { continue }
                    seen.insert(path)
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = Int64(values?.fileSize ?? 0)
                    let modified = values?.contentModificationDate
                    items.append(TrashItem(
                        path: path,
                        name: url.lastPathComponent,
                        group: location.label,
                        detail: FS.tilde((path as NSString).deletingLastPathComponent),
                        size: size > 0 ? size : FS.fileSize(path),
                        modified: modified,
                        preselected: true
                    ))
                }
            }
            return items
        }.value
    }

    /// Um .zip só conta como instalador se tiver um .app, .pkg ou .dmg dentro.
    private static func zipHasInstaller(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(50)
        return lines.contains { $0.contains(".app/") || $0.hasSuffix(".pkg") || $0.hasSuffix(".dmg") }
    }
}

// MARK: - Aba Limpar (Sistema · Projetos · Instaladores)

enum CleanMode: String, CaseIterable, Identifiable {
    case system, projects, installers, external
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Sistema"
        case .projects: return "Projetos"
        case .installers: return "Instaladores"
        case .external: return "Disco externo"
        }
    }
}

struct CleanTabView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            switch store.cleanMode {
            case .system:
                CleanView()
            case .projects:
                ScanListView(
                    model: store.purge,
                    icon: "hammer",
                    title: "Projetos",
                    subtitle: "Encontra artefatos de build que podem ser recriados (node_modules, vendor, target, .next, DerivedData…) nas suas pastas de projetos. Os usados nos últimos 7 dias ficam desmarcados.",
                    busy: "Procurando artefatos de build…",
                    empty: "Nenhum artefato encontrado",
                    groupIcon: "folder",
                    listSubtitle: "Pastas de build que o projeto recria. As usadas nos últimos 7 dias ficam desmarcadas."
                )
            case .installers:
                ScanListView(
                    model: store.installers,
                    icon: "shippingbox",
                    title: "Instaladores",
                    subtitle: "Encontra arquivos .dmg, .pkg, .iso, .xip e .zip de instalação esquecidos em Downloads, Mesa, iCloud, Mail, Telegram e no cache do Homebrew.",
                    busy: "Procurando instaladores…",
                    empty: "Nenhum instalador esquecido",
                    groupIcon: "tray.and.arrow.down",
                    listSubtitle: "Arquivos de instalação que já cumpriram o papel."
                )
            case .external:
                ExternalCleanView()
            }
        }
    }
}
