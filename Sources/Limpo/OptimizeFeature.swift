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

    var actionable: Int { sections.reduce(0) { $0 + $1.lines.filter { $0.kind == .preview || $0.kind == .done }.count } }

    func preview() async {
        phase = .scanning
        error = nil
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
                TopBar(title: model.phase == .done ? "Otimização concluída" : "Otimizar") { model.reset() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.sections.isEmpty, model.phase == .running {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Iniciando…").foregroundStyle(Theme.muted)
                            }
                        }
                        ForEach(model.sections) { section in
                            OutputSectionCard(section: section)
                        }
                        if !model.summary.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.summary, id: \.self) { Text($0) }
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 4)
                        }
                        if model.phase == .done {
                            Button(model.showLog ? "Ocultar saída completa" : "Ver saída completa") { model.showLog.toggle() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accentLight)
                            if model.showLog {
                                Text(ANSI.strip(model.raw))
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
                            }
                        }
                        Text("Tarefas que exigem senha de administrador são puladas quando o Mole roda pelo app. Para incluí-las, rode `mo optimize` no Terminal.")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                }
                bottom(model)
            }
        }
    }

    @ViewBuilder
    private func bottom(_ model: OptimizeModel) -> some View {
        HStack(spacing: 18) {
            Spacer()
            switch model.phase {
            case .preview:
                Button("Escolher tarefas…") { AppStore.shared.sheet = .settings }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentLight)
                Text("\(model.actionable) tarefa(s) no plano").foregroundStyle(Theme.muted)
                Button("Otimizar") { Task { await model.run() } }
                    .buttonStyle(PillButtonStyle(width: 260))
            case .running:
                ProgressView().controlSize(.small)
                Text("Otimizando…").foregroundStyle(Theme.muted)
            default:
                Button("Analisar novamente") { Task { await model.preview() } }
                    .buttonStyle(PillButtonStyle(width: 260))
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 84)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct OutputSectionCard: View {
    let section: OutputSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            ForEach(section.lines) { line in
                Divider().overlay(Theme.faint)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol(line.kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color(line.kind))
                        .frame(width: 16)
                    Text(line.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(line.kind == .skipped ? Theme.muted : Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func symbol(_ kind: OutputLine.Kind) -> String {
        switch kind {
        case .done: return "checkmark"
        case .preview: return "arrow.right"
        case .skipped: return "minus"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark"
        case .info: return "circle.fill"
        }
    }

    private func color(_ kind: OutputLine.Kind) -> Color {
        switch kind {
        case .done: return Palette.cpu
        case .preview: return Palette.network
        case .skipped, .info: return Theme.muted
        case .warning: return Palette.memory
        case .error: return Palette.hot
        }
    }
}
