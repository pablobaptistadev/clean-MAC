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
}

@MainActor
@Observable
final class CleanModel {
    enum Phase { case idle, scanning, preview, cleaning, done }

    var phase: Phase = .idle
    var sections: [CleanSection] = []
    var freed: Int64 = 0
    var log = ""
    var showLog = false
    var paths: [String: [CleanPath]] = [:]
    var expanded: Set<String> = []
    var protected: Set<String> = []
    var protectionChanged = false

    func toggleExpanded(_ name: String) {
        if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
    }

    func toggleProtect(_ path: String) {
        if protected.contains(path) {
            Whitelist.unprotect(path)
            protected.remove(path)
        } else {
            Whitelist.protect(path)
            protected.insert(path)
        }
        protectionChanged = true
    }
    var error: String?

    var total: Int64 { sections.reduce(0) { $0 + $1.bytes } }

    func scan() async {
        phase = .scanning
        error = nil
        do {
            let result = try await MoleCLI.run(["clean", "--dry-run"], mergeStderr: true)
            sections = CleanParser.parse(result.output)
            paths = CleanListFile.read()
            protected = Set(paths.values.flatMap { $0 }.map(\.path).filter(Whitelist.isProtected))
            protectionChanged = false
            phase = .preview
        } catch {
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    func clean() async {
        phase = .cleaning
        do {
            let result = try await MoleCLI.run(["clean"], mergeStderr: true)
            log = ANSI.strip(result.output)
            let done = CleanParser.parse(result.output)
            freed = done.reduce(0) { $0 + $1.bytes }
            sections = done
            phase = .done
        } catch {
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    func reset() {
        phase = .idle
        sections = []
        log = ""
        error = nil
    }
}

struct CleanView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.clean

        switch model.phase {
        case .idle:
            HeroView(
                icon: "bolt.fill",
                colors: [Color(red: 0.35, green: 0.62, blue: 1), Color(red: 0.18, green: 0.38, blue: 0.92)],
                title: "Limpeza",
                subtitle: "Remove caches, logs, arquivos temporários e restos de apps já desinstalados. Você vê tudo antes de apagar.",
                button: "Analisar",
                error: model.error
            ) {
                Task { await model.scan() }
            }

        case .scanning:
            BusyView(title: "Analisando seu Mac…")

        case .cleaning:
            BusyView(title: "Limpando…", subtitle: "Não feche o app.")

        case .preview:
            VStack(spacing: 0) {
                TopBar(title: "Limpeza") { model.reset() }
                if model.sections.isEmpty {
                    VStack(spacing: 14) {
                        IconTile(icon: "checkmark", colors: [.green, .teal], size: 80)
                        Text("Nada para limpar").font(.system(size: 26, weight: .semibold))
                        Text("Seu Mac já está em dia.").foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if model.protectionChanged {
                                HStack {
                                    Image(systemName: "lock.shield").foregroundStyle(Palette.memory)
                                    Text("Proteções alteradas. Analise de novo para atualizar o total.")
                                    Spacer()
                                    Button("Analisar de novo") { Task { await model.scan() } }
                                }
                                .font(.system(size: 13))
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.memory.opacity(0.1)))
                            }
                            ForEach(model.sections) { section in
                                SectionCard(section: section, model: model)
                            }
                            Text("Caches de sistema que exigem senha de administrador não entram nesta limpeza.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                    }
                }
                BottomBar(
                    selected: model.total,
                    total: model.total,
                    selectedLabel: "Para limpar",
                    button: "Limpar",
                    enabled: model.total > 0
                ) {
                    Task { await model.clean() }
                }
            }

        case .done:
            VStack(spacing: 18) {
                IconTile(icon: "checkmark.seal.fill", colors: [.green, .teal], size: 100)
                Text("Limpeza concluída")
                    .font(.system(size: 34, weight: .semibold))
                Text("\(Bytes.str(model.freed)) liberados")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.muted)
                Button(model.showLog ? "Ocultar detalhes" : "Ver detalhes") { model.showLog.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentLight)
                if model.showLog {
                    ScrollView {
                        Text(model.log)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(maxWidth: 680, maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
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

private struct SectionCard: View {
    let section: CleanSection
    let model: CleanModel

    var body: some View {
        let paths = model.paths[section.name] ?? []
        let open = model.expanded.contains(section.name)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(section.name).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(Bytes.str(section.bytes)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            ForEach(section.items) { item in
                Divider().overlay(Theme.faint)
                HStack {
                    Circle().fill(Palette.network).frame(width: 5, height: 5)
                    Text(item.title)
                    Spacer()
                    Text(item.detail).foregroundStyle(Theme.muted)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            if !paths.isEmpty {
                Divider().overlay(Theme.faint)
                Button { model.toggleExpanded(section.name) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        Text(open ? "Ocultar caminhos" : "Ver \(paths.count) caminho(s) e proteger o que quiser manter")
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.accentLight)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(paths.prefix(300)) { p in
                        let isProtected = model.protected.contains(p.path)
                        HStack(spacing: 10) {
                            Text(FS.tilde(p.path))
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(isProtected ? Theme.muted : Theme.text)
                                .strikethrough(isProtected)
                            Spacer()
                            Text(p.note).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.muted)
                            Button(isProtected ? "Protegido" : "Proteger") { model.toggleProtect(p.path) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isProtected ? Palette.memory : Theme.accentLight)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 5)
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
    }
}
