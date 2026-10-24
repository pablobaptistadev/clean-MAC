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

    var phase: Phase = .idle
    var apps: [InstalledApp] = []
    var selected: Set<String> = []
    var query = ""
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
        query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundle_id.localizedCaseInsensitiveContains(query)
        }
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
            session?.send("y")
        }

        let prompts = text.components(separatedBy: "Password:").count - 1
        if prompts > passwordsSent { needsPassword = true }
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
            switch model.phase {
            case .idle, .loading:
                BusyView(title: "Listando aplicativos…", subtitle: "Calculando tamanhos.")
            case .list:
                header(model)
                if let error = model.error {
                    Text(error).foregroundStyle(Theme.danger).padding()
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.filtered) { app in
                            AppRow(app: app, selected: model.selected.contains(app.id)) {
                                model.toggle(app)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                BottomBar(
                    selected: model.selectedBytes,
                    total: model.totalBytes,
                    selectedLabel: "Selecionado",
                    button: "Desinstalar",
                    enabled: !model.selected.isEmpty,
                    destructive: true
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

    private func header(_ model: UninstallModel) -> some View {
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Desinstalar Apps").font(.system(size: 26, weight: .semibold))
                Text("Remove o app junto com preferências, caches e restos. Você revisa tudo antes.")
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Incluir dados pessoais do app", isOn: Binding(get: { model.withData }, set: { model.withData = $0 }))
                    .help("Equivale a --with-data: também remove documentos e dados que o app guardou")
                Toggle("Apagar sem passar pelo Lixo", isOn: Binding(get: { model.permanent }, set: { model.permanent = $0 }))
                    .help("Equivale a --permanent: não dá para desfazer")
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Buscar app", text: Binding(get: { model.query }, set: { model.query = $0 }))
                    .textFieldStyle(.plain)
                    .frame(width: 200)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(Color.black.opacity(0.2)))
            Button {
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Atualizar lista")
        }
        .padding(.horizontal, 30)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CheckBox(on: selected)
            FileIcon(path: app.path, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 15))
                Text(app.bundle_id.isEmpty ? app.path : app.bundle_id)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            if app.source == "Homebrew" {
                Text("Homebrew")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(Theme.muted)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Spacer()
            Text(app.size).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
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
