import SwiftUI
import AppKit

/// Paleta grafite no estilo dos apps da Apple (Ajustes, Música, Xcode em modo escuro).
enum Theme {
    static let sidebar = Color(white: 0.105)
    static let main = Color(white: 0.135)
    static let panel = Color(white: 0.175)
    static let bar = Color(white: 0.115)
    static let accent = Color.white
    static let accentLight = Color(white: 0.86)
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let text = Color(white: 0.96)
    static let muted = Color(white: 0.58)
    static let faint = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.09)
    static let warning = Color(white: 0.72)
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

struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var width: CGFloat = 320

    func makeBody(configuration: Configuration) -> some View {
        let isLight = color == Theme.accent
        return configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isLight ? Color.black : Color.white)
            .frame(width: width, height: 46)
            .background(
                Capsule()
                    .fill(color.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(isLight ? 0 : 0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: - Componentes

/// Ícone em "squircle" grafite, estilo ícones do Ajustes do Sistema.
/// O parâmetro `colors` é mantido por compatibilidade, mas a paleta é monocromática.
struct IconTile: View {
    let icon: String
    var colors: [Color] = []
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.34), Color(white: 0.16)],
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

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color.white.opacity(0.05), .clear], center: .center, startRadius: 10, endRadius: 520)

            VStack(spacing: 16) {
                IconTile(icon: icon, size: 104)
                    .padding(.bottom, 10)
                Text(title)
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(-0.4)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 500)
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                }
                Button(button, action: action)
                    .buttonStyle(PillButtonStyle())
                    .padding(.top, 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

struct BusyView: View {
    let title: String
    var subtitle: String = "Isso pode levar alguns minutos."

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
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
                .buttonStyle(PillButtonStyle(color: destructive ? Theme.danger : Theme.accent, width: 260))
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
        }
        .padding(.horizontal, 28)
        .frame(height: 84)
        .background(
            VisualEffect(material: .headerView)
                .overlay(Theme.bar.opacity(0.6))
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private func sizeBlock(_ bytes: Int64, label: String, dim: Bool) -> some View {
        let parts = Bytes.split(bytes)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parts.number)
                .font(.system(size: 34, weight: .light, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 0) {
                Text(parts.unit).font(.system(size: 12, weight: .medium))
                Text(label).font(.system(size: 12))
            }
        }
        .foregroundStyle(dim ? Theme.muted : Theme.text)
    }
}

struct CheckBox: View {
    let on: Bool

    var body: some View {
        Group {
            if on {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(Color(white: 0.4))
            }
        }
        .font(.system(size: 18, weight: .regular))
        .animation(.easeOut(duration: 0.12), value: on)
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
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
