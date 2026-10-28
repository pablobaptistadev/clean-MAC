import SwiftUI

struct CleanItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let detail: String
    let bytes: Int64
}

struct CleanSection: Identifiable {
    var id: String { name }
    let name: String
    var items: [CleanItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

enum CleanParser {
    /// Lê a saída do `mo clean` / `mo clean --dry-run`:
    ///   ➤ Seção
    ///     → Item · 3 items, 1.2GB dry
    ///     ✓ Item · 640MB
    static func parse(_ raw: String) -> [CleanSection] {
        var sections: [CleanSection] = []
        var seen = Set<String>()
        var current = "Geral"

        for rawLine in ANSI.strip(raw).components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("➤") {
                current = line.dropFirst().trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("→") || line.hasPrefix("✓"), line.contains(" · ") else { continue }

            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            var parts = body.components(separatedBy: " · ")
            let title = parts.removeFirst()
            var detail = parts.joined(separator: " · ")
            if detail.hasSuffix(" dry") { detail = String(detail.dropLast(4)) }

            let key = current + "|" + title
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let item = CleanItem(title: title, detail: detail, bytes: Sizes.parse(detail))
            if let index = sections.lastIndex(where: { $0.name == current }) {
                sections[index].items.append(item)
            } else {
                sections.append(CleanSection(name: current, items: [item]))
            }
        }
        return sections
    }

    /// Seções que o Mole anunciou até agora (para o progresso da análise).
    static func headers(_ raw: String) -> [String] {
        ANSI.strip(raw).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("➤") }
            .map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Categorias da prévia (como no BuhoCleaner)

/// Um caminho da prévia, que pode ser desmarcado ou protegido.
struct CleanEntry: Identifiable, Hashable {
    let path: String
    let bytes: Int64
    let name: String
    var id: String { path }

    init(path: String, bytes: Int64) {
        self.path = path
        self.bytes = bytes
        self.name = CleanEntry.friendlyName(path)
    }

    private static let bases: Set<String> = [
        "Caches", "Application Support", "Logs", "Containers", "Group Containers", "Preferences",
        "Saved Application State", "WebKit", "HTTPStorages", "Cookies"
    ]
    nonisolated(unsafe) private static var appNames: [String: String] = [:]

    /// Nome legível: o app dono do caminho (a pasta logo depois de Caches, Application Support…,
    /// a pasta oculta como ~/.npm ou o .app) e a pasta específica. Hashes, UUIDs e versões não viram nome.
    static func friendlyName(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return path }
        if parts.contains(".Trash") { return last }
        if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let app = (parts[i] as NSString).deletingPathExtension
            return isVersion(last) ? "\(app) — versão \(last)" : app
        }
        var owner: String?
        if let i = parts.lastIndex(where: { bases.contains($0) }), i + 1 < parts.count {
            owner = appName(parts[i + 1])
        } else if let dot = parts.first(where: { $0.hasPrefix(".") && $0.count > 1 }) {
            owner = String(dot.dropFirst())
        }
        let meaningful = parts.last { !isOpaque($0) } ?? last
        guard let owner else { return meaningful }
        let detail = appName(meaningful)
        return detail == owner || meaningful == parts.first(where: { appName($0) == owner }) ? owner : "\(owner) — \(detail)"
    }

    /// Hash, UUID ou número de versão: não serve de nome.
    static func isOpaque(_ s: String) -> Bool {
        if isVersion(s) { return true }
        let hex = s.filter(\.isHexDigit).count
        return s.count >= 12 && hex >= s.count - 4 && s.contains(where: \.isNumber)
    }

    static func isVersion(_ s: String) -> Bool {
        s.range(of: #"^\d+(\.\d+)+([_-][\w.]+)?$"#, options: .regularExpression) != nil
    }

    /// "com.google.Chrome" → "Google Chrome" quando o app está instalado.
    private static func appName(_ s: String) -> String {
        guard s.range(of: #"^[a-z]{2,}\.[\w-]+\.[\w.-]+$"#, options: .regularExpression) != nil else { return s }
        if let cached = appNames[s] { return cached }
        var name = s
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s) {
            name = url.deletingPathExtension().lastPathComponent
        }
        appNames[s] = name
        return name
    }
}

/// Uma categoria da limpeza: uma seção do Mole (ou o Lixo), com os caminhos que ela apaga.
struct CleanCategory: Identifiable {
    let id: String
    let title: String
    let detail: String
    var entries: [CleanEntry]
    /// Linhas do Mole que não vêm com caminhos (ex.: "npm cache · would clean"): limpas com a categoria inteira.
    var actions: [CleanItem]

    var isTrash: Bool { id == CleanCategory.trashID }
    /// Sem caminhos não dá para desmarcar pedaços: o Mole limpa a categoria inteira.
    var isWhole: Bool { entries.isEmpty }
    var bytes: Int64 { isWhole ? actions.reduce(0) { $0 + $1.bytes } : entries.reduce(0) { $0 + $1.bytes } }

    static let trashID = "Trash"

    /// Nome e descrição em português das seções do Mole.
    static let names: [String: (title: String, detail: String)] = [
        trashID: ("Lixo", "Itens que estão no Lixo do Finder. Limpar esvazia o Lixo de vez."),
        "User essentials": ("Caches e logs de apps", "Caches que os apps recriam sozinhos e logs antigos. Sessões e histórico são mantidos."),
        "App caches": ("Caches do sistema", "Ajuda do macOS, Mapas, serviços de mídia da Apple e afins."),
        "Browsers": ("Navegadores", "Caches e versões antigas do Chrome, Edge, Firefox e outros. Senhas, abas e histórico são mantidos."),
        "Cloud & Office": ("Nuvem e Office", "Caches do iCloud, Dropbox, OneDrive e Office."),
        "Developer tools": ("Ferramentas de desenvolvimento", "Caches do Xcode, npm, Bun, pip, Homebrew e editores. A próxima compilação pode demorar mais."),
        "Apps & utilities": ("Apps e utilitários", "Caches e logs de apps instalados."),
        "Virtualization": ("Virtualização", "Caches de Docker, Parallels e máquinas virtuais."),
        "Application Support": ("Dados de suporte de apps", "Logs e caches guardados em Application Support."),
        "App leftovers": ("Restos de apps removidos", "Arquivos de apps que já não estão instalados."),
        "Apple Silicon updates": ("Atualizações antigas", "Instaladores de atualizações do macOS que já foram aplicadas."),
        "Device backups & firmware": ("Backups e firmware de dispositivos", "Firmware de iPhone e iPad já baixado e backups antigos."),
        "Time Machine": ("Time Machine", "Snapshots locais e restos de backups."),
        "Large files": ("Arquivos grandes", "Arquivos grandes que o Mole encontrou."),
        "Project artifacts": ("Artefatos de projetos", "Pastas de build recriáveis dos seus projetos.")
    ]

    /// "Recomendados" deixa de fora o que dá trabalho recuperar: o Lixo e os caches de desenvolvimento.
    var recommended: Bool { !isTrash && id != "Developer tools" }

    /// Junta a saída da prévia com a lista de caminhos (`clean-list.txt`). O Lixo vira a primeira categoria.
    static func build(output: String, paths: [String: [CleanPath]]) -> [CleanCategory] {
        let trashPrefix = FS.home + "/.Trash/"
        var trash: [CleanEntry] = []
        var result: [CleanCategory] = []
        for section in CleanParser.parse(output) {
            var entries: [CleanEntry] = []
            for p in paths[section.name] ?? [] {
                let entry = CleanEntry(path: p.path, bytes: Sizes.parse(p.note))
                if p.path.hasPrefix(trashPrefix) { trash.append(entry) } else { entries.append(entry) }
            }
            let actions = section.items.filter { !$0.title.hasPrefix("Trash") }
            guard !entries.isEmpty || actions.contains(where: { $0.bytes > 0 }) else { continue }
            let name = names[section.name] ?? (section.name, "")
            result.append(CleanCategory(id: section.name, title: name.title, detail: name.detail,
                                        entries: entries.sorted { $0.bytes > $1.bytes }, actions: actions))
        }
        if !trash.isEmpty {
            let name = names[trashID]!
            result.insert(CleanCategory(id: trashID, title: name.title, detail: name.detail,
                                        entries: trash.sorted { $0.bytes > $1.bytes }, actions: []), at: 0)
        }
        return result
    }
}

@MainActor
@Observable
final class CleanModel {
    enum Phase { case idle, scanning, preview, cleaning, done }

    var phase: Phase = .idle
    var categories: [CleanCategory] = []
    /// Caminhos desmarcados (ficam protegidos só durante esta limpeza).
    var deselected: Set<String> = []
    /// Categorias inteiras desmarcadas (as que não têm caminhos).
    var deselectedWhole: Set<String> = []
    var expanded: Set<String> = []
    /// Quantos caminhos cada categoria aberta mostra (categorias com milhares de itens abrem aos poucos).
    var rowLimit: [String: Int] = [:]
    var protected: Set<String> = []
    /// O Mole não conseguiu ler o Lixo: falta Acesso Total ao Disco para o Limpo.
    var trashBlocked = false
    var freed: Int64 = 0
    var log = ""
    var showLog = false
    var error: String?

    // Progresso da análise
    var scanOutput = ""
    var scanSection = ""
    var scanBytes: Int64 = 0
    var scanFraction = 0.0

    private static let expectedSections = 15

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Seleção

    func isSelected(_ entry: CleanEntry) -> Bool {
        !deselected.contains(entry.path) && !protected.contains(entry.path)
    }

    func state(of c: CleanCategory) -> TriCheckBox.State {
        if c.isWhole { return deselectedWhole.contains(c.id) ? .off : .on }
        let n = selectedCount(c)
        return n == 0 ? .off : n == c.entries.count ? .on : .mixed
    }

    func selectedCount(_ c: CleanCategory) -> Int {
        c.isWhole ? (deselectedWhole.contains(c.id) ? 0 : 1) : c.entries.filter(isSelected).count
    }

    func selectedBytes(_ c: CleanCategory) -> Int64 {
        if c.isWhole { return deselectedWhole.contains(c.id) ? 0 : c.bytes }
        return c.entries.filter(isSelected).reduce(0) { $0 + $1.bytes }
    }

    func toggle(_ c: CleanCategory) {
        if c.isWhole {
            if deselectedWhole.contains(c.id) { deselectedWhole.remove(c.id) } else { deselectedWhole.insert(c.id) }
            return
        }
        let paths = c.entries.map(\.path)
        if state(of: c) == .on { deselected.formUnion(paths) } else { deselected.subtract(paths) }
    }

    func toggle(_ entry: CleanEntry) {
        guard !protected.contains(entry.path) else { return }
        if deselected.contains(entry.path) { deselected.remove(entry.path) } else { deselected.insert(entry.path) }
    }

    func selectAll() { deselected = []; deselectedWhole = [] }
    func selectNone() {
        deselected = Set(categories.flatMap { $0.entries.map(\.path) })
        deselectedWhole = Set(categories.filter(\.isWhole).map(\.id))
    }
    func selectRecommended() {
        selectAll()
        for c in categories where !c.recommended {
            deselected.formUnion(c.entries.map(\.path))
            if c.isWhole { deselectedWhole.insert(c.id) }
        }
    }

    func toggleProtect(_ path: String) {
        if protected.contains(path) {
            Whitelist.unprotect(path)
            protected.remove(path)
        } else {
            Whitelist.protect(path)
            protected.insert(path)
        }
    }

    var total: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    var selectedTotal: Int64 { categories.reduce(0) { $0 + selectedBytes($1) } }
    var itemCount: Int { categories.reduce(0) { $0 + max($1.entries.count, $1.isWhole ? 1 : 0) } }
    var selectedItems: Int { categories.reduce(0) { $0 + selectedCount($1) } }

    // MARK: Análise e limpeza

    func scan() async {
        phase = .scanning
        error = nil
        scanOutput = ""
        scanSection = ""
        scanBytes = 0
        scanFraction = 0
        do {
            _ = try await MoleCLI.stream(["clean", "--dry-run"]) { [weak self] text in
                Task { @MainActor in self?.progress(text) }
            }
            // Os últimos pedaços da saída chegam pelo main actor depois do fim do processo.
            try? await Task.sleep(for: .milliseconds(150))
            trashBlocked = scanOutput.contains("Trash · skipped")
            categories = CleanCategory.build(output: scanOutput, paths: CleanListFile.read())
            protected = Set(categories.flatMap { $0.entries.map(\.path) }.filter(Whitelist.isProtected))
            deselected = []
            deselectedWhole = []
            expanded = []
            rowLimit = [:]
            phase = .preview
        } catch {
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    private func progress(_ text: String) {
        scanOutput += text
        let headers = CleanParser.headers(scanOutput)
        if let last = headers.last {
            scanSection = CleanCategory.names[last]?.title ?? last
        }
        scanFraction = min(Double(headers.count) / Double(Self.expectedSections), 0.99)
        scanBytes = CleanParser.parse(scanOutput).reduce(0) { $0 + $1.bytes }
    }

    /// Bytes da análise por grupo, para os três contadores da tela de progresso.
    func scanStat(_ sections: [String]) -> Int64 {
        CleanParser.parse(scanOutput).filter { sections.contains($0.name) }.reduce(0) { $0 + $1.bytes }
    }

    func clean() async {
        phase = .cleaning
        // O que o usuário desmarcou fica protegido só durante esta limpeza.
        var skip = Array(deselected)
        if deselectedWhole.contains(CleanCategory.trashID) { skip.append(FS.home + "/.Trash") }
        Whitelist.protectTemporarily(skip)
        defer { Whitelist.removeTemporary() }
        do {
            let result = try await MoleCLI.run(["clean"], mergeStderr: true)
            log = ANSI.strip(result.output)
            freed = CleanParser.parse(result.output).reduce(0) { $0 + $1.bytes }
            phase = .done
        } catch {
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    func reset() {
        phase = .idle
        categories = []
        log = ""
        error = nil
    }

    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Telas

struct CleanView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.clean

        switch model.phase {
        case .idle:
            HeroView(
                icon: "bolt",
                title: "Limpeza rápida",
                subtitle: "Encontra e limpa caches, logs, arquivos temporários, o Lixo e restos de apps já desinstalados. Você revisa tudo antes.",
                button: "Analisar",
                error: model.error
            ) {
                Task { await model.scan() }
            }

        case .scanning:
            ScanProgressView(model: model)

        case .cleaning:
            BusyView(title: "Limpando…", subtitle: "Não feche o app.")

        case .preview:
            CleanResultsView(model: model)

        case .done:
            VStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.accent, lineWidth: 9).frame(width: 132, height: 132)
                    Image(systemName: "checkmark").font(.system(size: 46, weight: .semibold))
                }
                .padding(.bottom, 8)
                Text("Limpeza concluída")
                    .font(.system(size: 30, weight: .regular))
                Text("\(Bytes.str(model.freed)) liberados")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                Button(model.showLog ? "Ocultar detalhes" : "Ver detalhes") { model.showLog.toggle() }
                    .buttonStyle(LinkButtonStyle())
                    .font(.system(size: 13))
                if model.showLog {
                    ScrollView {
                        Text(model.log)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(maxWidth: 680, maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar.opacity(0.5)))
                }
                Button("Analisar novamente") {
                    Task { await model.scan() }
                }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Progresso da análise: anel com porcentagem, total encontrado até agora, grupo atual e três contadores.
private struct ScanProgressView: View {
    let model: CleanModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressRing(fraction: model.scanFraction)
            HStack(spacing: 6) {
                Text("Analisando lixo")
                Text(Bytes.str(model.scanBytes)).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 22))
            Text(model.scanSection.isEmpty ? "Preparando…" : model.scanSection)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 56) {
                stat("internaldrive", "Sistema", ["App caches", "Application Support", "Apple Silicon updates", "Time Machine"])
                stat("person", "Usuário", ["User essentials", "Apps & utilities", "App leftovers", "Developer tools"])
                stat("globe", "Navegadores", ["Browsers"])
            }
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ symbol: String, _ title: String, _ sections: [String]) -> some View {
        let bytes = model.scanStat(sections)
        return VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.muted)
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            Text(bytes > 0 ? Bytes.str(bytes) : "…").font(.system(size: 11.5, weight: .semibold))
        }
        .frame(width: 110)
    }
}

/// "Pronto para limpar": categorias com caixa de marcar, caminhos com proteger e mostrar no Finder.
private struct CleanResultsView: View {
    @Environment(AppStore.self) private var store
    let model: CleanModel

