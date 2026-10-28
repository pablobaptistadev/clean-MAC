import SwiftUI

struct InstalledApp: Decodable, Identifiable, Hashable {
    let name: String
    let bundle_id: String
    let source: String
    let uninstall_name: String
    let path: String
    let size: String

    var id: String { path }
    var bytes: Int64 { Sizes.parse(size) }
}

@MainActor
@Observable
final class UninstallModel {
    enum Phase { case idle, loading, list }

    enum Filter: String, CaseIterable { case all, selected, large, homebrew }
    enum Sort { case size, name }

    var phase: Phase = .idle
    var apps: [InstalledApp] = []
    var selected: Set<String> = []
    var query = ""
    var filter: Filter = .all
    var sort: Sort = .size
    var expanded: Set<String> = []
    var error: String?

    // Folha de confirmação / execução
    var sheetOpen = false
    var planLoading = false
    var plan = ""
    var running = false
    var finished = false
    var exitCode: Int32 = 0
    var needsPassword = false
    var passwordInput = ""
    var withData = false
    var permanent = false

    var flags: [String] { (withData ? ["--with-data"] : []) + (permanent ? ["--permanent"] : []) }

    private var rawLog = ""
    private var session: PTYSession?
    private var confirmed = false
    private var passwordsSent = 0

    var log: String { ANSI.strip(rawLog) }

    var filtered: [InstalledApp] {
        let list = apps(in: filter).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundle_id.localizedCaseInsensitiveContains(query)
        }
        switch sort {
        case .size: return list.sorted { $0.bytes > $1.bytes }
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func apps(in filter: Filter) -> [InstalledApp] {
        switch filter {
        case .all: return apps
        case .selected: return apps.filter { selected.contains($0.id) }
        case .large: return apps.filter { $0.bytes >= 1_000_000_000 }
        case .homebrew: return apps.filter { $0.source == "Homebrew" }
        }
    }

    func toggleExpanded(_ app: InstalledApp) {
        if expanded.contains(app.id) { expanded.remove(app.id) } else { expanded.insert(app.id) }
    }
    var selectedApps: [InstalledApp] { apps.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedApps.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { apps.reduce(0) { $0 + $1.bytes } }

    func load() async {
        phase = .loading
        error = nil
        do {
            let result = try await MoleCLI.run(["uninstall", "--list"])
            guard let data = result.output.jsonPayload(startingWith: "[") else {
                throw MoleError.failed("O mo uninstall --list não devolveu JSON.")
            }
            apps = try JSONDecoder().decode([InstalledApp].self, from: data)
                .sorted { $0.bytes > $1.bytes }
            selected = selected.intersection(apps.map(\.id))
        } catch {
            self.error = error.localizedDescription
        }
        phase = .list
    }

    func toggle(_ app: InstalledApp) {
        if selected.contains(app.id) { selected.remove(app.id) } else { selected.insert(app.id) }
    }

    /// Mostra o plano (dry-run) antes de qualquer remoção.
    func openPreview() async {
        sheetOpen = true
        running = false
        finished = false
        needsPassword = false
        rawLog = ""
        plan = ""
        planLoading = true
        do {
            let result = try await MoleCLI.run(["uninstall", "--dry-run"] + flags + selectedApps.map(\.uninstall_name), mergeStderr: true)
            plan = ANSI.strip(result.output).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            plan = error.localizedDescription
        }
        planLoading = false
    }

    /// O usuário já revisou o plano na interface; aqui o Mole roda num terminal virtual
    /// e o app responde à confirmação dele.
    func confirm() {
        guard let mo = MoleCLI.locate() else { return }
        running = true
        confirmed = false
        passwordsSent = 0
        rawLog = ""

        let session = PTYSession()
        session.onText = { [weak self] text in
            Task { @MainActor in self?.handle(text) }
        }
        session.onExit = { [weak self] code in
            Task { @MainActor in self?.didExit(code) }
        }
        self.session = session
        do {
            try session.start(mo: mo, args: ["uninstall"] + flags + selectedApps.map(\.uninstall_name))
        } catch {
            rawLog = error.localizedDescription
            running = false
            finished = true
        }
    }

    func sendPassword(_ password: String) {
        passwordsSent += 1
        needsPassword = false
        session?.send(password + "\r")
    }

    func close() {
        if running { session?.terminate() }
        sheetOpen = false
    }

    private func handle(_ chunk: String) {
        rawLog += chunk
        let text = log
        let tail = String(text.suffix(400))

        if !confirmed, tail.contains("confirm"), tail.contains("cancel") {
            confirmed = true
            answerConfirmation(attempt: 1)
        }

        let prompts = text.components(separatedBy: "Password:").count - 1
        if prompts > passwordsSent { needsPassword = true }
    }

    /// O Mole joga fora o que chega logo depois de mostrar "Enter confirm, ESC cancel" (drain_pending_input),
    /// então responder na hora fazia a desinstalação travar. O Enter vai com atraso e é repetido
    /// enquanto a pergunta continuar sendo a última linha.
    private func answerConfirmation(attempt: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(attempt == 1 ? 800 : 2500))
            guard let self, self.running, self.waitingForConfirmation else { return }
            self.session?.send("\r")
            if attempt < 4 { self.answerConfirmation(attempt: attempt + 1) }
        }
    }

    private var waitingForConfirmation: Bool {
        let last = log.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return last.contains("confirm") && last.contains("cancel")
    }

    private func didExit(_ code: Int32) {
        running = false
        finished = true
        needsPassword = false
        exitCode = code
        session = nil
        selected.removeAll()
        Task { await load() }
    }
}

