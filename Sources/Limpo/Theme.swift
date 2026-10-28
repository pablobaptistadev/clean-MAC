import SwiftUI
import AppKit

/// Cores do sistema da Apple (iOS / macOS em modo escuro) no layout do BuhoCleaner:
/// fundos cinza-escuro em camadas, azul do sistema para ações e links. Nada em vermelho:
/// alertas e erros usam o laranja do sistema.
enum Theme {
    static let sidebar = Color(red: 0.086, green: 0.086, blue: 0.094)     // #161618
    static let main = Color(red: 0.110, green: 0.110, blue: 0.118)        // #1C1C1E
    static let panel = Color(red: 0.173, green: 0.173, blue: 0.180)       // #2C2C2E
    static let selection = Color(red: 0.227, green: 0.227, blue: 0.235)   // #3A3A3C
    static let bar = Color(red: 0.141, green: 0.141, blue: 0.149)         // #242426
    static let accent = Color(red: 0.039, green: 0.518, blue: 1.000)      // systemBlue #0A84FF
    static let accentLight = Color(red: 0.251, green: 0.612, blue: 1.000) // link #409CFF
    static let danger = Color(red: 1.000, green: 0.624, blue: 0.039)      // systemOrange #FF9F0A
    static let text = Color.white
    static let muted = Color(red: 0.596, green: 0.596, blue: 0.624)       // systemGray #98989F
    static let faint = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.10)
    static let warning = Color(red: 1.000, green: 0.839, blue: 0.039)     // systemYellow #FFD60A
}

// MARK: - Vidro / vibrancy nativo

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Botões

/// Botão em pílula. Azul por padrão (Analisar, Remover); `.white` vira a pílula branca de "Limpar · X GB".
struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var width: CGFloat = 200
    var height: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        let isLight = color == .white
        return configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(isLight ? Theme.sidebar : Color.white)
            .frame(minWidth: width)
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(
                Capsule()
                    .fill(color.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Link azul claro usado nas barras ("Todos · Nenhum", "Encerrar").
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.accentLight.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}

// MARK: - Componentes

/// Ícone em "squircle" no azul do sistema.
/// O parâmetro `colors` é mantido por compatibilidade; a cor vem do tema.
struct IconTile: View {
    let icon: String
    var colors: [Color] = []
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.25, green: 0.62, blue: 1.0), Color(red: 0.0, green: 0.44, blue: 0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: max(0.5, size * 0.012)
                    )
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom)
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: size * 0.1, y: size * 0.05)
    }
}

struct HeroView: View {
    let icon: String
    var colors: [Color] = []
    let title: String
    let subtitle: String
    let button: String
    var error: String? = nil
    let action: () -> Void

    /// Tela inicial de cada módulo: título, descrição, "Analisar" e o ícone grande e apagado cortado na borda direita.
    var body: some View {
        ZStack {
            Image(systemName: icon)
                .font(.system(size: 300, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.045))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: 110)
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 30, weight: .regular))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                Button(button, action: action)
                    .buttonStyle(PillButtonStyle())
                    .padding(.top, 38)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// Anel de progresso do BuhoCleaner. Sem `fraction`, o arco gira (análise sem porcentagem conhecida).
struct ProgressRing: View {
    var fraction: Double?
    var size: CGFloat = 132
    var label: String? = nil

    var body: some View {
        TimelineView(.animation(paused: fraction != nil)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: fraction.map { max(0.02, min($0, 1)) } ?? 0.28)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(fraction == nil ? angle - 90 : -90))
                if let label {
                    Text(label).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                } else if let fraction {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(fraction * 100))").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        Text("%").font(.system(size: 12, weight: .medium))
                    }
                }
            }
            .frame(width: size, height: size)
        }
    }
}

struct BusyView: View {
    let title: String
    var subtitle: String = "Isso pode levar alguns minutos."

    var body: some View {
        VStack(spacing: 22) {
            ProgressRing()
            Text(title)
                .font(.system(size: 22, weight: .regular))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TopBar: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Começar novamente")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .frame(height: 58)
    }
}

struct BottomBar: View {
    let selected: Int64
    let total: Int64
    let selectedLabel: String
    let button: String
    let enabled: Bool
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 22) {
            Spacer()
            sizeBlock(selected, label: selectedLabel, dim: false)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 40)
            sizeBlock(total, label: "Total", dim: true)
            Button(button, action: action)
                .buttonStyle(PillButtonStyle(width: 150))
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
        .background(Theme.bar)
    }

    private func sizeBlock(_ bytes: Int64, label: String, dim: Bool) -> some View {
        let parts = Bytes.split(bytes)
        return HStack(alignment: .center, spacing: 5) {
            Text(parts.number)
                .font(.system(size: 24, weight: .regular))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 0) {
                Text(parts.unit).font(.system(size: 10.5, weight: .medium))
                Text(label).font(.system(size: 10.5))
            }
        }
        .foregroundStyle(dim ? Theme.muted.opacity(0.7) : Theme.text)
    }
}