    var body: some View {
        VStack(spacing: 0) {
            ResultHeader(
                title: "Pronto para limpar",
                subtitle: "\(Bytes.str(model.total)) disponíveis para limpeza · \(model.itemCount) itens · \(model.categories.count) categorias",
                onRefresh: { Task { await model.scan() } },
                onClose: { model.reset() }
            )
            if model.categories.isEmpty && !model.trashBlocked {
                EmptyResult(title: "Nada para limpar", subtitle: "Seu Mac já está em dia.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if model.trashBlocked { trashBlockedCard }
                        ForEach(model.categories) { category in
                            CategoryCard(category: category, model: model)
                        }
                        Text("Caches de sistema que exigem senha de administrador ficam para a limpeza no Terminal (Ajustes).")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
            }
            footer
        }
    }

    private var trashBlockedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lixo").font(.system(size: 13, weight: .semibold))
                Text("O macOS não deixa o Limpo ver o Lixo. Dê Acesso Total ao Disco ao Limpo e analise de novo para ver e esvaziar o Lixo aqui.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Abrir Ajustes") { CleanModel.openFullDiskAccess() }
                .buttonStyle(LinkButtonStyle())
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
    }

    private var footer: some View {
        ActionBar(button: "Limpar · \(Bytes.str(model.selectedTotal))", enabled: model.selectedTotal > 0, action: {
            Task { await model.clean() }
        }) {
            Text("\(model.selectedItems) selecionados").font(.system(size: 12, weight: .medium))
            Button("Todos") { model.selectAll() }.buttonStyle(LinkButtonStyle())
            Text("·").foregroundStyle(Theme.muted)
            Button("Nenhum") { model.selectNone() }.buttonStyle(LinkButtonStyle())
            Text("·").foregroundStyle(Theme.muted)
            Button("Recomendados") { model.selectRecommended() }.buttonStyle(LinkButtonStyle())
        }
    }
}

private struct CategoryCard: View {
    let category: CleanCategory
    let model: CleanModel

