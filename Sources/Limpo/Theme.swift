import SwiftUI
import AppKit

/// Paleta azul-marinho no estilo do BuhoCleaner: barra lateral escura, área principal azul,
/// botões principais em azul vivo e links em azul claro.
enum Theme {
    static let sidebar = Color(red: 0.122, green: 0.133, blue: 0.200)
    static let main = Color(red: 0.216, green: 0.290, blue: 0.471)
    static let panel = Color(red: 0.250, green: 0.329, blue: 0.525)
    static let selection = Color(red: 0.180, green: 0.243, blue: 0.408)
    static let bar = Color(red: 0.173, green: 0.231, blue: 0.392)
    static let accent = Color(red: 0.255, green: 0.443, blue: 0.957)
    static let accentLight = Color(red: 0.490, green: 0.650, blue: 1.000)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let text = Color.white
    static let muted = Color(red: 0.690, green: 0.737, blue: 0.851)
    static let faint = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.08)
    static let warning = Color(red: 1.0, green: 0.80, blue: 0.40)
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

/// Ícone em "squircle" azul.
/// O parâmetro `colors` é mantido por compatibilidade; a cor vem do tema.
struct IconTile: View {
    let icon: String
    var colors: [Color] = []
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.18, green: 0.35, blue: 0.86)],
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
                .foregroundStyle(Theme.sidebar.opacity(0.35))
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
                Circle().stroke(Theme.sidebar.opacity(0.6), lineWidth: 9)
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

// MARK: - Cores dos gráficos (a interface é grafite; só os dados ganham cor)

enum Palette {
    static let cpu = Color(red: 0.36, green: 0.84, blue: 0.56)
    static let gpu = Color(red: 1.00, green: 0.62, blue: 0.32)
    static let memory = Color(red: 0.98, green: 0.80, blue: 0.38)
    static let disk = Color(red: 0.42, green: 0.62, blue: 1.00)
    static let network = Color(red: 0.36, green: 0.74, blue: 1.00)
    static let upload = Color(red: 0.42, green: 0.88, blue: 0.62)
    static let warm = Color(red: 1.00, green: 0.55, blue: 0.30)
    static let hot = Color(red: 1.00, green: 0.33, blue: 0.33)
    static let violet = Color(red: 0.70, green: 0.56, blue: 1.00)

    /// Verde → âmbar → vermelho conforme a fração (0…1).
    static func level(_ fraction: Double) -> Color {
        fraction >= 0.85 ? hot : fraction >= 0.65 ? warm : cpu
    }

    static func health(_ score: Int) -> Color {
        score >= 80 ? cpu : score >= 60 ? memory : hot
    }

    static let temperature = LinearGradient(colors: [cpu, memory, warm, hot], startPoint: .leading, endPoint: .trailing)
}
