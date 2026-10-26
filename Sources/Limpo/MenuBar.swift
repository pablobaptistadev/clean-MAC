import SwiftUI
import AppKit
import IOKit.pwr_mgt
import UserNotifications

// MARK: - App delegate: janela principal + ícone da barra de menus

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    private var store: AppStore { AppStore.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Uma instância só: se já houver um Limpo aberto, traz ele para frente e encerra este.
        let me = NSRunningApplication.current
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0 != me }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        setupStatusItem()
        if UserDefaults.standard.bool(forKey: "backgroundMonitor") { store.status.attach() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        store.status.onAlert = { alert in
            let content = UNMutableNotificationContent()
            content.title = "\(alert.name ?? "Um processo") está pesando na CPU"
            content.body = "\(Fmt.dec(alert.cpu))% de CPU há mais de \(alert.window ?? "alguns minutos") (PID \(alert.pid))."
            content.sound = .default
            let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        store.updates.onFound = { release in
            let content = UNMutableNotificationContent()
            content.title = "Limpo \(release.version) disponível"
            content.body = "Abra o Limpo e clique em Atualizar. Ele baixa a versão nova, troca o app e reabre sozinho."
            let request = UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        store.updates.start()
        showMainWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    // MARK: Janela

    @objc func showMainWindow(_ sender: Any?) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: RootView()
                    .environment(store)
                    .frame(minWidth: 1100, minHeight: 720)
            )
            let win = NSWindow(contentViewController: hosting)
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.title = "Limpo"
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.backgroundColor = NSColor(white: 0.13, alpha: 1)
            win.setContentSize(NSSize(width: 1240, height: 800))
            win.center()
            _ = win.setFrameAutosaveName("LimpoMain")
            window = win
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func open(_ section: AppSection) {
        store.section = section
        popover.performClose(nil)
        showMainWindow(nil)
    }

    // MARK: Barra de menus

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Limpo")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        let monitor = NSHostingController(
            rootView: MonitorView(
                onOpen: { [weak self] section in self?.open(section) },
                onMenu: { [weak self] in self?.showMenu() }
            )
            .environment(store)
        )
        monitor.sizingOptions = .preferredContentSize
        popover.contentViewController = monitor
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func showMonitor(_ sender: Any?) {
        guard let button = statusItem?.button, !popover.isShown else { return }
        togglePopover(button)
    }

    private func showMenu() {
        popover.performClose(nil)
        guard let item = statusItem else { return }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in self.statusItem?.menu = nil }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(entry("Abrir Limpo", symbol: "macwindow", action: #selector(showMainWindow(_:))))
        menu.addItem(.separator())
        for section in AppSection.allCases {
            let it = entry(section.menuTitle, symbol: section.symbol, action: #selector(openSection(_:)))
            it.representedObject = section.rawValue
            menu.addItem(it)
        }
        menu.addItem(entry("Mostrar monitor", symbol: "chart.xyaxis.line", action: #selector(showMonitorLater(_:))))
        menu.addItem(.separator())
        menu.addItem(entry("Histórico", symbol: "clock.arrow.circlepath", action: #selector(openHistory(_:))))
        let settings = entry("Ajustes…", symbol: "gearshape", action: #selector(openSettings(_:)))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())

        let awake = entry("Manter tela ligada", symbol: "cup.and.saucer", action: #selector(toggleAwake(_:)))
        awake.state = store.keepAwake.isOn ? .on : .off
        menu.addItem(awake)
        menu.addItem(entry("Atualizar o Mole", symbol: "arrow.triangle.2.circlepath", action: #selector(updateMole(_:))))
        let updates = store.updates
        let limpoUpdate = updates.phase == .available
            ? entry("Atualizar o Limpo para \(updates.release?.version ?? "")…", symbol: "arrow.down.circle", action: #selector(installUpdate(_:)))
            : entry("Procurar atualizações do Limpo…", symbol: "arrow.down.circle", action: #selector(checkForUpdates(_:)))
        menu.addItem(limpoUpdate)
        menu.addItem(entry("Sobre o Limpo", symbol: "info.circle", action: #selector(about(_:))))
        menu.addItem(.separator())
        let quit = entry("Encerrar Limpo", symbol: "rectangle.portrait.and.arrow.right", action: #selector(quit(_:)))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    private func entry(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func openSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let section = AppSection(rawValue: raw) else { return }
        open(section)
    }

    @objc private func openHistory(_ sender: Any?) {
        showMainWindow(nil)
        store.sheet = .history
    }

    @objc private func openSettings(_ sender: Any?) {
        showMainWindow(nil)
        store.sheet = .settings
    }

    @objc private func showMonitorLater(_ sender: Any?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showMonitor(nil)
        }
    }

    @objc private func toggleAwake(_ sender: NSMenuItem) {
        store.keepAwake.toggle()
    }

    @objc private func updateMole(_ sender: Any?) {
        Task {
            let output: String
            do {
                let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
                if let brew, MoleCLI.locate()?.contains("brew") == true || MoleCLI.locate()?.hasPrefix("/opt/homebrew") == true {
                    output = try await Shell.run(brew, ["upgrade", "mole"])
                } else {
                    output = try await MoleCLI.run(["update"], mergeStderr: true).output
                }
            } catch {
                output = error.localizedDescription
            }
            let alert = NSAlert()
            alert.messageText = "Atualização do Mole"
            alert.informativeText = String(ANSI.strip(output).trimmingCharacters(in: .whitespacesAndNewlines).suffix(800))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Task {
            await store.updates.check(manual: true)
            if store.updates.phase == .available {
                showMainWindow(nil)
                return
            }
            let alert = NSAlert()
            alert.messageText = store.updates.phase == .upToDate ? "O Limpo está atualizado" : "Atualizações do Limpo"
            alert.informativeText = store.updates.statusText
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func installUpdate(_ sender: Any?) {
        showMainWindow(nil)
        store.updates.dismissed = nil
        Task { await store.updates.install() }
    }

    @objc private func about(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Limpo",
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
            .credits: NSAttributedString(
                string: "Interface nativa para o Mole CLI (github.com/tw93/Mole, GPL-3.0).",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

// MARK: - Manter tela ligada (asserção de energia do macOS)

struct KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isOn = false

    mutating func toggle() {
        if isOn {
            IOPMAssertionRelease(assertionID)
            isOn = false
        } else {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Limpo: manter tela ligada" as CFString,
                &assertionID
            )
            isOn = result == kIOReturnSuccess
        }
    }
}

// MARK: - Shell simples (brew)

enum Shell {
    static func run(_ path: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = MoleCLI.environment(tty: false)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

// MARK: - Monitor (popover da barra de menus)

struct MonitorView: View {
    @Environment(AppStore.self) private var store
    let onOpen: (AppSection) -> Void
    let onMenu: () -> Void

    var body: some View {
        let model = store.status
        let procs = store.processes

        VStack(alignment: .leading, spacing: 10) {
            if let s = model.snapshot {
                header(s)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    cpu(s, model)
                    gpu(s, model)
                    memory(s, model)
                    disk(s)
                    network(s, model)
                    fan(s)
                }
                if !s.connectedBluetooth.isEmpty { devices(s) }
                processes(procs)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.error ?? "Lendo o sistema…").font(.callout).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            }
            footer
        }
        .padding(14)
        .frame(width: 370)
        .background(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
        .foregroundStyle(Theme.text)
        .onAppear {
            model.attach()
            procs.attach()
            Task { await store.history.load() }
        }
        .onDisappear {
            model.detach()
            procs.detach()
        }
        .alert(
            "Encerrar \(procs.pendingKill?.name ?? "")?",
            isPresented: Binding(get: { procs.pendingKill != nil && procs.actionOrigin == "monitor" }, set: { if !$0 { procs.pendingKill = nil } })
        ) {
            Button("Cancelar", role: .cancel) { procs.pendingKill = nil }
            Button("Encerrar") {
                if let p = procs.pendingKill { procs.terminate(p, force: false) }
                procs.pendingKill = nil
            }
            Button("Forçar encerramento", role: .destructive) {
                if let p = procs.pendingKill { procs.terminate(p, force: true) }
                procs.pendingKill = nil
            }
        } message: {
            Text(procs.pendingKill?.killWarning ?? "")
        }
        .alert(
            procs.info?.group.name ?? "",
            isPresented: Binding(get: { procs.info != nil && procs.actionOrigin == "monitor" }, set: { if !$0 { procs.info = nil } })
        ) {
            Button("OK") { procs.info = nil }
            Button("Copiar PID") { if let p = procs.info?.process { procs.copyPID(p) }; procs.info = nil }
        } message: {
            if let d = procs.info {
                let count = d.group.count > 1 ? " · \(d.group.count) processos" : ""
                Text("\(d.reason)\n\nPID \(d.process.pid) · \(Bytes.mem(d.group.memoryBytes))\(count)\(d.parent.map { " · pai: \($0.name)" } ?? "")\n\(d.process.path)")
            }
        }
    }

    private func header(_ s: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Palette.health(s.health_score ?? 0))
                Text("\(s.health_score ?? 0)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(s.healthLabel)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button(action: onMenu) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Mais opções")
            }
            FlowChips(items: [
                s.hardware?.cpu_model,
                s.hardware?.total_ram,
                s.hardware?.os_version,
                s.uptime.map { "ligado há \($0)" }
            ].compactMap { $0 }.filter { !$0.isEmpty })
        }
    }

    private func temp(_ v: Double?) -> String? {
        guard let v, v > 0 else { return nil }
        return String(format: "%.0f°C", v)
    }

    private func cpu(_ s: StatusSnapshot, _ m: StatusModel) -> some View {
        MetricCard(title: "CPU", symbol: "cpu", badge: temp(s.thermal?.cpu_temp), compact: true) {
            BigValue(value: Fmt.pct(s.cpu?.usage), unit: "%", size: 26)
            CoreBars(values: s.cpu?.per_core ?? m.cpuHistory, color: Palette.cpu).frame(height: 22)
            Footnote(text: "\(s.cpu?.logical_cpu ?? 0) núcleos · carga \(Fmt.dec(s.cpu?.load1))")
        }
    }

    private func gpu(_ s: StatusSnapshot, _ m: StatusModel) -> some View {
        MetricCard(title: "GPU", symbol: "square.stack.3d.up", badge: temp(s.thermal?.gpu_temp), compact: true) {
            BigValue(value: Fmt.pct(s.gpuUsage), unit: "%", size: 26)
            Sparkline(values: m.gpuHistory, fill: true, maxValue: 100, color: Palette.gpu).frame(height: 22)
            Footnote(text: s.gpuUsage == nil ? "sem leitura de uso" : (s.gpuUsage ?? 0) < 5 ? "ociosa" + ((s.thermal?.system_power ?? 0) > 0 ? " · \(Fmt.dec(s.thermal?.system_power)) W" : "") : "em uso")
        }
    }

    private func memory(_ s: StatusSnapshot, _ m: StatusModel) -> some View {
        let high = Fmt.pressure(s.memory?.pressure) != nil
        return MetricCard(title: "Memória", symbol: "memorychip", badge: high ? "Alta" : nil, badgeStrong: high, compact: true) {
            BigValue(value: Fmt.pct(s.memory?.used_percent), unit: "%", size: 26)
            Sparkline(values: m.memHistory, fill: true, maxValue: 100, color: Palette.memory).frame(height: 22)
            Footnote(text: "\(Fmt.bytes(s.memory?.used)) / \(Fmt.bytes(s.memory?.total))")
        }
    }

    private func disk(_ s: StatusSnapshot) -> some View {
        let d = s.mainDisk
        let free = max(Int64(d?.total ?? 0) - Int64(d?.used ?? 0), 0)
        let parts = Bytes.split(free)
        return MetricCard(title: "Livre", symbol: "internaldrive", badge: Bytes.str(Int64(d?.total ?? 0)), compact: true) {
            BigValue(value: parts.number, unit: parts.unit, size: 26)
            Meter(fraction: (d?.used_percent ?? 0) / 100, color: Palette.disk).frame(height: 22)
            Footnote(text: "Leitura \(Fmt.dec(s.disk_io?.read_rate)) MB/s")
        }
    }

    private func network(_ s: StatusSnapshot, _ m: StatusModel) -> some View {
        let rx = Fmt.rate(s.rxMBs)
        let tx = Fmt.rate(s.txMBs)
        return MetricCard(title: "Rede", symbol: "globe", badge: s.primaryInterface, compact: true) {
            BigValue(value: rx.0, unit: rx.1, size: 26)
            Sparkline(values: m.rxHistory, color: Palette.network, secondary: m.txHistory).frame(height: 22)
            Footnote(text: "Envio \(tx.0) \(tx.1)")
        }
    }

    private func fan(_ s: StatusSnapshot) -> some View {
        let count = s.thermal?.fan_count ?? 0
        let speed = Double(s.thermal?.fan_speed ?? 0)
        return MetricCard(title: "Ventoinha", symbol: "fanblades", compact: true) {
            BigValue(value: count > 0 ? Fmt.rpm(s.thermal?.fan_speed) : "—", unit: count > 0 ? "RPM" : "", size: 26)
            Meter(fraction: speed / 6000, color: Palette.network).frame(height: 22).opacity(count > 0 ? 1 : 0)
            Footnote(text: "Controlada pelo macOS")
        }
    }

    private func devices(_ s: StatusSnapshot) -> some View {
        VStack(spacing: 2) {
            ForEach(s.connectedBluetooth.prefix(4)) { d in
                let level = Double((d.battery ?? "").filter(\.isNumber)) ?? 0
                HStack(spacing: 10) {
                    Image(systemName: icon(for: d.name))
                        .frame(width: 18)
                        .foregroundStyle(Theme.muted)
                    Text(d.name).lineLimit(1)
                    Spacer()
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.1), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: level / 100)
                            .stroke(level <= 20 ? Palette.hot : Palette.cpu, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 18, height: 18)
                    Text(d.battery ?? "")
                        .foregroundStyle(level <= 20 ? Palette.hot : Palette.cpu)
                        .frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 13))
                .frame(height: 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("estojo") || n.contains("case") { return "airpodspro.chargingcase.wireless" }
        if n.contains("airpods") { return "airpods.pro" }
        if n.contains("mouse") || n.contains("mx") { return "computermouse" }
        if n.contains("keyboard") || n.contains("teclado") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return "headphones"
    }

    private func processes(_ procs: ProcessModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Principais processos").frame(maxWidth: .infinity, alignment: .leading)
                Text("Memória").frame(width: 70, alignment: .trailing)
                Text("% CPU").frame(width: 42, alignment: .trailing)
                Color.clear.frame(width: 20, height: 1)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.muted)
            .padding(.bottom, 4)
            ForEach(procs.topByMemory(5)) { p in
                HStack(spacing: 8) {
                    Group {
                        if let icon = procs.icon(for: p.main) { Image(nsImage: icon).resizable() } else { Image(systemName: "gearshape").foregroundStyle(Theme.muted) }
                    }
                    .frame(width: 16, height: 16)
                    Text(p.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(Bytes.mem(p.memoryBytes))
                        .foregroundStyle(Palette.memory)
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                    Text(Fmt.dec(p.cpu))
                        .foregroundStyle(p.cpu > 50 ? Palette.warm : Theme.text)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                    ProcessActionsMenu(group: p, model: procs, origin: "monitor")
                        .frame(width: 20)
                }
                .font(.system(size: 13))
                .padding(.vertical, 5)
                .help(p.count > 1 ? "\(p.name): \(p.count) processos somados" : p.name)
                .contextMenu { ProcessActions(group: p, model: procs, origin: "monitor") }
            }
            Button("Ver todos os processos") { onOpen(.status) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accentLight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                counter(Bytes.str(store.history.cleanedBytes), "Liberados")
                counter("\(store.history.uninstallCount)", "Apps removidos")
                counter("\(store.history.optimizeCount)", "Otimizações")
            }
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))

            HStack(spacing: 6) {
                Button {
                    store.keepAwake.toggle()
                } label: {
                    Label("Tela ligada", systemImage: store.keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 12.5, weight: store.keepAwake.isOn ? .semibold : .regular))
                        .foregroundStyle(store.keepAwake.isOn ? Palette.memory : Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(store.keepAwake.isOn ? 0.1 : 0.06)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Impede que a tela apague")
                footerButton("Limpar", strong: false) { onOpen(.clean) }
                footerButton("Abrir Limpo", strong: true) { onOpen(store.section) }
            }
        }
    }

    private func counter(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func footerButton(_ title: String, strong: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: strong ? .semibold : .regular))
                .foregroundStyle(strong ? Color.black : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(strong ? Color(white: 0.95) : Color.white.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Chips que quebram linha quando não cabem.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { Chip(text: $0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
