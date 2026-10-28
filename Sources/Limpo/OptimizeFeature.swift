import SwiftUI

@MainActor
@Observable
final class OptimizeModel {
    enum Phase { case idle, scanning, preview, running, done }

    var phase: Phase = .idle
    var sections: [OutputSection] = []
    var summary: [String] = []
    var raw = ""
    var showLog = false
    var error: String?
    /// Tarefas que o usuário desmarcou (as mesmas de Ajustes › Tarefas da otimização).
    var skipped: Set<String> = Whitelist.skippedTasks()

    var actionable: Int { SettingsModel.optimizeTasks.filter { !skipped.contains($0.id) }.count }

    /// Título de cada seção do `mo optimize` → id da tarefa no `whitelist_optimize`.
    static let moleTitles: [String: String] = [
        "Finder Cache Refresh": "cache_refresh", "App State Cleanup": "saved_state_cleanup",
        "Broken Config Repair": "fix_broken_configs", "Network Cache Refresh": "network_optimization",
        "Database Optimization": "sqlite_vacuum", "Prevent Finder .DS_Store": "prevent_network_dsstore",
        "Legacy Overrides": "legacy_overrides_audit", "Network Stack Refresh": "network_stack_optimize",
        "Permission Repair": "disk_permissions_repair", "Spotlight Optimization": "spotlight_index_optimize",
        "Spotlight Orphan Rules": "spotlight_orphan_rules_cleanup", "Periodic Maintenance": "periodic_maintenance",
        "Shared File Lists": "shared_file_list_repair", "Disk Health": "disk_verify", "Login Items": "login_items_audit",
        "Quarantine Database Cleanup": "quarantine_cleanup", "Launch Agents Cleanup": "launch_agents_cleanup",
        "Notifications": "notification_cleanup", "Usage Data": "coreduet_cleanup"
    ]

    /// O que o Mole disse sobre cada tarefa (prévia, andamento ou resultado).
    func result(for id: String) -> OutputLine? {
        sections.first { Self.moleTitles[$0.title] == id }?.lines.first
    }

    func toggle(_ id: String) {
        let skip = !skipped.contains(id)
        Whitelist.setTask(id, skipped: skip)
        skipped = Whitelist.skippedTasks()
    }

    func setAll(_ on: Bool) {
        for task in SettingsModel.optimizeTasks { Whitelist.setTask(task.id, skipped: !on) }
        skipped = Whitelist.skippedTasks()
    }

