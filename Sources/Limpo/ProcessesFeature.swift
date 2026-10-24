import SwiftUI
import AppKit
import Darwin

// MARK: - Processos (lista completa via `ps`)

struct ProcessInfoRow: Identifiable, Hashable {
    let pid: Int32
    let ppid: Int32
    let memoryBytes: Int64
    let cpu: Double
    let user: String
    let path: String
    let name: String
    var id: Int32 { pid }

    var isApp: Bool { path.contains(".app/") }
}

@MainActor
@Observable
final class ProcessModel {
    enum Sort: String { case memory, cpu, name, pid }

    var all: [ProcessInfoRow] = []
    var sort: Sort = .memory
    var ascending = false
    var query = ""
    var onlyMine = false
    var error: String?
    var pendingKill: ProcessInfoRow?
    var info: ProcessDetails?
    /// Qual tela pediu a ação (janela ou monitor), para o alerta aparecer só nela.
    var actionOrigin = "window"

    func topByMemory(_ n: Int) -> [ProcessInfoRow] {
        Array(all.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(n))
    }

    private var viewers = 0
    private var loop: Task<Void, Never>?
    private var iconCache: [Int32: NSImage] = [:]

    var totalMemory: Int64 { all.reduce(0) { $0 + $1.memoryBytes } }

