import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Histórico (`mo history --json`)

struct HistoryJSON: Decodable {
    struct Session: Decodable, Identifiable {
        let command: String?
        let run_id: String?
        let started_at: String?
        let ended_at: String?
        let items: Int?
        let size: String?
        let operation_count: Int?
        let failed_tasks: Int?
        let actions: [String: Int]?
        var id: String { (run_id ?? "") + (started_at ?? "") + (command ?? "") }
    }
    struct Deletion: Decodable, Identifiable {
        let timestamp: String?
        let mode: String?
        let status: String?
        let size_kb: Int64?
        let path: String?
        var id: String { (timestamp ?? "") + (path ?? "") }
    }
    let sessions: [Session]?
    let deletions: [Deletion]?
}

@MainActor
@Observable
final class HistoryModel {
    var sessions: [HistoryJSON.Session] = []
    var deletions: [HistoryJSON.Deletion] = []
    var loading = false
    var error: String?

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await MoleCLI.run(["history", "--json", "--limit", "200"])
            guard let data = result.output.jsonPayload(startingWith: "{") else { throw MoleError.failed("Sem histórico.") }
            let decoded = try JSONDecoder().decode(HistoryJSON.self, from: data)
            sessions = decoded.sessions ?? []
            deletions = decoded.deletions ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runs(_ command: String) -> [HistoryJSON.Session] {
        sessions.filter { ($0.command ?? "").hasPrefix(command) }
    }

    var cleanedBytes: Int64 {
        sessions.filter { ["clean", "purge", "installer"].contains($0.command ?? "") }
            .reduce(0) { $0 + Sizes.parse($1.size ?? "") }
    }
    var uninstallCount: Int { runs("uninstall").reduce(0) { $0 + max($1.items ?? 0, 0) } }
    var optimizeCount: Int { runs("optimize").count }

    static func label(_ command: String?) -> String {
        switch command ?? "" {
        case "clean": return "Limpeza"
        case "uninstall": return "Desinstalação"
        case "optimize": return "Otimização"
        case "purge": return "Projetos"
        case "installer": return "Instaladores"
        case "analyze": return "Analisar"
        case let other: return other.capitalized
        }
    }

    static func date(_ raw: String?) -> String {
        guard let raw else { return "" }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) {
            return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
        }
        return raw.replacingOccurrences(of: "T", with: " ")
    }
}