    func preview() async {
        phase = .scanning
        error = nil
        skipped = Whitelist.skippedTasks()
        do {
            let result = try await MoleCLI.run(["optimize", "--dry-run"], mergeStderr: true)
            apply(result.output)
            phase = .preview
        } catch {
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    func run() async {
        phase = .running
        raw = ""
        sections = []
        summary = []
        do {
            _ = try await MoleCLI.stream(["optimize"]) { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.raw += text
                    self.apply(self.raw)
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
            apply(raw)
            phase = .done
        } catch {
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    private func apply(_ text: String) {
        raw = text
        let parsed = OutputParser.parse(text)
        sections = parsed.sections
        summary = parsed.summary
    }

    func reset() {
        phase = .idle
        sections = []
        summary = []
        raw = ""
    }
}

struct OptimizeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.optimize

        switch model.phase {
        case .idle:
            HeroView(
                icon: "gauge.with.dots.needle.bottom.50percent",
                title: "Otimizar",
                subtitle: "Atualiza caches do Finder e do QuickLook, limpa DNS, verifica o Spotlight, compacta bancos de dados de apps e corrige configurações quebradas. Você vê o plano antes.",
                button: "Analisar",
                error: model.error
            ) {
                Task { await model.preview() }
            }

        case .scanning:
            BusyView(title: "Diagnosticando o sistema…")

        case .preview, .running, .done:
            VStack(spacing: 0) {
                ResultHeader(
                    title: model.phase == .done ? "Otimização concluída" : model.phase == .running ? "Otimizando…" : "Pronto para otimizar",
                    subtitle: "\(model.actionable) de \(SettingsModel.optimizeTasks.count) tarefas selecionadas · caches, rede, Spotlight, bancos de dados e configurações",
                    onRefresh: model.phase == .running ? nil : { Task { await model.preview() } },
                    onClose: { model.reset() }
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.sections.isEmpty, model.phase == .running {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Iniciando…").foregroundStyle(Theme.muted)
                            }
                        }
                        TaskListCard(model: model)
                        if !model.summary.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.summary, id: \.self) { Text($0) }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 4)
                        }
                        if model.phase == .done {
                            Button(model.showLog ? "Ocultar saída completa" : "Ver saída completa") { model.showLog.toggle() }
                                .buttonStyle(LinkButtonStyle())
                                .font(.system(size: 12))
                            if model.showLog {
                                Text(ANSI.strip(model.raw))
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                            }
                        }
                        Text("Tarefas que exigem senha de administrador são puladas quando o Mole roda pelo app. Para incluí-las, use Ajustes › Otimizar no Terminal.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
                bottom(model)
            }
        }
    }

    @ViewBuilder
    private func bottom(_ model: OptimizeModel) -> some View {
        switch model.phase {
        case .preview:
            ActionBar(button: "Otimizar · \(model.actionable) tarefas", enabled: model.actionable > 0, action: { Task { await model.run() } }) {
                Text("\(model.actionable) selecionadas").font(.system(size: 12, weight: .medium))
                Button("Todas") { model.setAll(true) }.buttonStyle(LinkButtonStyle())
                Text("·").foregroundStyle(Theme.muted)
                Button("Nenhuma") { model.setAll(false) }.buttonStyle(LinkButtonStyle())
            }
        case .running:
            ActionBar(button: "Otimizando…", enabled: false, action: {}) {
                ProgressView().controlSize(.small)
                Text("Otimizando…").foregroundStyle(Theme.muted)
            }
        default:
            ActionBar(button: "Analisar novamente", action: { Task { await model.preview() } }) {
                Text("\(model.actionable) tarefa(s) executada(s)").font(.system(size: 12, weight: .medium))
            }
        }
    }
}

/// Todas as tarefas num cartão: caixa de marcar, nome e explicação em português e o que o Mole respondeu.
private struct TaskListCard: View {
    let model: OptimizeModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(SettingsModel.optimizeTasks.enumerated()), id: \.element.id) { index, task in
                let on = !model.skipped.contains(task.id)
                let result = model.result(for: task.id)
                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 43) }
                HStack(spacing: 12) {
                    Button { model.toggle(task.id) } label: { CheckBox(on: on) }
                        .buttonStyle(.plain)
                        .disabled(model.phase == .running)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).font(.system(size: 13))
                        Text(task.detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 16)
                    if let result, on {
                        Image(systemName: OutputSectionCard.symbol(result.kind))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(OutputSectionCard.color(result.kind))
                        Text(result.text)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .frame(maxWidth: 320, alignment: .trailing)
                    } else if !on {
                        Text("Pulada").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .opacity(on ? 1 : 0.55)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
    }
}

struct OutputSectionCard: View {
    let section: OutputSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            ForEach(section.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: Self.symbol(line.kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Self.color(line.kind))
                        .frame(width: 15)
                    Text(line.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(line.kind == .skipped ? Theme.muted : Theme.text)
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.vertical, 7)
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
    }

    static func symbol(_ kind: OutputLine.Kind) -> String {
        switch kind {
        case .done: return "checkmark"
        case .preview: return "arrow.right"
        case .skipped: return "minus"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark"
        case .info: return "circle.fill"
        }
    }

    static func color(_ kind: OutputLine.Kind) -> Color {
        switch kind {
        case .done: return Palette.cpu
        case .preview: return Palette.network
        case .skipped, .info: return Theme.muted
        case .warning: return Palette.memory
        case .error: return Palette.hot
        }
    }
}
