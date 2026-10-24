import SwiftUI
import AppKit

// MARK: - Lista genérica "escanear → selecionar → mover para o Lixo"
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

    init(scanner: @escaping @Sendable () async -> [TrashItem]) {
        self.scanner = scanner
    }

    var groups: [(name: String, items: [TrashItem])] {
        let dict = Dictionary(grouping: items, by: \.group)
        return dict.map { ($0.key, $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.items.reduce(0) { $0 + $1.size } > $1.items.reduce(0) { $0 + $1.size } }
    }

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() async {
        phase = .scanning
        let found = await scanner()
        items = found
        selected = Set(found.filter(\.preselected).map(\.id))
        failed = []
        phase = .results
    }

    func toggle(_ item: TrashItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func toggleGroup(_ list: [TrashItem]) {
        let ids = Set(list.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
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
                    VStack(spacing: 14) {
                        IconTile(icon: "checkmark", size: 80)
                        Text(empty).font(.system(size: 22, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if !model.failed.isEmpty {
                                Text("Não foi possível mover: \(model.failed.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.danger)
                            }
                            ForEach(model.groups, id: \.name) { group in
                                groupCard(group.name, group.items)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                    }
                }
                BottomBar(
                    selected: model.selectedBytes,
                    total: model.total,
                    selectedLabel: "Selecionado",
                    button: "Mover para o Lixo",
                    enabled: !model.selected.isEmpty
                ) {
                    model.confirm = true
                }
            }
            .alert("Mover \(model.selected.count) item(ns) para o Lixo?", isPresented: Binding(get: { model.confirm }, set: { model.confirm = $0 })) {
                Button("Cancelar", role: .cancel) {}
                Button("Mover para o Lixo", role: .destructive) { model.trashSelected() }
            } message: {
                Text("\(Bytes.str(model.selectedBytes)) serão movidos. Dá para recuperar pelo Lixo.")
            }
        }
    }

    private func groupCard(_ name: String, _ list: [TrashItem]) -> some View {
        let allOn = Set(list.map(\.id)).isSubset(of: model.selected)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { model.toggleGroup(list) } label: { CheckBox(on: allOn) }
                    .buttonStyle(.plain)
                Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Bytes.str(list.reduce(0) { $0 + $1.size })).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ForEach(list) { item in
                Divider().overlay(Theme.faint)
                HStack(spacing: 12) {
                    CheckBox(on: model.selected.contains(item.id))
                    FileIcon(path: item.path, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 13.5)).lineLimit(1)
                        Text(item.detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(Bytes.str(item.size)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Mostrar no Finder")
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(item) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
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
            SubTabs(items: CleanMode.allCases.map { (id: $0.rawValue, title: $0.title) }, selected: store.cleanMode.rawValue) {
                store.cleanMode = CleanMode(rawValue: $0) ?? .system
            }
            switch store.cleanMode {
            case .system:
                CleanView()
            case .projects:
                ScanListView(
                    model: store.purge,
                    icon: "hammer.fill",
                    title: "Projetos",
                    subtitle: "Encontra artefatos de build que podem ser recriados (node_modules, vendor, target, .next, DerivedData…) nas suas pastas de projetos. Os usados nos últimos 7 dias ficam desmarcados.",
                    busy: "Procurando artefatos de build…",
                    empty: "Nenhum artefato encontrado"
                )
            case .installers:
                ScanListView(
                    model: store.installers,
                    icon: "shippingbox.fill",
                    title: "Instaladores",
                    subtitle: "Encontra arquivos .dmg, .pkg, .iso, .xip e .zip de instalação esquecidos em Downloads, Mesa, iCloud, Mail, Telegram e no cache do Homebrew.",
                    busy: "Procurando instaladores…",
                    empty: "Nenhum instalador esquecido"
                )
            case .external:
                ExternalCleanView()
            }
        }
    }
}

struct SubTabs: View {
    let items: [(id: String, title: String)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let active = item.id == selected
                Button { onSelect(item.id) } label: {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(active ? Theme.text : Theme.muted)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(Capsule().fill(active ? Color.white.opacity(0.12) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.2)))
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}