/// Caixa de marcar quadrada (azul quando marcada), como no BuhoCleaner.
struct CheckBox: View {
    let on: Bool

    var body: some View {
        TriCheckBox(state: on ? .on : .off)
    }
}

struct TriCheckBox: View {
    enum State { case off, mixed, on }
    let state: State
    var disabled = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(state == .off ? Color.clear : Theme.accent)
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(state == .off ? Theme.muted.opacity(0.75) : Theme.accent, lineWidth: 1.2)
            if state == .on {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            } else if state == .mixed {
                RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 8, height: 2)
            }
        }
        .frame(width: 15, height: 15)
        .opacity(disabled ? 0.4 : 1)
        .animation(.easeOut(duration: 0.12), value: state)
    }
}

// MARK: - Peças das listas no estilo do BuhoCleaner (coluna de filtros + lista + barra inferior)

/// Linha da coluna de filtros à esquerda (Todos, Selecionados, categorias…).
struct FilterRow: View {
    let symbol: String
    let title: String
    let value: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(value).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Coluna de filtros: largura fixa, rolável quando há muitos grupos.
struct FilterColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) { content }
                .padding(.horizontal, 10)
                .padding(.top, 4)
        }
        .frame(width: 250)
    }
}

/// Título e descrição acima de uma lista, com controles à direita (ordenar, marcar todos).
struct ListHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 12) {
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                trailing
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

/// Linha de arquivo com caixa de marcar, ícone, nome, detalhe, tamanho e "mostrar no Finder".
struct FileCheckRow: View {
    let path: String
    let name: String
    let detail: String
    let size: Int64
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) { CheckBox(on: selected) }
                .buttonStyle(.plain)
            FileIcon(path: path, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Bytes.str(size)).font(.system(size: 12)).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help("Mostrar no Finder")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

/// Lista vazia depois de uma análise ("Nada para limpar").
struct EmptyResult: View {
    let title: String
    var subtitle = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 54, weight: .light)).foregroundStyle(Theme.accentLight)
            Text(title).font(.system(size: 24))
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Cabeçalho das telas de resultado ("Pronto para limpar"): título, resumo e botões à direita.
struct ResultHeader: View {
    let title: String
    let subtitle: String
    var onRefresh: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(spacing: 14) {
                if let onRefresh {
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .help("Analisar de novo")
                }
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                        .help("Começar novamente")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 14)
    }
}

/// Barra inferior das telas de resultado: informações à esquerda e a pílula de ação à direita.
struct ActionBar<Leading: View>: View {
    let button: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 6) {
            leading
            Spacer()
            Button(button, action: action)
                .buttonStyle(PillButtonStyle(color: .white, width: 190))
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 22)
        .frame(height: 62)
        .background(Theme.bar)
    }
}

struct FileIcon: View {
    let path: String
    var size: CGFloat = 34

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.panel)
            )
    }
}

// MARK: - Bytes

enum Bytes {
    static func str(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    /// Memória em unidades binárias (16 GB de RAM = 16 GB), como no Monitor de Atividade.
    static func mem(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    static func split(_ bytes: Int64) -> (number: String, unit: String) {
        let s = str(bytes)
        guard let space = s.lastIndex(where: { $0.isWhitespace }) else { return (s, "") }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }
}

// MARK: - Cores dos dados: as cores do sistema da Apple (modo escuro), sem vermelho

enum Palette {
    static let cpu = Color(red: 0.188, green: 0.820, blue: 0.345)     // systemGreen #30D158
    static let gpu = Color(red: 1.000, green: 0.624, blue: 0.039)     // systemOrange #FF9F0A
    static let memory = Color(red: 1.000, green: 0.839, blue: 0.039)  // systemYellow #FFD60A
    static let disk = Color(red: 0.039, green: 0.518, blue: 1.000)    // systemBlue #0A84FF
    static let network = Color(red: 0.392, green: 0.824, blue: 1.000) // systemCyan #64D2FF
    static let upload = Color(red: 0.400, green: 0.831, blue: 0.812)  // systemMint #66D4CF
    static let warm = Color(red: 1.000, green: 0.624, blue: 0.039)    // systemOrange
    static let hot = Color(red: 1.000, green: 0.624, blue: 0.039)     // systemOrange (o vermelho foi aposentado)
    static let violet = Color(red: 0.749, green: 0.353, blue: 0.949)  // systemPurple #BF5AF2

    /// Verde → amarelo → laranja conforme a fração (0…1).
    static func level(_ fraction: Double) -> Color {
        fraction >= 0.85 ? hot : fraction >= 0.65 ? memory : cpu
    }

    static func health(_ score: Int) -> Color {
        score >= 80 ? cpu : score >= 60 ? memory : hot
    }

    static let temperature = LinearGradient(colors: [cpu, memory, warm, hot], startPoint: .leading, endPoint: .trailing)
}