    var visible: [ProcessInfoRow] {
        var list = all
        if onlyMine {
            let me = NSUserName()
            list = list.filter { $0.user == me }
        }
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query) || "\($0.pid)" == query }
        }
        let sorted: [ProcessInfoRow]
        switch sort {
        case .memory: sorted = list.sorted { $0.memoryBytes > $1.memoryBytes }
        case .cpu: sorted = list.sorted { $0.cpu > $1.cpu }
        case .name: sorted = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid: sorted = list.sorted { $0.pid < $1.pid }
        }
        let defaultAscending = sort == .name || sort == .pid
        return ascending == defaultAscending ? sorted : sorted.reversed()
    }

    func toggleSort(_ s: Sort) {
        if sort == s {
            ascending.toggle()
        } else {
            sort = s
            ascending = (s == .name || s == .pid)
        }
    }

    func attach() {
        viewers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    func refresh() async {
        do {
            let output = try await Shell.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,rss=,%cpu=,user=,comm="])
            all = Self.parse(output)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func parse(_ text: String) -> [ProcessInfoRow] {
        text.split(separator: "\n").compactMap { raw in
            let fields = raw.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let rss = Int64(fields[2]) else { return nil }
            let cpu = Double(fields[3].replacingOccurrences(of: ",", with: ".")) ?? 0
            let path = String(fields[5]).trimmingCharacters(in: .whitespaces)
            return ProcessInfoRow(
                pid: pid,
                ppid: ppid,
                memoryBytes: rss * 1024,
                cpu: cpu,
                user: String(fields[4]),
                path: path,
                name: displayName(pid: pid, path: path)
            )
        }
    }

    nonisolated static func displayName(pid: Int32, path: String) -> String {
        // Para apps, usa o nome do pacote .app (ex.: "Google Chrome Helper (Renderer)" continua com o próprio nome).
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? "PID \(pid)" : last
    }

    func icon(for p: ProcessInfoRow) -> NSImage? {
        if let cached = iconCache[p.pid] { return cached }
        var image: NSImage?
        if let app = NSRunningApplication(processIdentifier: p.pid), let icon = app.icon {
            image = icon
        } else if let range = p.path.range(of: ".app/") {
            let bundle = String(p.path[..<range.lowerBound]) + ".app"
            image = NSWorkspace.shared.icon(forFile: bundle)
        }
        if let image { iconCache[p.pid] = image }
        return image
    }

    // MARK: Ações

    func copyPID(_ p: ProcessInfoRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(p.pid)", forType: .string)
    }

    func reveal(_ p: ProcessInfoRow) {
        var target = p.path
        if let range = p.path.range(of: ".app/") {
            target = String(p.path[..<range.lowerBound]) + ".app"
        }
        guard FileManager.default.fileExists(atPath: target) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    func terminate(_ p: ProcessInfoRow, force: Bool) {
        if let app = NSRunningApplication(processIdentifier: p.pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(p.pid, force ? SIGKILL : SIGTERM)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
        }
    }

    func explain(_ p: ProcessInfoRow) async {
        let parent = all.first { $0.pid == p.ppid }
        let started = (try? await Shell.run("/bin/ps", ["-o", "lstart=", "-p", "\(p.pid)"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        info = ProcessDetails(process: p, parent: parent, started: started)
    }
}

struct ProcessDetails: Identifiable {
    let process: ProcessInfoRow
    let parent: ProcessInfoRow?
    let started: String
    var id: Int32 { process.pid }

    var reason: String {
        let p = process
        if NSRunningApplication(processIdentifier: p.pid)?.activationPolicy == .regular {
            return "É um app aberto por você (aparece no Dock)."
        }
        if p.path.contains("/Contents/Frameworks/") || p.path.contains("Helper") {
            let owner = p.path.components(separatedBy: "/").first { $0.hasSuffix(".app") }?.replacingOccurrences(of: ".app", with: "")
            return "É um processo auxiliar\(owner.map { " do \($0)" } ?? "") — some quando o app principal é fechado."
        }
        if p.path.hasPrefix("/System/") || p.path.hasPrefix("/usr/libexec") || p.path.hasPrefix("/usr/sbin") {
            return "Serviço do macOS. Encerrar pode causar instabilidade; o sistema costuma reabri-lo."
        }
        if p.ppid == 1 {
            return "Iniciado pelo launchd (item de início, agente em segundo plano ou serviço de um app)."
        }
        if let parent {
            return "Iniciado por \(parent.name) (PID \(parent.pid))."
        }
        return "Iniciado por outro processo."
    }
}

// MARK: - Lista de processos (tela Status)

struct ProcessListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.processes

        VStack(spacing: 0) {
            toolbar(model)
            Divider().overlay(Theme.hairline)
            header(model)
            Divider().overlay(Theme.hairline)
            let maxMemory = model.all.map(\.memoryBytes).max() ?? 1
            LazyVStack(spacing: 0) {
                ForEach(model.visible) { p in
                    ProcessRowView(process: p, model: model, maxMemory: maxMemory)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
        .alert(
            "Encerrar \(model.pendingKill?.name ?? "")?",
            isPresented: Binding(get: { model.pendingKill != nil && model.actionOrigin == "window" }, set: { if !$0 { model.pendingKill = nil } })
        ) {
            Button("Cancelar", role: .cancel) { model.pendingKill = nil }
            Button("Encerrar") {
                if let p = model.pendingKill { model.terminate(p, force: false) }
                model.pendingKill = nil
            }
            Button("Forçar encerramento", role: .destructive) {
                if let p = model.pendingKill { model.terminate(p, force: true) }
                model.pendingKill = nil
            }
        } message: {
            Text("Alterações não salvas nesse app podem ser perdidas.")
        }
        .sheet(item: Binding(get: { model.actionOrigin == "window" ? model.info : nil }, set: { model.info = $0 })) { details in
            ProcessDetailsSheet(details: details) { model.info = nil }
        }
    }

    private func toolbar(_ model: ProcessModel) -> some View {
        HStack(spacing: 12) {
            Text("Processos")
                .font(.system(size: 15, weight: .semibold))
            Text("\(model.visible.count) · \(Bytes.mem(model.totalMemory)) em uso")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            if let zombies = store.status.snapshot?.zombie_count, zombies > 0 {
                Chip(text: "\(zombies) zumbi\(zombies > 1 ? "s" : "")", strong: true)
                    .help("Processos encerrados que o processo pai ainda não recolheu. Somem quando o app pai é fechado.")
            }
            Spacer()
            Toggle("Só meus", isOn: Binding(get: { model.onlyMine }, set: { model.onlyMine = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Buscar processo", text: Binding(get: { model.query }, set: { model.query = $0 }))
                    .textFieldStyle(.plain)
                    .frame(width: 170)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.black.opacity(0.25)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func header(_ model: ProcessModel) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 24, height: 1)
            sortButton("NOME", .name, model).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("MEMÓRIA", .memory, model).frame(width: 220, alignment: .trailing)
            sortButton("% CPU", .cpu, model).frame(width: 150, alignment: .trailing)
            sortButton("PID", .pid, model).frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 24, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func sortButton(_ title: String, _ sort: ProcessModel.Sort, _ model: ProcessModel) -> some View {
        Button {
            model.toggleSort(sort)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if model.sort == sort {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(model.sort == sort ? Theme.text : Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ordenar por \(title.lowercased())")
    }
}

private struct ProcessRowView: View {
    let process: ProcessInfoRow
    let model: ProcessModel
    let maxMemory: Int64

    var body: some View {
        let p = process
        HStack(spacing: 12) {
            Group {
                if let icon = model.icon(for: p) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).lineLimit(1)
                if p.user != NSUserName() {
                    Text(p.user).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Meter(fraction: Double(p.memoryBytes) / Double(max(maxMemory, 1)), color: Palette.memory)
                    .frame(width: 110)
                Text(Bytes.mem(p.memoryBytes))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            .frame(width: 220, alignment: .trailing)

            HStack(spacing: 10) {
                Meter(fraction: min(p.cpu, 100) / 100, color: Palette.cpu)
                    .frame(width: 70)
                Text(Fmt.dec(p.cpu))
                    .monospacedDigit()
                    .foregroundStyle(p.cpu > 50 ? Palette.warm : Theme.text)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(width: 150, alignment: .trailing)

            Text("\(p.pid)")
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 64, alignment: .trailing)

            ProcessActionsMenu(process: p, model: model)
                .frame(width: 24)
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 20)
        .frame(height: 40)
        .contentShape(Rectangle())
        .contextMenu { ProcessActions(process: p, model: model) }
    }
}

struct ProcessActionsMenu: View {
    let process: ProcessInfoRow
    let model: ProcessModel
    var origin = "window"

    var body: some View {
        Menu {
            ProcessActions(process: process, model: model, origin: origin)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Theme.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct ProcessActions: View {
    let process: ProcessInfoRow
    let model: ProcessModel
    var origin = "window"

    var body: some View {
        Button {
            model.actionOrigin = origin
            Task { await model.explain(process) }
        } label: { Label("Por que está em execução?", systemImage: "lightbulb") }
        Button { model.copyPID(process) } label: { Label("Copiar PID", systemImage: "doc.on.doc") }
        Button { model.reveal(process) } label: { Label("Mostrar no Finder", systemImage: "folder") }
        Divider()
        Button { model.actionOrigin = origin; model.pendingKill = process } label: { Label("Encerrar…", systemImage: "xmark.circle") }
    }
}

private struct ProcessDetailsSheet: View {
    let details: ProcessDetails
    let close: () -> Void

    var body: some View {
        let p = details.process
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.memory)
                Text(p.name).font(.system(size: 20, weight: .semibold))
            }
            Text(details.reason)
                .font(.system(size: 14))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("PID", "\(p.pid)")
                row("Processo pai", details.parent.map { "\($0.name) (\($0.pid))" } ?? "PID \(p.ppid)")
                row("Usuário", p.user)
                row("Memória", Bytes.mem(p.memoryBytes))
                row("CPU", "\(Fmt.dec(p.cpu))%")
                if !details.started.isEmpty { row("Iniciado em", details.started) }
                row("Caminho", p.path)
            }
            .font(.system(size: 12.5))
            HStack {
                Spacer()
                Button("Fechar", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.muted)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}
