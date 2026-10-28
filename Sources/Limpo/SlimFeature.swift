import SwiftUI
import AppKit

// MARK: - Reduzir apps universais (`mo slim`)

struct SlimApp: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let size: Int64
    var path: String? {
        ["/Applications", FS.home + "/Applications"]
            .map { "\($0)/\(name).app" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}

@MainActor
@Observable
final class SlimModel {
    enum Phase { case idle, scanning, results }

    var phase: Phase = .idle
    var apps: [SlimApp] = []
    var summary = ""
    var unsupported: String?

    var total: Int64 { apps.reduce(0) { $0 + $1.size } }

    func scan() async {
        phase = .scanning
        unsupported = nil
        do {
            let result = try await MoleCLI.run(["slim", "--dry-run"], mergeStderr: true)
            let text = ANSI.strip(result.output)
            if text.contains("Unknown command") {
                unsupported = "Sua versão do Mole ainda não tem o mo slim. Atualize em Ajustes."
            }
            var list: [SlimApp] = []
            for raw in text.components(separatedBy: "\n") {
                guard raw.hasPrefix("  "), !raw.contains("DRY RUN") else {
                    if raw.contains("of Intel code") { summary = raw.trimmingCharacters(in: .whitespaces) }
                    continue
                }
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard let split = line.range(of: #"\s+[0-9.,]+\s*(B|KB|MB|GB|TB)$"#, options: .regularExpression) else { continue }
                let name = String(line[..<split.lowerBound]).trimmingCharacters(in: .whitespaces)
                list.append(SlimApp(name: name, size: Sizes.parse(String(line[split]))))
            }
            apps = list.sorted { $0.size > $1.size }
        } catch {
            unsupported = error.localizedDescription
        }
        phase = .results
    }
}

struct SlimView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.slim

        switch model.phase {
        case .idle:
            HeroView(
                icon: "scissors",
                title: "Reduzir apps",
                subtitle: "Em Macs com Apple Silicon, remove o código Intel de apps universais. Cada app é reduzido numa cópia que precisa passar na assinatura e no Gatekeeper; o original vai para o Lixo. Atualizações do app trazem o código Intel de volta.",
                button: "Analisar"
            ) {
                Task { await model.scan() }
            }
        case .scanning:
            BusyView(title: "Procurando código Intel nos apps…")
        case .results:
            VStack(spacing: 0) {
                TopBar(title: "Reduzir apps") { model.phase = .idle }
                if let unsupported = model.unsupported {
                    Text(unsupported).foregroundStyle(Theme.muted).padding()
                }
                if model.apps.isEmpty {
                    VStack(spacing: 14) {
                        IconTile(icon: "checkmark", size: 80)
                        Text("Nenhum app com código Intel para remover").font(.system(size: 20, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.apps) { app in
                                HStack(spacing: 14) {
                                    if let path = app.path { FileIcon(path: path, size: 34) } else { IconTile(icon: "app", size: 34) }
                                    Text(app.name).font(.system(size: 14))
                                    Spacer()
                                    Text(Bytes.str(app.size)).foregroundStyle(Palette.gpu)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 54)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                }
                HStack(spacing: 18) {
                    Text(model.summary.isEmpty ? "\(model.apps.count) apps" : model.summary).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("A escolha dos apps é feita no Terminal, que mostra a seleção do Mole.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Button("Reduzir no Terminal") { SettingsModel.runInTerminal("slim") }
                        .buttonStyle(PillButtonStyle(width: 240))
                        .disabled(model.apps.isEmpty)
                        .opacity(model.apps.isEmpty ? 0.4 : 1)
                }
                .padding(.horizontal, 28)
                .frame(height: 84)
                .background(Theme.bar)
            }
        }
    }
}

enum AppsMode: String, CaseIterable {
    case uninstall, slim
    var title: String { self == .uninstall ? "Desinstalar" : "Reduzir (Intel)" }
}

struct AppsTabView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            switch store.appsMode {
            case .uninstall: UninstallView()
            case .slim: SlimView()
            }
        }
    }
}
