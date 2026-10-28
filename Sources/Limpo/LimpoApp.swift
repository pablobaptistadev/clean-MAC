import SwiftUI
import AppKit

@main
struct LimpoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A janela principal e o ícone da barra de menus são criados pelo AppDelegate.
        Settings { EmptyView() }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case clean, optimize, analyze, uninstall, status

    var id: String { rawValue }

    var tab: String {
        switch self {
        case .clean: return "Limpar"
        case .optimize: return "Otimizar"
        case .analyze: return "Analisar"
        case .uninstall: return "Apps"
        case .status: return "Status"
        }
    }

    var menuTitle: String { tab }

    var symbol: String {
        switch self {
        case .clean: return "sparkles"
        case .optimize: return "gauge.with.dots.needle.bottom.50percent"
        case .analyze: return "chart.pie"
        case .uninstall: return "square.grid.2x2"
        case .status: return "waveform.path.ecg"
        }
    }
}

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
}

enum AppSheet: String, Identifiable {
    case history, settings
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    var section: AppSection = .clean
    var cleanMode: CleanMode = .system
    var analyzeMode: AnalyzeMode = .explorer
    var sheet: AppSheet?
    var moPath: String? = MoleCLI.locate()
    var keepAwake = KeepAwake()

    let clean = CleanModel()
    let optimize = OptimizeModel()
    let explorer = ExplorerModel()
    let large = LargeFilesModel()
    let uninstall = UninstallModel()
    let status = StatusModel()
    let processes = ProcessModel()
    let history = HistoryModel()
    let settings = SettingsModel()
    let updates = UpdateModel()
    let purge = ScanListModel(scanner: { await PurgeScanner.scan() })
    let installers = ScanListModel(scanner: { await InstallerScanner.scan() })
    let external = ExternalCleanModel()
    let slim = SlimModel()
    var appsMode: AppsMode = .uninstall

    func recheck() {
        moPath = MoleCLI.locate()
    }
}

// MARK: - Janela principal

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(spacing: 0) {
                if store.moPath == nil {
                    MissingMoleView()
                } else {
                    if store.updates.bannerVisible {
                        UpdateBanner()
                            .padding(.horizontal, 24)
                            .padding(.top, 34)
                            .padding(.bottom, 4)
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.main)
        }
        .foregroundStyle(Theme.text)
        .ignoresSafeArea()
        .sheet(item: Binding(get: { store.sheet }, set: { store.sheet = $0 })) { sheet in
            switch sheet {
            case .history: HistorySheet().environment(store)
            case .settings: SettingsSheet().environment(store)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.section {
        case .clean: CleanTabView()
        case .optimize: OptimizeView()
        case .analyze: AnalyzeTabView()
        case .uninstall: AppsTabView()
        case .status: StatusView()
        }
    }
}

/// Itens da barra lateral: cada um leva a uma seção (e ao modo dela), como a lista do BuhoCleaner.
enum SidebarItem: String, CaseIterable, Identifiable {
    case clean, uninstall, largeFiles, explorer, projects, installers, optimize, status, external, slim

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "Limpeza rápida"
        case .uninstall: return "Desinstalar apps"
        case .largeFiles: return "Arquivos grandes"
        case .explorer: return "Espaço em disco"
        case .projects: return "Projetos"
        case .installers: return "Instaladores"
        case .optimize: return "Otimizar"
        case .status: return "Status"
        case .external: return "Disco externo"
        case .slim: return "Reduzir apps (Intel)"
        }
    }

    var symbol: String {
        switch self {
        case .clean: return "bolt"
        case .uninstall: return "trash"
        case .largeFiles: return "folder"
        case .explorer: return "chart.pie"
        case .projects: return "hammer"
        case .installers: return "shippingbox"
        case .optimize: return "gauge.with.dots.needle.bottom.50percent"
        case .status: return "waveform.path.ecg"
        case .external: return "externaldrive"
        case .slim: return "scissors"
        }
    }

    @MainActor func isActive(_ store: AppStore) -> Bool {
        switch self {
        case .clean: return store.section == .clean && store.cleanMode == .system
        case .projects: return store.section == .clean && store.cleanMode == .projects
        case .installers: return store.section == .clean && store.cleanMode == .installers
        case .external: return store.section == .clean && store.cleanMode == .external
        case .uninstall: return store.section == .uninstall && store.appsMode == .uninstall
        case .slim: return store.section == .uninstall && store.appsMode == .slim
        case .largeFiles: return store.section == .analyze && store.analyzeMode == .largeFiles
        case .explorer: return store.section == .analyze && store.analyzeMode == .explorer
        case .optimize: return store.section == .optimize
        case .status: return store.section == .status
        }
    }

    @MainActor func select(_ store: AppStore) {
        switch self {
        case .clean: store.section = .clean; store.cleanMode = .system
        case .projects: store.section = .clean; store.cleanMode = .projects
        case .installers: store.section = .clean; store.cleanMode = .installers
        case .external: store.section = .clean; store.cleanMode = .external
        case .uninstall: store.section = .uninstall; store.appsMode = .uninstall
        case .slim: store.section = .uninstall; store.appsMode = .slim
        case .largeFiles: store.section = .analyze; store.analyzeMode = .largeFiles
        case .explorer: store.section = .analyze; store.analyzeMode = .explorer
        case .optimize: store.section = .optimize
        case .status: store.section = .status
        }
    }
}

struct Sidebar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                AppGlyph(size: 18)
                Text("Limpo")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accentLight)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 46)
            .padding(.bottom, 30)

            ForEach(SidebarItem.allCases) { item in
                row(item.title, item.symbol, active: item.isActive(store)) {
                    withAnimation(.snappy(duration: 0.2)) { item.select(store) }
                }
            }
            Spacer()
            row("Histórico", "clock.arrow.circlepath", active: false) { store.sheet = .history }
            row("Ajustes", "gearshape", active: false) { store.sheet = .settings }
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 11)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func row(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(active ? 1 : 0.88))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(active ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Ícone do Limpo (brilhos sobre azul), usado na barra lateral.
struct AppGlyph: View {
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.9, weight: .semibold))
            .foregroundStyle(Theme.accentLight)
            .frame(width: size, height: size)
    }
}

struct MissingMoleView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            IconTile(icon: "exclamationmark.triangle.fill", size: 90)
            Text("Mole não encontrado")
                .font(.system(size: 30, weight: .semibold))
            Text("O Limpo usa o Mole CLI por baixo. Instale pelo Homebrew e clique em Verificar novamente.")
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack {
                Text("brew install mole")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install mole", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            Button("Verificar novamente") { store.recheck() }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