struct UninstallView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.uninstall

        VStack(spacing: 0) {
            titleBar(model)
            switch model.phase {
            case .idle, .loading:
                BusyView(title: "Listando aplicativos…", subtitle: "Calculando tamanhos.")
            case .list:
                HStack(spacing: 0) {
                    filters(model)
                    VStack(spacing: 0) {
                        listHeader(model)
                        if let error = model.error {
                            Text(error).foregroundStyle(Theme.danger).padding()
                        }
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.filtered) { app in
                                    AppRow(app: app, model: model)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                    }
                }
                BottomBar(
                    selected: model.selectedBytes,
                    total: model.totalBytes,
                    selectedLabel: "Selecionado",
                    button: "Remover",
                    enabled: !model.selected.isEmpty
                ) {
                    Task { await model.openPreview() }
                }
            }
        }
        .task {
            if model.phase == .idle { await model.load() }
        }
        .sheet(isPresented: Binding(get: { model.sheetOpen }, set: { model.sheetOpen = $0 })) {
            UninstallSheet(model: model)
        }
    }

    /// Barra de título como a do BuhoCleaner: nome da tela no centro e busca à direita.
    private func titleBar(_ model: UninstallModel) -> some View {
        ZStack {
            Text("Desinstalar apps").font(.system(size: 13, weight: .medium))
            HStack(spacing: 10) {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Buscar app", text: Binding(get: { model.query }, set: { model.query = $0 }))
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Theme.sidebar.opacity(0.35)))
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .help("Atualizar lista")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .frame(height: 48)
    }

    private func filters(_ model: UninstallModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            filterRow(model, .all, "square.grid.2x2", "Todos os apps")
            filterRow(model, .selected, "checkmark.circle", "Selecionados")
            filterRow(model, .large, "externaldrive", "Grandes (1 GB ou mais)")
            filterRow(model, .homebrew, "mug", "Homebrew")
            Text("Opções")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
                .padding(.top, 22)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            optionRow("Incluir dados pessoais do app", on: model.withData, help: "Equivale a --with-data: também remove documentos e dados que o app guardou") {
                model.withData.toggle()
            }
            optionRow("Apagar sem passar pelo Lixo", on: model.permanent, help: "Equivale a --permanent: não dá para desfazer") {
                model.permanent.toggle()
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .frame(width: 250)
    }

    private func filterRow(_ model: UninstallModel, _ filter: UninstallModel.Filter, _ symbol: String, _ title: String) -> some View {
        let active = model.filter == filter
        return Button { model.filter = filter } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 12.5))
                Spacer()
                Text("\(model.apps(in: filter).count)").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func optionRow(_ title: String, on: Bool, help: String, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                CheckBox(on: on)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func listHeader(_ model: UninstallModel) -> some View {
        let titles: [UninstallModel.Filter: String] = [.all: "Todos os apps", .selected: "Selecionados", .large: "Apps grandes", .homebrew: "Instalados pelo Homebrew"]
        return VStack(alignment: .leading, spacing: 3) {
            Text(titles[model.filter] ?? "").font(.system(size: 15, weight: .semibold))
            HStack {
                Text("Apps instalados no seu Mac. Você revisa tudo antes de remover.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Menu(model.sort == .size ? "Ordenar por tamanho" : "Ordenar por nome") {
                    Button("Tamanho") { model.sort = .size }
                    Button("Nome") { model.sort = .name }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let model: UninstallModel

    var body: some View {
        let selected = model.selected.contains(app.id)
        let open = model.expanded.contains(app.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.toggle(app) } label: { CheckBox(on: selected) }
                    .buttonStyle(.plain)
                FileIcon(path: app.path, size: 26)
                Text(app.name).font(.system(size: 13))
                if app.source == "Homebrew" {
                    Text("Homebrew")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(Theme.muted)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                Spacer()
                Text(Bytes.str(app.bytes)).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9))
                Button { withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(app) } } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
            .onTapGesture { model.toggle(app) }

            if open {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Caminho", FS.tilde(app.path))
                    if !app.bundle_id.isEmpty { detail("Identificador", app.bundle_id) }
                    detail("Origem", app.source)
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                        .buttonStyle(LinkButtonStyle())
                        .font(.system(size: 11.5))
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 78)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.selection : .clear))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Theme.muted).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11.5))
    }
}

private struct UninstallSheet: View {
    let model: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 20, weight: .semibold))

            ScrollViewReader { proxy in
                ScrollView {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
                .onChange(of: content) { proxy.scrollTo("end") }
            }

            if model.planLoading || (model.running && !model.needsPassword) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.planLoading ? "Montando o plano…" : "Desinstalando…")
                        .foregroundStyle(Theme.muted)
                }
            }

            if model.needsPassword {
                HStack {
                    SecureField("Senha de administrador do Mac", text: Binding(get: { model.passwordInput }, set: { model.passwordInput = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Enviar", action: send)
                }
            }

            HStack {
                Spacer()
                if model.finished {
                    Button("Fechar") { model.close() }
                        .keyboardShortcut(.defaultAction)
                } else if model.running {
                    Button("Cancelar") { model.close() }
                } else {
                    Button("Cancelar") { model.close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Desinstalar") { model.confirm() }
                        .tint(Theme.danger)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.planLoading)
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: 520)
    }

    private var title: String {
        if model.finished { return model.exitCode == 0 ? "Desinstalação concluída" : "Desinstalação terminou com avisos" }
        if model.running { return "Desinstalando…" }
        return "Revise antes de desinstalar"
    }

    private var content: String {
        model.running || model.finished ? model.log : model.plan
    }

    private func send() {
        guard !model.passwordInput.isEmpty else { return }
        model.sendPassword(model.passwordInput)
        model.passwordInput = ""
    }
}