struct HistorySheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.history

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Histórico").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Abrir logs") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: FS.home + "/Library/Logs/mole"))
                }
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                Button("Fechar") { store.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 12) {
                tile(Bytes.str(model.cleanedBytes), "liberados", "sparkles", Palette.cpu)
                tile("\(model.uninstallCount)", "apps removidos", "trash", Palette.gpu)
                tile("\(model.optimizeCount)", "otimizações", "gauge.with.dots.needle.67percent", Palette.network)
            }
            if let error = model.error {
                Text(error).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Execuções").font(.system(size: 14, weight: .semibold))
                    if model.sessions.isEmpty {
                        Text("Nada registrado ainda.").foregroundStyle(Theme.muted)
                    }
                    ForEach(model.sessions) { s in
                        HStack(spacing: 12) {
                            Text(HistoryModel.label(s.command)).font(.system(size: 13.5, weight: .medium)).frame(width: 120, alignment: .leading)
                            Text(HistoryModel.date(s.started_at)).foregroundStyle(Theme.muted)
                            Spacer()
                            if let items = s.items, items > 0 { Text("\(items) itens").foregroundStyle(Theme.muted) }
                            Text(s.size ?? "").monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .font(.system(size: 13))
                        Divider().overlay(Theme.hairline)
                    }
                    if !model.deletions.isEmpty {
                        Text("Itens removidos recentemente").font(.system(size: 14, weight: .semibold)).padding(.top, 8)
                        ForEach(model.deletions.prefix(100)) { d in
                            HStack(spacing: 12) {
                                Image(systemName: d.mode == "trash" ? "trash" : "xmark.bin")
                                    .foregroundStyle(Theme.muted)
                                    .frame(width: 16)
                                Text(FS.tilde(d.path ?? "")).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Bytes.str((d.size_kb ?? 0) * 1024)).foregroundStyle(Theme.muted)
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: 620)
        .background(Theme.main)
        .task { await model.load() }
    }

    private func tile(_ value: String, _ label: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
    }
}

// MARK: - Ajustes

@MainActor
@Observable
final class SettingsModel {
    static let configDir = FS.home + "/.config/mole"
    static let files: [(key: String, title: String, help: String, path: String)] = [
        ("clean", "Proteções da limpeza", "Caminhos (um por linha, aceita * e ~) que o Limpar nunca apaga.", configDir + "/whitelist"),
        ("purge", "Pastas de projetos", "Onde procurar artefatos de build. Vazio = pastas padrão (~/dev, ~/Projects, ~/GitHub…).", configDir + "/purge_paths")
    ]

    var texts: [String: String] = [:]
    var saved: String?
    var version = ""
    var touchID = false
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var skippedTasks: Set<String> = []
    var confirmRemove = false

    var recordHistory: Bool {
        get { access(keyPath: \.recordHistory); return !UserDefaults.standard.bool(forKey: "noOplog") }
        set { withMutation(keyPath: \.recordHistory) { UserDefaults.standard.set(!newValue, forKey: "noOplog") } }
    }
    var backgroundMonitor: Bool {
        get { access(keyPath: \.backgroundMonitor); return UserDefaults.standard.bool(forKey: "backgroundMonitor") }
        set { withMutation(keyPath: \.backgroundMonitor) { UserDefaults.standard.set(newValue, forKey: "backgroundMonitor") } }
    }
    var cpuAlertsEnabled: Bool {
        get { access(keyPath: \.cpuAlertsEnabled); return UserDefaults.standard.object(forKey: "cpuAlertsEnabled") as? Bool ?? true }
        set { withMutation(keyPath: \.cpuAlertsEnabled) { UserDefaults.standard.set(newValue, forKey: "cpuAlertsEnabled") } }
    }
    var cpuThreshold: Double {
        get { access(keyPath: \.cpuThreshold); let v = UserDefaults.standard.double(forKey: "cpuAlertThreshold"); return v > 0 ? v : 100 }
        set { withMutation(keyPath: \.cpuThreshold) { UserDefaults.standard.set(newValue, forKey: "cpuAlertThreshold") } }
    }
    var cpuMinutes: Int {
        get { access(keyPath: \.cpuMinutes); let v = UserDefaults.standard.integer(forKey: "cpuAlertMinutes"); return v > 0 ? v : 5 }
        set { withMutation(keyPath: \.cpuMinutes) { UserDefaults.standard.set(newValue, forKey: "cpuAlertMinutes") } }
    }

    func toggleTask(_ id: String) {
        let skip = !skippedTasks.contains(id)
        Whitelist.setTask(id, skipped: skip)
        skippedTasks = Whitelist.skippedTasks()
    }

    static let optimizeTasks: [(id: String, title: String, detail: String)] = [
        ("cache_refresh", "Caches do Finder", "Recria miniaturas do QuickLook e o cache de ícones"),
        ("saved_state_cleanup", "Estados salvos de apps", "Remove estados de janelas com mais de 30 dias"),
        ("fix_broken_configs", "Preferências corrompidas", "Repara arquivos .plist quebrados"),
        ("network_optimization", "Cache de DNS", "Limpa o cache de DNS"),
        ("sqlite_vacuum", "Bancos de dados", "Compacta os bancos do Mail, Safari e Mensagens (pula se estiverem abertos)"),
        ("prevent_network_dsstore", "Sem .DS_Store em rede/USB", "Impede o Finder de criar .DS_Store em SMB/AFP/NFS e USB"),
        ("legacy_overrides_audit", "Ajustes antigos ocultos", "Remove overrides de App Nap e verificação de imagens deixados por apps de tweak"),
        ("network_stack_optimize", "Pilha de rede", "Limpa a tabela de rotas e o cache ARP"),
        ("disk_permissions_repair", "Permissões do usuário", "Corrige permissões da sua pasta pessoal"),
        ("spotlight_index_optimize", "Índice do Spotlight", "Recria o índice se a busca estiver lenta"),
        ("spotlight_orphan_rules_cleanup", "Regras órfãs do Spotlight", "Remove regras de apps que já não existem"),
        ("periodic_maintenance", "Manutenção periódica", "Roda os scripts diários/semanais/mensais do macOS se estiverem atrasados"),
        ("shared_file_list_repair", "Favoritos e recentes", "Repara listas de favoritos e documentos recentes do Finder"),
        ("disk_verify", "Saúde do disco", "Verifica a integridade do sistema de arquivos"),
        ("login_items_audit", "Itens de início", "Aponta itens de início quebrados"),
        ("quarantine_cleanup", "Histórico de quarentena", "Limpa o registro de downloads do Gatekeeper"),
        ("launch_agents_cleanup", "Launch Agents", "Aponta agentes cujo programa não existe mais"),
        ("notification_cleanup", "Notificações", "Limpa notificações antigas para reduzir o banco de dados"),
        ("coreduet_cleanup", "Dados de uso", "Limpa dados antigos de rastreamento de uso")
    ]

    func load() async {
        for file in Self.files {
            if let text = try? String(contentsOfFile: file.path, encoding: .utf8) {
                texts[file.key] = text
            } else if file.key == "clean" {
                texts[file.key] = Whitelist.cleanDefaults.joined(separator: "\n") + "\n"
            } else {
                texts[file.key] = ""
            }
        }
        skippedTasks = Whitelist.skippedTasks()
        version = (try? await MoleCLI.run(["--version"]).output)?
            .components(separatedBy: .newlines).first { !$0.isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let status = (try? await MoleCLI.run(["touchid", "status"], mergeStderr: true).output) ?? ""
        if status.contains("Touch ID is enabled") {
            touchID = true
        } else if status.contains("not configured") {
            touchID = false
        } else {
            let pam = (try? String(contentsOfFile: "/etc/pam.d/sudo_local", encoding: .utf8)) ?? ""
            let pam2 = (try? String(contentsOfFile: "/etc/pam.d/sudo", encoding: .utf8)) ?? ""
            touchID = (pam + pam2).contains("pam_tid.so")
        }
    }

    func save(_ key: String) {
        guard let file = Self.files.first(where: { $0.key == key }) else { return }
        try? FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)
        do {
            try (texts[key] ?? "").write(toFile: file.path, atomically: true, encoding: .utf8)
            saved = key
        } catch {
            saved = nil
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Abre o Terminal rodando um comando do Mole que precisa de senha/terminal (ex.: `mo touchid`).
    static func runInTerminal(_ args: String) {
        guard let mo = MoleCLI.locate() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("limpo-\(UUID().uuidString.prefix(6)).command")
        let script = "#!/bin/bash\nclear\n\"\(mo)\" \(args)\necho\nread -n 1 -s -r -p 'Pressione qualquer tecla para fechar…'\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

struct SettingsSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.settings

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Ajustes").font(.system(size: 22, weight: .semibold))
                Text("Limpo \(AppInfo.version) (\(AppInfo.build))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Fechar") { store.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let updates = store.updates
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            row("Atualizações do Limpo", updates.statusText) {
                                if updates.phase == .available {
                                    Button("Atualizar para \(updates.release?.version ?? "")") {
                                        updates.dismissed = nil
                                        Task { await updates.install() }
                                    }
                                } else {
                                    Button("Procurar agora") { Task { await updates.check(manual: true) } }
                                        .disabled(updates.phase == .checking || updates.phase == .installing)
                                }
                            }
                            Divider().overlay(Theme.hairline)
                            row("Procurar automaticamente", "Ao abrir o Limpo e uma vez por dia, na última versão publicada no GitHub") {
                                Toggle("", isOn: Binding(get: { updates.autoCheck }, set: { updates.autoCheck = $0 }))
                                    .toggleStyle(.switch).labelsHidden()
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            row("Mole CLI", model.version.isEmpty ? (MoleCLI.locate() ?? "não encontrado") : model.version) {
                                Menu("Atualizar") {
                                    Button("Atualizar para a versão estável") { SettingsModel.runInTerminal("update") }
                                    Button("Reinstalar a versão estável (--force)") { SettingsModel.runInTerminal("update --force") }
                                    Button("Versão de desenvolvimento (--nightly)") { SettingsModel.runInTerminal("update --nightly") }
                                }
                                .fixedSize()
                            }
                            Divider().overlay(Theme.hairline)
                            row("Touch ID para sudo", model.touchID ? "Ativado — o Mole pede a digital em vez da senha" : "Desativado") {
                                Button(model.touchID ? "Desativar" : "Ativar") { SettingsModel.runInTerminal(model.touchID ? "touchid disable" : "touchid enable") }
                            }
                            Divider().overlay(Theme.hairline)
                            row("Autocompletar no Terminal", "Adiciona o autocompletar dos comandos mo ao seu shell") {
                                Button("Instalar") { SettingsModel.runInTerminal("completion") }
                            }
                            Divider().overlay(Theme.hairline)
                            row("Registrar histórico", "Grava as operações em ~/Library/Logs/mole (desligado = MO_NO_OPLOG)") {
                                Toggle("", isOn: Binding(get: { model.recordHistory }, set: { model.recordHistory = $0 }))
                                    .toggleStyle(.switch).labelsHidden()
                            }
                            Divider().overlay(Theme.hairline)
                            row("Abrir ao iniciar sessão", "Mantém o monitor na barra de menus") {
                                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                            Divider().overlay(Theme.hairline)
                            row("Tarefas com senha de administrador", "Limpeza de sistema e otimizações completas") {
                                HStack {
                                    Button("Limpar no Terminal") { SettingsModel.runInTerminal("clean") }
                                    Button("Otimizar no Terminal") { SettingsModel.runInTerminal("optimize") }
                                }
                            }
                            Divider().overlay(Theme.hairline)
                            row("Remover o Mole", "Desinstala o Mole CLI (mo remove)") {
                                Button("Remover…") { model.confirmRemove = true }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Monitor e alertas").font(.system(size: 14, weight: .semibold))
                            row("Monitorar em segundo plano", "Coleta o status mesmo com o monitor fechado, para os alertas funcionarem") {
                                Toggle("", isOn: Binding(get: { model.backgroundMonitor }, set: {
                                    model.backgroundMonitor = $0
                                    if $0 { store.status.attach() } else { store.status.detach() }
                                }))
                                .toggleStyle(.switch).labelsHidden()
                            }
                            row("Alerta de CPU alta", "Avisa quando um processo passa do limite por tempo contínuo") {
                                Toggle("", isOn: Binding(get: { model.cpuAlertsEnabled }, set: { model.cpuAlertsEnabled = $0; store.status.restart() }))
                                    .toggleStyle(.switch).labelsHidden()
                            }
                            HStack(spacing: 18) {
                                Stepper("Limite: \(Int(model.cpuThreshold))% de CPU", value: Binding(get: { model.cpuThreshold }, set: { model.cpuThreshold = $0; store.status.restart() }), in: 20...800, step: 10)
                                Stepper("Por \(model.cpuMinutes) min", value: Binding(get: { model.cpuMinutes }, set: { model.cpuMinutes = $0; store.status.restart() }), in: 1...60)
                            }
                            .font(.system(size: 12.5))
                            .disabled(!model.cpuAlertsEnabled)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tarefas da otimização").font(.system(size: 14, weight: .semibold))
                            Text("Desmarque o que o Otimizar deve pular (salvo em ~/.config/mole/whitelist_optimize).")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            ForEach(SettingsModel.optimizeTasks, id: \.id) { task in
                                Toggle(isOn: Binding(get: { !model.skippedTasks.contains(task.id) }, set: { _ in model.toggleTask(task.id) })) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(task.title).font(.system(size: 13))
                                        Text(task.detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    ForEach(SettingsModel.files, id: \.key) { file in
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(file.title).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    if model.saved == file.key {
                                        Text("Salvo").font(.caption).foregroundStyle(Palette.cpu)
                                    }
                                    Button("Salvar") { model.save(file.key) }
                                }
                                Text(file.help).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                TextEditor(text: Binding(get: { model.texts[file.key] ?? "" }, set: { model.texts[file.key] = $0; model.saved = nil }))
                                    .font(.system(size: 12, design: .monospaced))
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .frame(height: 110)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
                                Text(FS.tilde(file.path)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
        }
        .alert("Remover o Mole deste Mac?", isPresented: Binding(get: { model.confirmRemove }, set: { model.confirmRemove = $0 })) {
            Button("Cancelar", role: .cancel) {}
            Button("Ver o que será removido") { SettingsModel.runInTerminal("remove --dry-run") }
            Button("Remover", role: .destructive) { SettingsModel.runInTerminal("remove") }
        } message: {
            Text("O Limpo depende do Mole e deixa de funcionar. Os logs em ~/Library/Logs/mole são mantidos.")
        }
        .padding(24)
        .frame(width: 720, height: 680)
        .background(Theme.main)
        .task { await model.load() }
    }

    private func row<Trailing: View>(_ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer()
            trailing()
        }
    }
}