    var body: some View {
        let c = category
        let open = model.expanded.contains(c.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.toggle(c) } label: { TriCheckBox(state: model.state(of: c)) }
                    .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if c.isTrash { Image(systemName: "trash").font(.system(size: 11.5)) }
                        Text(c.title).font(.system(size: 13, weight: .semibold))
                        Text(c.isWhole ? "categoria inteira" : "\(model.selectedCount(c))/\(c.entries.count) selecionados")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                    Text(c.detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Spacer()
                Text("\(Bytes.str(model.selectedBytes(c))) / \(Bytes.str(c.bytes))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentLight)
                    .monospacedDigit()
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 18)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(c.id) } }

            if open {
                let limit = model.rowLimit[c.id] ?? 200
                VStack(spacing: 0) {
                    ForEach(c.entries.prefix(limit)) { entry in
                        EntryRow(entry: entry, model: model)
                    }
                    if c.entries.count > limit {
                        Button("Mostrar mais \(min(500, c.entries.count - limit)) de \(c.entries.count - limit) restantes") {
                            model.rowLimit[c.id] = limit + 500
                        }
                        .buttonStyle(LinkButtonStyle())
                        .font(.system(size: 11.5))
                        .frame(height: 30)
                    }
                    ForEach(c.actions.filter { c.isWhole || $0.bytes == 0 }) { action in
                        HStack(spacing: 10) {
                            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 15)
                            Text(action.title).font(.system(size: 12))
                            Spacer()
                            Text(action.detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        .padding(.leading, 42)
                        .padding(.trailing, 16)
                        .frame(height: 30)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
    }
}

private struct EntryRow: View {
    let entry: CleanEntry
    let model: CleanModel

    var body: some View {
        let isProtected = model.protected.contains(entry.path)
        HStack(spacing: 12) {
            Button { model.toggle(entry) } label: {
                TriCheckBox(state: model.isSelected(entry) ? .on : .off, disabled: isProtected)
            }
            .buttonStyle(.plain)
            .disabled(isProtected)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.system(size: 12)).lineLimit(1)
                    if isProtected {
                        Text("Protegido").font(.system(size: 10.5)).foregroundStyle(Theme.warning)
                    }
                }
                Text(FS.tilde(entry.path))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(Bytes.str(entry.bytes)).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
            Button { model.toggleProtect(entry.path) } label: {
                Image(systemName: isProtected ? "shield.fill" : "shield")
            }
            .help(isProtected ? "Deixar de proteger" : "Proteger: o Limpo nunca mais apaga isto")
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: {
                Image(systemName: "folder")
            }
            .help("Mostrar no Finder")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
        .opacity(isProtected ? 0.6 : 1)
        .padding(.leading, 42)
        .padding(.trailing, 16)
        .frame(height: 36)
    }
}
