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
        VStack(spacing: 0) {
            if store.moPath == nil {
                MissingMoleView()
            } else {
                TabHeader()
                if store.updates.bannerVisible {
                    UpdateBanner()
                        .padding(.horizontal, 32)
                        .padding(.vertical, 8)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(white: 0.15), Theme.main], startPoint: .top, endPoint: .center)
        )
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

struct TabHeader: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            AppGlyph(size: 34)
                .padding(.trailing, 6)
            ForEach(AppSection.allCases) { section in
                let active = store.section == section
                Button {
                    withAnimation(.snappy(duration: 0.22)) { store.section = section }
                } label: {
                    Text(section.tab)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(active ? Color.black : Color(white: 0.83))
                        .padding(.horizontal, 20)
                        .frame(height: 34)
                        .background(
                            Capsule()
                                .fill(active ? Color(white: 0.96) : .clear)
                                .shadow(color: .black.opacity(active ? 0.35 : 0), radius: 6, y: 2)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        )
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            HStack(spacing: 14) {
                headerButton("clock.arrow.circlepath", "Histórico") { store.sheet = .history }
                headerButton("gearshape", "Ajustes") { store.sheet = .settings }
            }
            .padding(.trailing, 20)
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func headerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Ícone do Limpo (brilhos sobre grafite), usado na barra de abas.
struct AppGlyph: View {
    var size: CGFloat = 34

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.17)], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            )
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
