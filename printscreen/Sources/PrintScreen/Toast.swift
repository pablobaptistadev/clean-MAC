import AppKit

// MARK: - Aviso rápido de sucesso ("Copiado"), que some sozinho

@MainActor
enum Toast {
    private static var current: ToastPanel?

    /// Mostra o aviso centrado em `point` (coordenadas da tela) e some depois de `seconds`.
    static func show(_ title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill",
                     at point: CGPoint, seconds: TimeInterval = 1.6) {
        current?.orderOut(nil)
        let panel = ToastPanel(title: title, detail: detail, symbol: symbol)
        var origin = CGPoint(x: point.x - panel.frame.width / 2, y: point.y - panel.frame.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        current = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    if current === panel { current = nil }
                }
            })
        }
    }
}

/// Vidro escuro com ícone verde, como os avisos do sistema.
final class ToastPanel: NSPanel {
    init(title: String, detail: String?, symbol: String) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))!)
        icon.contentTintColor = .systemGreen
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        var texts: [NSView] = [titleLabel]
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.7)
            texts.append(detailLabel)
        }
        let column = NSStackView(views: texts)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        let row = NSStackView(views: [icon, column])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.topAnchor),
            row.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        // Tamanho pelas partes (o fittingSize da pilha não conta as margens de cima e de baixo aqui).
        let iconSize = icon.fittingSize, textSize = column.fittingSize
        let size = CGSize(width: ceil(16 + iconSize.width + 10 + textSize.width + 20),
                          height: ceil(max(iconSize.height, textSize.height) + 24))
        glass.frame = CGRect(origin: .zero, size: size)
        contentView = glass
        setContentSize(size)
    }

    override var canBecomeKey: Bool { false }
}
